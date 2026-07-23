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

    val (curMin, curMax, curRefund, curRefundBonus) = pool.getLimitsPerValidator();

    val minTonPerValidator = promptCoins(
        "MIN_TON_PER_VALIDATOR",
        "Min TON per validator:",
        coinsToTonString(curMin),
    );
    val maxTonPerValidator = promptCoins(
        "MAX_TON_PER_VALIDATOR",
        "Max TON per validator:",
        coinsToTonString(curMax),
    );
    val maxRefund = promptCoins(
        "MAX_REFUND",
        "Max refund to validator:",
        coinsToTonString(curRefund),
    );
    val refundBonus = promptCoins(
        "REFUND_BONUS",
        "Refund bonus to validator:",
        coinsToTonString(curRefundBonus),
    );
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins("MSG_VALUE", "Message value (TON):", "1");

    println(
        "Updating global validator limits: min={:gram} max={:gram} refund={:gram} bonus={:gram}",
        minTonPerValidator,
        maxTonPerValidator,
        maxRefund,
        refundBonus,
    );

    val res = pool.sendUpdateLimits(
        owner.address,
        queryId,
        GlobalValidatorsLimit {
            minTonPerValidator,
            maxTonPerValidator,
            maxRefund: maxRefund as uint33,
            refundBonus: refundBonus as uint33,
        },
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("UpdateLimits (GlobalValidatorsLimit) message was not accepted by network");
    }

    val (newMin, newMax, newRefund, newRefundBonus) = pool.getLimitsPerValidator();
    val ok = newMin == minTonPerValidator && newMax == maxTonPerValidator &&
    newRefund == maxRefund &&
    newRefundBonus == refundBonus;

    if (ok) {
        println("OK: global validator limits updated on pool {}", pool.address);
    } else {
        // The contract rejected the new limits (InvalidMaxMin, MinStakeBelowNetworkLimit,
        // MaxStakeAboveNetworkLimit, etc.). Surface the refund error code for diagnostics.
        val refundTx = res.findTransaction<RefundMessage>({
            from: pool.address,
            to: owner.address,
        });
        assert(refundTx != null, 231);
        val refundMsg = refundTx.loadBody<RefundMessage>();
        Assert.fail(
            format(
                "UpdateLimits (GlobalValidatorsLimit) rejected by contract: error code {}",
                refundMsg.context.errorCode,
            ),
        );
    }

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
