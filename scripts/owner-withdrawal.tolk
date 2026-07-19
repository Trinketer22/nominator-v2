import "@acton/env"
import "@acton/fmt"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/types/transaction"

import "@contracts/fees"
import "@contracts/messages"
import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

fun maxOwnerShare(pool: Pool): coins {
    val poolData = pool.getPoolData();
    val validators = lazy poolData.validators.load();
    val curBalance = testing.getAccountBalance(pool.address) - POOL_MIN_STORAGE -
    poolData.pendingDeposits;
    val fullBalance = curBalance + validators.stakeUsed;
    val ownerTheoreticalMax = fullBalance - poolData.nominatorsAmount -
    pool.getMaxPunishment(0) * validators.activeSlots;
    return min(curBalance, ownerTheoreticalMax);
}

fun main() {
    val pool = loadPool();
    val owner = poolOwner();

    val available = maxOwnerShare(pool);
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins("MSG_VALUE", "Value to send with OwnerWithdrawal message (TON):", "1");

    // AMOUNT env var overrides; otherwise prompt with the full available share as default.
    val amountEnv = env<coins>("AMOUNT");
    var requested: coins;
    if (amountEnv != null) {
        requested = amountEnv;
    } else {
        // Use integer TON part as the default (good enough for a default; user can type exact amount).
        val defaultTonStr = format("{}", available / 1000000000);
        val prompted = promptCoins(
            "AMOUNT_PROMPT",
            "Amount to withdraw (TON, empty = all available):",
            defaultTonStr,
        );
        // The prompt default returns the available amount when user presses Enter.
        requested = prompted == 0 ? available : prompted;
    }

    println(
        "Owner withdrawal: requested={:gram} available={:gram}",
        requested,
        available,
    );

    val res = pool.sendOwnerWithdrawal(
        owner.address,
        queryId,
        requested,
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("OwnerWithdrawal message was not accepted by network");
    }

    val successTx = res.findTransaction<OwnerWithdrawalSuccess>({
        from: pool.address,
        to: owner.address,
    });

    if (successTx != null) {
        assert(requested <= available, 230);
        println(
            "OK: withdrew {:gram} from pool {} to owner {}",
            requested,
            pool.address,
            owner.address,
        );
    } else {
        // Expect a refund because requested > available
        val refundTx = res.findTransaction<RefundMessage>({
            from: pool.address,
            to: owner.address,
        });
        assert(refundTx != null, 231);
        val refundMsg = refundTx.loadBody<RefundMessage>();
        assert(refundMsg.context.errorCode != 0, 232);
        assert(requested > available, 233);
        println(
            "OK: withdrawal refused (error={}) since requested={:gram} > available={:gram}",
            refundMsg.context.errorCode,
            requested,
            available,
        );
    }

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
