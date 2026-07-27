import "@stdlib/strings"
import "@acton/env"
import "@acton/fmt"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/emulation/testing"
import "@acton/testing/assert"

import "@contracts/types"
import "@wrappers/Pool.gen"

const DEFAULT_POOL_ID = 0
const DEFAULT_DEPLOY_VALUE = ton("250")
const DEFAULT_MSG_VALUE = ton("1")
const DEFAULT_ADD_VALIDATOR_VALUE = ton("250")
const EMUL_SNAPSHOT_PATH = "build/cache/emul-snapshot.json"

// Shows a confirmation dialog summarizing the pending transaction before it is
// sent to the network. Lets the user interrupt the script by answering "no".
// Set the BATCH env var (e.g. BATCH=1) to skip the dialog for non-interactive
// automation.
fun confirmSend(summary: string): void {
    if (env<bool>("BATCH") ?? false) {
        return;
    }
    val ok = confirm(
        format("{}\n\nIs it ok to send this transaction?", summary),
        false,
        "Answer 'no' to abort without sending anything to the network.",
    );
    if (!ok) {
        Assert.fail("Transaction aborted by user before sending to the network");
    }
}

fun poolOwner(): ActonWallet {
    // Use promptWallet so the script is compatible with `--tonconnect`: in
    // broadcast mode with TON Connect the chosen wallet name resolves to the
    // connected wallet, and in emulation mode any name is accepted.
    val walletName = env<string>("DEPLOYER_WALLET") ??
    promptWallet("Select the pool owner wallet:");
    return scripts.wallet(walletName);
}

fun poolId(): uint32 {
    return (env<int>("POOL_ID") ?? DEFAULT_POOL_ID) as uint32;
}

fun poolFor(owner: address): Pool {
    return Pool.fromStorage({
        owner,
        poolId: poolId(),
    });
}

// --- Emulation snapshot helpers (for script testing purposes only) ---
// These helpers persist the local emulator world state to a JSON file so that
// a sequence of `acton script` invocations can chain together (deploy -> add
// validator -> withdraw -> ...) without rerunning the whole flow each time.
//
// They are NO-OPs when the script is launched with `--net` (testnet/mainnet):
// `net.isBroadcasting()` returns true in broadcast mode, and both functions
// early-return without touching the filesystem. In broadcast mode each script
// reads/writes the real on-chain state directly, so no local snapshot is
// needed or used.

fun saveEmulationSnapshot(): void {
    if (net.isBroadcasting()) {
        return;
    }
    val ok = testing.saveSnapshot(EMUL_SNAPSHOT_PATH);
    if (!ok) {
        println("warning: failed to save emulation snapshot to {}", EMUL_SNAPSHOT_PATH);
    }
}

fun loadEmulationSnapshot(): bool {
    if (net.isBroadcasting()) {
        return true;
    }
    return testing.loadSnapshot(EMUL_SNAPSHOT_PATH);
}

fun loadPool(poolAddress: address): Pool {
    // EMUL-TEST-ONLY: restore emulator state from the previous `acton script` run.
    // No-op under `--net` (broadcast mode reads real on-chain state instead).
    loadEmulationSnapshot();

    val pool = Pool.fromAddress(poolAddress);
    if (!scripts.isContractDeployed(pool.address)) {
        Assert.fail(format("Pool contract is not deployed at {}", pool.address));
    }
    return pool;
}

fun promptPoolAddress(): address {
    val fromEnv = env<address>("POOL_ADDRESS");
    if (fromEnv != null) {
        return fromEnv;
    }
    return promptAddress("Pool address:", null, "EQ... / kQ... / Ef... / kf...");
}

