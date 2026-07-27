import "@acton/env"
import "@acton/fmt"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"

import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

fun main() {
    val poolAddress = promptPoolAddress();
    val pool = loadPool(poolAddress);
    val owner = poolOwner();

    val validator = promptValidatorPicker(
        pool,
        "VALIDATOR_ADDRESS",
        "Select validator to remove:",
        false,
    );
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins("MSG_VALUE", "Value to send with RemoveValidator (TON):", "1");

    println("Removing validator {} from pool {}", validator, pool.address);

    confirmSend(
        format(
            "Remove validator\n  pool:       {}\n  validator:  {}\n  value:      {:gram}",
            pool.address,
            validator,
            value,
        ),
    );

    val res = pool.sendRemoveValidator(
        owner.address,
        queryId,
        validator,
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("RemoveValidator message was not accepted by network");
    }

    // Read the post-remove state from the persisted validators cell. The main
    // validator cannot be removed (the contract rejects it with
    // MainValidatorCantBeRemoved), so only extra validators are relevant here.
    // We avoid get_validator_info because it calls rotateRound →
    // blockchain.configParam(34), which is unreliable off-chain (DEFAULT_CONFIG
    // in acton script) and may throw, masking the actual post-remove state.
    val poolData = pool.getPoolData();
    val validators = lazy poolData.validators.load();
    val lookup = validators.validators.get(validator);

    if (lookup.isFound) {
        val rec = lookup.loadValue();
        if (!rec.isBanned) {
            Assert.fail(
                format(
                    "Validator {} is still present and not banned after RemoveValidator",
                    validator,
                ),
            );
        }
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
