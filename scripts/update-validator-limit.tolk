import "@stdlib/strings"
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

    val validator = promptValidatorAddress("VALIDATOR_ADDRESS", "Enter validator address:");

    val limitKind = promptStringWithEnvOrSelect(
        "LIMIT_KIND",
        "Limit type:",
        ["ton", "share"],
        0,
    );
    var limit: ValidatorLimit;
    if (limitKind.equalTo("ton")) {
        val maxTon = promptCoins("MAX_TON", "Max TON for this validator:", "300000");
        limit = ValidatorLimitTon { maxTon };
    } else {
        val maxShare = promptIntWithEnvOrConst(
            "MAX_SHARE",
            "Max share (0..16777216):",
            SHARE_BASE / 2,
        );
        assert(maxShare >= 0 && maxShare <= SHARE_BASE, 114);
        // SAFETY: maxShare is range-checked above to fit uint25 (SHARE_BASE = 2^24 - 1).
        limit = ValidatorLimitShare { maxShare: maxShare as uint25 };
    }

    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins("MSG_VALUE", "Message value (TON):", "1");

    println("Updating per-validator limit for {} (kind={})", validator, limitKind);

    val res = pool.sendUpdateLimits(
        owner.address,
        queryId,
        ValidatorSpecific { validator, limit },
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("UpdateLimits (ValidatorSpecific) message was not accepted by network");
    }

    val poolAfter = pool.getPoolData();
    val validatorsAfter = lazy poolAfter.validators.load();
    val lookup = validatorsAfter.validators.get(validator);
    assert(lookup.isFound, 600);
    val rec = lookup.loadValue();

    var applied = false;
    var ok = false;
    match (limit) {
        ValidatorLimitTon => {
            if (rec.limit is ValidatorLimitTon) {
                applied = true;
                val got = rec.limit as ValidatorLimitTon;
                val expected = limit as ValidatorLimitTon;
                ok = got.maxTon == expected.maxTon;
            }
        }
        ValidatorLimitShare => {
            if (rec.limit is ValidatorLimitShare) {
                applied = true;
                val got = rec.limit as ValidatorLimitShare;
                val expected = limit as ValidatorLimitShare;
                ok = got.maxShare == expected.maxShare;
            }
        }
    }

    if (applied && ok) {
        println("OK: per-validator limit updated for {} on pool {}", validator, pool.address);
    } else {
        // The contract rejected the new limit (e.g. below global min, above global max,
        // or invalid share). Surface the refund error code for diagnostics.
        val refundTx = res.findTransaction<RefundMessage>({
            from: pool.address,
            to: owner.address,
        });
        assert(refundTx != null, 231);
        val refundMsg = refundTx.loadBody<RefundMessage>();
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