// Looks up a validator record in the persisted validators cell, accounting
// for the main validator (stored in mainValidatorData, NOT in the validators
// map). Returns null when the validator is not found.
// We avoid get_validator_info because it calls rotateRound →
// blockchain.configParam(34), which is unreliable off-chain (DEFAULT_CONFIG
// in acton script) and may throw, masking the actual on-chain state.
fun lookupValidatorRecord(pool: Pool, validator: address): Validator? {
    val poolData = pool.getPoolData();
    val validators = lazy poolData.validators.load();
    if (validator == validators.mainValidatorAddress) {
        val mainData = lazy validators.mainValidatorData.load();
        return mainData;
    }
    val lookup = validators.validators.get(validator);
    if (lookup.isFound) {
        return lookup.loadValue();
    }
    return null;
}

fun ensureValidatorAdded(pool: Pool, validator: address): void {
    val owner = poolOwner();

    if (lookupValidatorRecord(pool, validator) != null) {
        return;
    }

    val allowance = env<int>("VALIDATOR_ROUND_ALLOWANCE") ?? RoundAllowance.InAllRounds as int;
    val value = env<coins>("ADD_VALIDATOR_VALUE") ?? DEFAULT_ADD_VALIDATOR_VALUE;

    val res = pool.sendAddValidator(
        owner.address,
        0,
        validator,
        // SAFETY: allowance comes from VALIDATOR_ROUND_ALLOWANCE env or defaults to InAllRounds (3);
        // valid values are 1 (InOddRounds), 2 (InEvenRounds), 3 (InAllRounds).
        allowance as RoundAllowance,
        null,
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("AddValidator message was not accepted by network");
    }

    println("Validator {} added to pool {}", validator, pool.address);
}

// Verifies a validator is present in the pool. Reads the persisted validators
// cell (accounting for the main validator) instead of get_validator_info,
// which is unreliable off-chain due to configParam(34) dependency.
fun expectValidatorPresent(pool: Pool, validator: address): void {
    if (lookupValidatorRecord(pool, validator) == null) {
        Assert.fail(
            format("Validator {} is not present in pool {}", validator, pool.address),
        );
    }
}

fun expectValidatorAbsent(pool: Pool, validator: address): void {
    // A removed validator with no outstanding stake is deleted from the
    // validators map. The main validator cannot be removed, so absence is
    // checked only against the extra-validators map.
    if (lookupValidatorRecord(pool, validator) != null) {
        Assert.fail(
            format("Validator {} is still present in pool {}", validator, pool.address),
        );
    }
}

fun assertEqual<T>(actual: T, expected: T, label: string): void {
    if (actual != expected) {
        Assert.fail(format("Assertion failed: {} expected={}, actual={}", label, expected, actual));
    }
}

// Parses a decimal TON amount string (e.g. "1.5", "0.001", "250") into nanograms.
// Returns null if the string is empty or malformed.
fun parseTonAmount(s: string): coins? {
    var slice = s.beginParse();
    if (slice.remainingBitsCount() == 0) {
        return null;
    }
    val mns = 45;
    val pls = 43;
    val dt = 46;
    val zr = 48;
    val nr = 57;

    var intPart: int = 0;
    var negative = false;
    var hasDigits = false;

    val first = slice.loadUint(8);
    if (first == mns) {
        negative = true;
    } else if (first == pls) {
        // skip
    } else if (first >= zr && first <= nr) {
        intPart = first - zr;
        hasDigits = true;
    } else {
        return null;
    }

    var seenDot = false;
    var fracDigits = 0;
    var fracValue: int = 0;

    while (slice.remainingBitsCount() > 0) {
        val c = slice.loadUint(8);
        if (c == dt) {
            if (seenDot) {
                return null;
            }
            seenDot = true;
        } else {
            if (c < zr || c > nr) {
                return null;
            }
            hasDigits = true;
            val digit = c - zr;
            if (seenDot) {
                if (fracDigits < 9) {
                    fracValue = fracValue * 10 + digit;
                    fracDigits += 1;
                }
            } else {
                intPart = intPart * 10 + digit;
            }
        }
    }

    if (!hasDigits) {
        return null;
    }
    if (negative) {
        return null;
    }

    // Pad fractional part to 9 digits (nanograms).
    var i = fracDigits;
    while (i < 9) {
        fracValue *= 10;
        i += 1;
    }

    return (intPart * 1000000000) + fracValue;
}

