import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"

import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

fun main() {
    val pool = loadPool();
    val owner = poolOwner();

    val poolData = pool.getPoolData();
    val nominators = lazy poolData.nominators.load();

    val newMaxNmRaw = promptIntWithEnvOrConst(
        "MAX_NOMINATORS",
        "Max nominators:",
        poolData.maxNominators as int,
    );
    assert(newMaxNmRaw >= 0 && newMaxNmRaw <= 1023, 114);
    // SAFETY: range-checked above to fit uint10.
    val newMaxNm = newMaxNmRaw as uint10;
    val newMinStake = promptCoins(
        "MIN_STAKE",
        "Min nominator stake (TON):",
        coinsToTonString(nominators.minStake),
    );
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins("MSG_VALUE", "Message value (TON):", "1");

    println(
        "Updating nominator limits: maxNominators={} minStake={:gram}",
        newMaxNm,
        newMinStake,
    );

    val res = pool.sendUpdateLimits(
        owner.address,
        queryId,
        GlobalNominatorsLimit {
            maxNm: newMaxNm,
            minStake: newMinStake,
        },
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("UpdateLimits (GlobalNominatorsLimit) message was not accepted by network");
    }

    val poolAfter = pool.getPoolData();
    val nominatorsAfter = lazy poolAfter.nominators.load();

    assertEqual(poolAfter.maxNominators, newMaxNm, "maxNominators");
    assertEqual(nominatorsAfter.minStake, newMinStake, "minStake");

    println("OK: nominator limits updated on pool {}", pool.address);
    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
