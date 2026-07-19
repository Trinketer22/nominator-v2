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

fun poolOwner(): ActonWallet {
    return scripts.wallet(env<string>("DEPLOYER_WALLET") ?? "deployer");
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

fun loadPool(): Pool {
    // EMUL-TEST-ONLY: restore emulator state from the previous `acton script` run.
    // No-op under `--net` (broadcast mode reads real on-chain state instead).
    loadEmulationSnapshot();
    val owner = poolOwner();
    val pool = poolFor(owner.address);
    assert(scripts.isContractDeployed(pool.address), 150);
    return pool;
}

fun ensureValidatorAdded(pool: Pool, validator: address): void {
    val owner = poolOwner();

    var alreadyThere = false;
    try {
        val _info = pool.getValidatorInfo(validator);
        alreadyThere = true;
    } catch (_e) {
        alreadyThere = false;
    }

    if (alreadyThere) {
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

fun expectValidatorPresent(pool: Pool, validator: address): void {
    val poolData = pool.getPoolData();
    val validators = lazy poolData.validators.load();
    val lookup = validators.validators.get(validator);
    assert(lookup.isFound, 200);
}

fun expectValidatorAbsent(pool: Pool, validator: address): void {
    val poolData = pool.getPoolData();
    val validators = lazy poolData.validators.load();
    val lookup = validators.validators.get(validator);
    assert(!lookup.isFound, 201);
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
        assert(fromEnv > 0, 241);
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

fun promptValidatorAddress(envVar: string, message: string): address {
    val fromEnv = env<address>(envVar);
    if (fromEnv != null) {
        return fromEnv;
    }
    return promptAddress(message, null, "EQ... / kQ... / Ef... / kf...");
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
        assert(fromEnv >= 1 && fromEnv <= 3, 115);
        // SAFETY: range-checked above to 1..3 which are exactly the RoundAllowance variants.
        return fromEnv as RoundAllowance;
    }
    val parsed = promptInt("Validator round allowance (1=odd, 2=even, 3=all):", "3", "1, 2, or 3");
    assert(parsed >= 1 && parsed <= 3, 115);
    // SAFETY: range-checked above to 1..3.
    return parsed as RoundAllowance;
}