// Converts a coins amount (nanograms) to a decimal TON string (e.g. "3.5", "0.001").
fun coinsToTonString(amount: coins): string {
    val intPart = amount / 1000000000;
    val fracPart = amount % 1000000000;
    if (fracPart == 0) {
        return format("{}", intPart);
    }
    // Pad fractional part to exactly 9 digits with leading zeros, then strip trailing zeros.
    // e.g. fracPart=1000000 -> "001000000" -> "001"
    var frac = fracPart;
    // Extract 9 digits little-endian into an array.
    var digits: array<int> = [
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    ];
    var i = 0;
    repeat (9) {
        digits.set(frac % 10, i);
        frac /= 10;
        i += 1;
    }
    // Find the lowest non-zero digit (least significant, lowest index in little-endian).
    // We strip trailing zeros in the big-endian output, which are leading zeros in little-endian.
    var first = 0;
    while (first <= 8 && digits.get(first) == 0) {
        first += 1;
    }
    if (first > 8) {
        return format("{}", intPart);
    }
    // Build the fractional string: from most significant (index 8) down to `first`.
    var s = ".";
    var j = 8;
    while (j >= first) {
        s = format("{}{}", s, digits.get(j));
        j -= 1;
    }
    return format("{}{}", intPart, s);
}

// --- Prompted input helpers (with env-var fallback for non-interactive runs) ---
// Each helper first checks an env var. If the env var is set (e.g. in CI or when
// chaining scripts in emulation), it is used directly. Otherwise, an interactive
// prompt is shown. This keeps scripts usable both interactively and in automation.

fun promptCoins(envVar: string, message: string, defaultGrams: string): coins {
    val fromEnv = env<coins>(envVar);
    if (fromEnv != null) {
        return fromEnv;
    }
    val input = prompt(message, "amount in TON (e.g. 1.5)", defaultGrams);
    val parsed = parseTonAmount(input);
    if (parsed != null) {
        return parsed;
    }
    // Fall back to the default if the user entered garbage.
    val defaultParsed = parseTonAmount(defaultGrams);
    if (defaultParsed != null) {
        return defaultParsed;
    }
    Assert.fail(format("Invalid amount '{}'", input));
}

fun promptCoinsRequired(envVar: string, message: string): coins {
    val fromEnv = env<coins>(envVar);
    if (fromEnv != null) {
        if (fromEnv <= 0) {
            Assert.fail(format("{} must be greater than zero (got {:gram})", envVar, fromEnv));
        }
        return fromEnv;
    }
    val input = prompt(message, "amount in TON (e.g. 1.5)", "");
    val parsed = parseTonAmount(input);
    if (parsed == null || parsed <= 0) {
        Assert.fail(format("Invalid or zero amount '{}'", input));
    }
    return parsed;
}

fun promptAddressWithEnv(envVar: string, message: string, default: address? = null): address {
    val fromEnv = env<address>(envVar);
    if (fromEnv != null) {
        return fromEnv;
    }
    return promptAddress(message, default);
}

// Builds a list of known validator addresses from the pool's persisted
// validators cell (main validator + extra validators). Returns the addresses
// together with their picker labels (the main validator is tagged "(main)").
fun collectValidatorOptions(pool: Pool, includeMain: bool): (array<address>, array<string>) {
    var addresses: array<address> = [];
    var labels: array<string> = [];
    val poolData = pool.getPoolData();
    val validators = lazy poolData.validators.load();
    if (includeMain) {
        addresses.push(validators.mainValidatorAddress);
        labels.push(format("{} (main)", validators.mainValidatorAddress));
    }
    if (!validators.validators.isEmpty()) {
        var iter = validators.validators.findFirst();
        while (iter.isFound) {
            val addr = iter.getKey();
            addresses.push(addr);
            labels.push(format("{}", addr));
            iter = validators.validators.iterateNext(iter);
        }
    }
    return (addresses, labels);
}

