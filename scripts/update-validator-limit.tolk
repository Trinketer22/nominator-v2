import "@acton/env"
import "@acton/fmt"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"
import "@acton/types/transaction"

import "@contracts/messages"
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
        "Select validator to update the limit for:",
        true,
    );

    val limitOpt = promptValidatorLimit();
    if (limitOpt == null) {
        Assert.fail(
            "A per-validator limit must be selected (ton or share); 'none' clears the limit and is not supported by UpdateLimits (ValidatorSpecific)",
        );
    }
    val limit = limitOpt!;

    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins("MSG_VALUE", "Message value (TON):", "1");

    println("Updating per-validator limit for {}", validator);

    confirmSend(
        format(
            "Update per-validator limit\n  pool:       {}\n  validator:  {}\n  limit:      {}\n  value:      {:gram}",
            pool.address,
            validator,
            limit,
            value,
        ),
    );

    val res = pool.sendUpdateLimits(
        owner.address,
        queryId,
        ValidatorSpecific { validator, limit },
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("UpdateLimits (ValidatorSpecific) message was not accepted by network");
    }

    // Read the validator's record back from the persisted validators cell. We
    // account for the main validator (stored in mainValidatorData, NOT in the
    // validators map) as well as extra validators. The limit is compared by
    // cell hash because the ValidatorLimit union (ValidatorLimitTon |
    // ValidatorLimitShare) has no explicit opcodes, so deserializing it back
    // via `match` is unreliable off-chain.
    val rec = lookupValidatorRecord(pool, validator);
    if (rec == null) {
        Assert.fail(
            format(
                "Validator {} was not found in pool {} after UpdateLimits",
                validator,
                pool.address,
            ),
        );
    }
    val storedLimit = rec!.limit;

    val expectedLimitCell = (limit as ValidatorLimit).toCell();
    val applied = storedLimit != null && storedLimit!.toCell().hash() == expectedLimitCell.hash();

    if (applied) {
        println("OK: per-validator limit updated for {} on pool {}", validator, pool.address);
    } else {
        // The contract rejected the new limit (e.g. below global min, above global max,
        // or invalid share). A refund with errorCode=0 means success; only a non-zero
        // errorCode indicates an actual rejection.
        val refundTx = res.findTransaction<RefundMessage>({
            from: pool.address,
            to: owner.address,
        });
        if (refundTx == null) {
            Assert.fail(
                format(
                    "UpdateLimits (ValidatorSpecific) for {} was not applied and no refund transaction was observed",
                    validator,
                ),
            );
        }
        val refundMsg = refundTx.loadBody<RefundMessage>();
        if (refundMsg.context.errorCode == 0) {
            Assert.fail(
                format(
                    "UpdateLimits (ValidatorSpecific) for {} reported success (errorCode=0) but the limit was not stored as expected",
                    validator,
                ),
            );
        }
        Assert.fail(
            format(
                "UpdateLimits (ValidatorSpecific) rejected by contract: error code {}",
                refundMsg.context.errorCode,
            ),
        );
    }

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
