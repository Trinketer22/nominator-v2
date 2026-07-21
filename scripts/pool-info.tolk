import "@stdlib/strings"
import "@acton/env"
import "@acton/fmt"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/testing"

import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

// Recovery requirement check, matching the on-chain logic in
// RotationData.checkRecoverRequirements (validators.tolk:270-279).
// Uses the PERSISTED rotationCount/rotationTime read directly from
// get_pool_data's validators cell — NOT the projected values from
// get_validator_info, which depend on blockchain.configParam(34) and
// are unreliable off-chain (DEFAULT_CONFIG in acton script, latest
// config in tonlib smc.runGetMethod).
fun printPersistedRotationInfo(
    label: string,
    proxyHash: uint256,
    round: RoundData,
) {
    val lookup = round.users.get(proxyHash);
    if (!lookup.isFound) {
        return;
    }
    val usage = lookup.loadValue();

    println("--- {} (persisted) ---", label);
    println("Proxy:           {}", proxyHash);
    println("TON used:        {:gram}", usage.tonUsed);
    println("Held for:        {}s", usage.heldFor);
    println("Rotation time:   {}", usage.rotation.rotationTime);
    println("Rotation count:  {}", usage.rotation.rotationCount);

    val rotCount = usage.rotation.rotationCount;
    val rotTime = usage.rotation.rotationTime;
    val heldFor = usage.heldFor;

    if (rotCount < 2) {
        println("Recovery:        NOT YET (rotationCount={} < 2)", rotCount);
    } else if (rotCount == 2) {
        val earliest = rotTime + heldFor + 60;
        println("Earliest recover:{} — compare against current blockchain time manually", earliest);
        println("                 (on-chain check: blockchain.now() > {})", earliest);
    } else {
        println("Recovery:        ALLOWED (rotationCount={} > 2, time check skipped)", rotCount);
    }
}

