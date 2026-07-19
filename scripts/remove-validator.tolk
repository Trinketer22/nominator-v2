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

    val validator = promptValidatorAddress(
        "VALIDATOR_ADDRESS",
        "Enter validator address to remove:",
    );
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins("MSG_VALUE", "Value to send with RemoveValidator (TON):", "1");

    println("Removing validator {} from pool {}", validator, pool.address);

    val res = pool.sendRemoveValidator(
        owner.address,
        queryId,
        validator,
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("RemoveValidator message was not accepted by network");
    }

    // A validator with an outstanding stake is banned rather than deleted; check the
    // validators map directly since get_validator_info throws for banned-then-deleted
    // records.
    val poolData = pool.getPoolData();
    val validators = lazy poolData.validators.load();
    val lookup = validators.validators.get(validator);

    if (lookup.isFound) {
        val rec = lookup.loadValue();
        assert(rec.isBanned, 210);
        println(
            "Validator {} is banned (had outstanding stake); will be removed after recovery.",
            validator,
        );
    } else {
        println("OK: validator {} was removed from pool {}", validator, pool.address);
    }

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