// Prompts for a validator address using a picker built from the pool's known
// validators instead of a free-form text prompt. An env var short-circuits the
// picker for non-interactive runs.
fun promptValidatorPicker(
    pool: Pool,
    envVar: string,
    message: string,
    includeMain: bool,
): address {
    val fromEnv = env<address>(envVar);
    if (fromEnv != null) {
        return fromEnv;
    }

    val (addresses, labels) = collectValidatorOptions(pool, includeMain);

    if (labels.size() == 0) {
        Assert.fail("No validators available to pick from in this pool");
    }

    val choice = select(message, labels, 0);

    var idx = 0;
    while (idx < addresses.size()) {
        if (choice.equalTo(labels.get(idx))) {
            return addresses.get(idx);
        }
        idx += 1;
    }
    Assert.fail(format("No validator selected from picker (choice='{}')", choice));
}

// Prompts for a validator address to ADD (a brand-new validator, not present in
// the pool yet). Uses an env var or a free-form address prompt, since there is
// nothing to pick from for a validator that does not exist yet.
fun promptNewValidatorAddress(envVar: string, message: string): address {
    val fromEnv = env<address>(envVar);
    if (fromEnv != null) {
        return fromEnv;
    }
    return promptAddress(message, null, "EQ... / kQ... / Ef... / kf...");
}

// Prompts for a per-validator limit (none / ton / share). Returns null when
// "none" is selected (the validator will use the global limits). Env vars
// LIMIT_KIND, MAX_TON and MAX_SHARE short-circuit the prompts.
fun promptValidatorLimit(): ValidatorLimit? {
    val limitKind = promptStringWithEnvOrSelect(
        "LIMIT_KIND",
        "Limit type for the main validator:",
        ["none", "ton", "share"],
        0,
    );
    if (limitKind.equalTo("none")) {
        return null;
    }
    if (limitKind.equalTo("ton")) {
        val maxTon = promptCoins("MAX_TON", "Max TON for this validator:", "300000");
        return ValidatorLimitTon { maxTon };
    }
    val maxShare = promptIntWithEnvOrConst(
        "MAX_SHARE",
        "Max share (0..16777216):",
        SHARE_BASE / 2,
    );
    if (maxShare < 0 || maxShare > SHARE_BASE) {
        Assert.fail(format("Max share {} is out of range (0..{})", maxShare, SHARE_BASE));
    }
    // SAFETY: maxShare is range-checked above to fit uint25 (SHARE_BASE = 2^24 - 1).
    return ValidatorLimitShare { maxShare: maxShare as uint25 };
}

fun promptIntWithEnvOrConst(envVar: string, message: string, default: int): int {
    val fromEnv = env<int>(envVar);
    if (fromEnv != null) {
        return fromEnv;
    }
    return promptInt(message, format("{}", default), "");
}

fun promptStringWithEnvOrSelect(
    envVar: string,
    message: string,
    variants: array<string>,
    defaultIndex: int = 0,
): string {
    val fromEnv = env<string>(envVar);
    if (fromEnv != null) {
        return fromEnv;
    }
    return select(message, variants, defaultIndex);
}

fun roundAllowanceFromEnvOrPrompt(): RoundAllowance {
    val fromEnv = env<int>("VALIDATOR_ROUND_ALLOWANCE");
    if (fromEnv != null) {
        if (fromEnv < 1 || fromEnv > 3) {
            Assert.fail(
                format(
                    "VALIDATOR_ROUND_ALLOWANCE must be 1 (odd), 2 (even), or 3 (all), got {}",
                    fromEnv,
                ),
            );
        }
        // SAFETY: range-checked above to 1..3 which are exactly the RoundAllowance variants.
        return fromEnv as RoundAllowance;
    }
    val parsed = promptInt("Validator round allowance (1=odd, 2=even, 3=all):", "3", "1, 2, or 3");
    if (parsed < 1 || parsed > 3) {
        Assert.fail(
            format("Round allowance must be 1 (odd), 2 (even), or 3 (all), got {}", parsed),
        );
    }
    // SAFETY: range-checked above to 1..3.
    return parsed as RoundAllowance;
}