// Prints the PROJECTED rotation info from get_validator_info for reference.
// This data depends on blockchain.configParam(34), which is unreliable
// off-chain (DEFAULT_CONFIG in acton script, latest config in tonlib).
// Shown only as an informational hint — recovery decisions should use
// the persisted data above.
fun printProjectedRotationInfo(label: string, usage: ValidatorUsageStats) {
    println("--- {} (projected — unreliable off-chain) ---", label);
    println("Proxy:           {}", usage.proxy);
    println("TON used:        {:gram}", usage.usage.tonUsed);
    println("Held for:        {}s", usage.usage.heldFor);
    println("Rotation time:   {}", usage.usage.rotation.rotationTime);
    println("Rotation count:  {}", usage.usage.rotation.rotationCount);
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

    // Persisted validators cell info — read directly from get_pool_data.
    val validators = lazy data.validators.load();
    println("--- Validators cell (persisted) ---");
    println("Main validator:    {}", validators.mainValidatorAddress);
    println("vsetHash (>>128):  {}", validators.vsetHash);
    println("Active validators: {}", validators.activeValidators);
    println("Active slots:      {}", validators.activeSlots);
    println("Stake used:        {:gram}", validators.stakeUsed);
    if (validators.validators.isEmpty()) {
        println("Extra validators:  none");
    } else {
        println("Extra validators:");
        var valIter = validators.validators.findFirst();
        while (valIter.isFound) {
            val valAddr = valIter.getKey();
            val valEntry = valIter.loadValue();
            println(
                "  {} (usageState={}, refund={:gram})",
                valAddr,
                valEntry.usageState,
                valEntry.refundAmount,
            );
            valIter = validators.validators.iterateNext(valIter);
        }
    }
    val curRound = lazy validators.curRound.load();
    val prevRound = lazy validators.prevRound.load();
    println("curRound index:    {}", curRound.roundIndex);
    println("curRound users:    {}", curRound.users.isEmpty() ? "empty" : "present");
    println("prevRound index:   {}", prevRound.roundIndex);
    println("prevRound users:   {}", prevRound.users.isEmpty() ? "empty" : "present");

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

fun printValidatorInfo(pool: Pool, validator: address, poolData: Storage) {
    val validators = lazy poolData.validators.load();

    // Look up the validator in the persisted validators map to get proxy hashes.
    // The validator can be the main validator or a regular one.
    var valData: Validator?;
    valData = null;
    if (validator == validators.mainValidatorAddress) {
        val mainData = lazy validators.mainValidatorData.load();
        valData = mainData;
    } else {
        val valLookup = validators.validators.get(validator);
        if (valLookup.isFound) {
            valData = valLookup.loadValue();
        }
    }

    println("=== Validator {} ===", validator);
    if (valData == null) {
        println("Validator not found in pool");
        return;
    }
    val vd = valData!;

    println("Banned:        {}", vd.isBanned);
    println("Usage state:   {}", vd.usageState);
    println("Round parity:  {}", vd.roundParity);
    if (vd.evenProxy != null) {
        println("Even proxy:    {}", vd.evenProxy!);
    }
    if (vd.oddProxy != null) {
        println("Odd proxy:     {}", vd.oddProxy!);
    }
    println("Refund amount: {:gram}", vd.refundAmount);
    if (vd.limit != null) {
        match (vd.limit) {
            ValidatorLimitTon => {
                val lt = vd.limit as ValidatorLimitTon;
                println("Limit:         ton max={:gram}", lt.maxTon);
            }
            ValidatorLimitShare => {
                val ls = vd.limit as ValidatorLimitShare;
                println("Limit:         share max={}/{}", ls.maxShare, SHARE_BASE);
            }
        }
    } else {
        println("Limit:         none (uses global)");
    }

    // get_validator_info may fail off-chain due to DEFAULT_CONFIG mismatch
    // (rotateRound/rotateVset depend on blockchain.configParam(34)).
    // We catch the error and skip the projected data section.
    var info: GetValidatorInfo?;
    info = null;
    try {
        info = pool.getValidatorInfo(validator);
    } catch (_e) {
        info = null;
    }

    if (info != null) {
        val i = info!;
        println("Stakeable:     {:gram}", i.stakeable);
        println("Round index:   {}", i.roundIndex);
        println("Rotated:       {}", i.rotated);
    } else {
        println("Stakeable:     (get_validator_info failed — DEFAULT_CONFIG mismatch)");
        println("Round index:   {}", poolData.roundIndex);
    }

    // Persisted rotation data — read directly from the validators cell in
    // get_pool_data. This is the data the RecoverStakeCompat handler
    // actually sees on-chain (no config-dependent projection).
    val curRound = lazy validators.curRound.load();
    val prevRound = lazy validators.prevRound.load();

    println("");
    println("=== Persisted rotation data (from get_pool_data) ===");
    if (vd.evenProxy != null) {
        printPersistedRotationInfo("curRound (even proxy)", vd.evenProxy!, curRound);
    }
    if (vd.oddProxy != null) {
        printPersistedRotationInfo("curRound (odd proxy)", vd.oddProxy!, curRound);
    }
    if (vd.evenProxy != null) {
        printPersistedRotationInfo("prevRound (even proxy)", vd.evenProxy!, prevRound);
    }
    if (vd.oddProxy != null) {
        printPersistedRotationInfo("prevRound (odd proxy)", vd.oddProxy!, prevRound);
    }

    // Projected rotation data — from get_validator_info. Shown for reference
    // only, as it depends on blockchain.configParam(34) which is unreliable
    // off-chain (DEFAULT_CONFIG in acton script, latest config in tonlib).
    if (info != null) {
        val i = info!;
        println("");
        println("=== Projected rotation data (from get_validator_info — unreliable off-chain) ===");
        if (i.usage.curRoundUsage != null) {
            printProjectedRotationInfo("Current round usage", i.usage.curRoundUsage!);
        }
        if (i.usage.prevRoundUsage != null) {
            printProjectedRotationInfo("Previous round usage", i.usage.prevRoundUsage!);
        }
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
        val poolData = pool.getPoolData();
        var validator: address = poolData.validators.load().mainValidatorAddress;
        if (validatorEnv != null) {
            validator = validatorEnv;
        } else {
            // Build a picker from the known validators in the persisted cell.
            val validators = lazy poolData.validators.load();
            var options: array<string> = [];
            var addresses: array<address> = [];
            // Main validator first
            options.push(format("{} (main)", validators.mainValidatorAddress));
            addresses.push(validators.mainValidatorAddress);
            // Extra validators
            if (!validators.validators.isEmpty()) {
                var iter = validators.validators.findFirst();
                while (iter.isFound) {
                    val addr = iter.getKey();
                    options.push(format("{}", addr));
                    addresses.push(addr);
                    iter = validators.validators.iterateNext(iter);
                }
            }
            val choice = select("Select validator:", options, 0);
            var foundIdx = -1;
            var idx = 0;
            while (idx < addresses.size()) {
                if (choice.equalTo(options.get(idx))) {
                    foundIdx = idx;
                    idx = addresses.size();
                }
                idx += 1;
            }
            if (foundIdx < 0) {
                println("No validator selected, exiting");
                return;
            }
            validator = addresses.get(foundIdx);
        }
        printValidatorInfo(pool, validator, poolData);
    } else {
        printPoolInfo(pool);
    }
}
