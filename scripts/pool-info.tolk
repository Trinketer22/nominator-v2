import "@stdlib/strings"
import "@acton/env"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/config"
import "@acton/emulation/scripts"
import "@acton/emulation/testing"

import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

// Fetches an approximate "now" from the current validator set (config param 34).
// Returns the utimeUntil of the current vset as an upper bound on the current time,
// or 0 if the config cannot be read.
fun fetchApproxNow(): int {
    var config: BlockchainConfigMap?;
    config = null;
    try {
        config = scripts.fetchConfig();
    } catch (_e) {
        config = null;
    }
    if (config == null) {
        return testing.getNow();
    }
    val vsetCell = config.getParamRaw(34);
    if (vsetCell == null) {
        return testing.getNow();
    }
    // CurrentVsetParsed has utimeSince and utimeUntil; use utimeUntil as upper bound.
    val parsed = CurrentVsetParsed.fromCell(vsetCell, { assertEndAfterReading: false });
    return parsed.utimeUntil;
}

fun printRotationInfo(label: string, usage: ValidatorUsageStats) {
    println("--- {} ---", label);
    println("Proxy:           {}", usage.proxy);
    println("TON used:        {:gram}", usage.usage.tonUsed);
    println("Held for:        {}s", usage.usage.heldFor);
    println(
        "Rotation time:   {} ({})",
        usage.usage.rotation.rotationTime,
        usage.usage.rotation.rotationTime,
    );
    println("Rotation count:  {}", usage.usage.rotation.rotationCount);

    val rotCount = usage.usage.rotation.rotationCount;
    val rotTime = usage.usage.rotation.rotationTime;
    val heldFor = usage.usage.heldFor;

    if (rotCount < 2) {
        println("Recovery:        NOT YET (rotationCount={} < 2)", rotCount);
    } else if (rotCount == 2) {
        val earliest = rotTime + heldFor + 60;
        val nowApprox = fetchApproxNow();
        val canRecover = nowApprox > earliest;
        println("Earliest recover:{} ({})", earliest, earliest);
        if (nowApprox > 0) {
            println("Approx now:      {} ({})", nowApprox, nowApprox);
            println("heldFor passed:  {}", canRecover);
        } else {
            println("heldFor passed:  (could not fetch current time — compare manually)");
        }
    } else {
        println("Recovery:        ALLOWED (rotationCount={} > 2)", rotCount);
    }
}

fun printPoolInfo(pool: Pool) {
    val data = pool.getPoolData();
    val (minTon, maxTon, maxRefund) = pool.getLimitsPerValidator();
    val balance = testing.getAccountBalance(pool.address);
    val minStake = pool.getNominatorMinimalStake();

    println("=== Pool {} ===", pool.address);
    println("Owner:             {}", data.owner);
    println("Pool ID:           {}", data.poolId);
    println("Halted:            {}", data.halted);
    println("Round closed:      {}", data.roundClosed);
    println("Round index:       {}", data.roundIndex);
    println("Owner share:       {}/{}", data.ownerShare, SHARE_BASE);
    println("Pool supply:       {:gram}", data.poolSupply);
    println("Nominators amount: {:gram}", data.nominatorsAmount);
    println("Pending deposits:  {:gram}", data.pendingDeposits);
    println("Pending withdraws: {:gram}", data.pendingWithdrawals);
    println("Max nominators:    {}", data.maxNominators);
    println("Pool balance:      {:gram}", balance);
    println("--- Validator limits ---");
    println("Min TON/validator: {:gram}", minTon);
    println("Max TON/validator: {:gram}", maxTon);
    println("Max refund:        {:gram}", maxRefund);
    println("--- Nominator settings ---");
    println("Min stake:         {:gram}", minStake.minStake);
    println("Min expected value:{:gram}", minStake.minExpectedValue);

    // get_pool_invariants may not exist on older pool deployments.
    var invariants: PoolInvariants?;
    invariants = null;
    var invariantsOk = false;
    try {
        invariants = pool.getPoolInvariants();
        invariantsOk = true;
    } catch (_e) {
        invariantsOk = false;
    }
    if (invariantsOk) {
        val inv = invariants!;
        println("--- Invariants ---");
        println("Supply match:          {}", inv.supplyMatch);
        println("Pending withdrawals:   {}", inv.pendingWithdrawalsMatch);
        println("Pending deposits:      {}", inv.pendingDepositsMatch);
        println("Nominator count match: {}", inv.nmCountMatch);
        println("All match:             {}", inv.allMatch);
        println("Projected balance:     {:gram}", inv.projectedBalance);
    } else {
        println("--- Invariants ---");
        println("(get_pool_invariants not available on this pool)");
    }
}

fun printValidatorInfo(pool: Pool, validator: address) {
    val info = pool.getValidatorInfo(validator);

    println("=== Validator {} ===", validator);
    println("Banned:        {}", info.validator.isBanned);
    println("Usage state:   {}", info.validator.usageState);
    println("Round parity:  {}", info.validator.roundParity);
    println("Even proxy:    {}", info.validator.evenProxy);
    println("Odd proxy:     {}", info.validator.oddProxy);
    println("Refund amount: {:gram}", info.validator.refundAmount);
    if (info.validator.limit != null) {
        match (info.validator.limit) {
            ValidatorLimitTon => {
                val lt = info.validator.limit as ValidatorLimitTon;
                println("Limit:         ton max={:gram}", lt.maxTon);
            }
            ValidatorLimitShare => {
                val ls = info.validator.limit as ValidatorLimitShare;
                println("Limit:         share max={}/{}", ls.maxShare, SHARE_BASE);
            }
        }
    } else {
        println("Limit:         none (uses global)");
    }
    println("Stakeable:     {:gram}", info.stakeable);
    println("Round index:   {}", info.roundIndex);
    println("Rotated:       {}", info.rotated);

    if (info.usage.curRoundUsage != null) {
        printRotationInfo("Current round usage", info.usage.curRoundUsage);
    }
    if (info.usage.prevRoundUsage != null) {
        printRotationInfo("Previous round usage", info.usage.prevRoundUsage);
    }
}

fun main() {
    val poolAddress = promptPoolAddress();
    val pool = loadPool(poolAddress);

    // MODE=validator (or VALIDATOR_ADDRESS set) -> validator info; otherwise pool info.
    val validatorEnv = env<address>("VALIDATOR_ADDRESS");
    val modeEnv = env<string>("MODE") ?? "";

    var showValidator: bool;
    if (validatorEnv != null) {
        showValidator = true;
    } else if (modeEnv.equalTo("validator")) {
        showValidator = true;
    } else if (modeEnv.equalTo("pool")) {
        showValidator = false;
    } else {
        // interactive: ask the user
        val choice = select("What to query?", ["Pool info", "Validator info"], 0);
        showValidator = choice.equalTo("Validator info");
    }

    if (showValidator) {
        var validator: address;
        if (validatorEnv != null) {
            validator = validatorEnv;
        } else {
            validator = promptAddress("Validator address:", null, "EQ... / kQ... / Ef... / kf...");
        }
        printValidatorInfo(pool, validator);
    } else {
        printPoolInfo(pool);
    }
}
