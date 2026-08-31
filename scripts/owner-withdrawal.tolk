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

    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins("MSG_VALUE", "Value to send with OwnerWithdrawal message (TON):", "1");

    // Use the on-chain get_shares_info getter: it mirrors the OwnerWithdrawal
    // handler's math, including the pending-deposits and pending-withdrawals
    // carve-outs and the halted/insolvent zeroing.
    var shares: GetSharesInfoResult?;
    shares = null;
    try {
        shares = pool.getSharesInfo();
    } catch (_e) {
        shares = null;
    }
    if (shares == null) {
        Assert.fail(
            "get_shares_info is not available on this pool; a current pool deployment is required",
        );
    }
    val sharesInfo = shares;
    val available = sharesInfo.liquidOwnerShare;

    println(
        "Owner equity: {:gram}, withdrawable now: {:gram}",
        sharesInfo.ownerShareValue,
        available,
    );

    if (available == 0) {
        println(
            "Nothing to withdraw right now (halted, insolvent, or equity fully capitalized), pool {}",
            pool.address,
        );
        return;
    }

    // The on-chain handler subtracts the incoming message value from the
    // available balance before applying the withdrawal cap, so the maximum
    // that can be withdrawn with THIS message is available - value.
    val maxWithdrawable = available > value ? available - value : 0 as coins;

    // AMOUNT env var overrides; otherwise prompt with the withdrawable maximum as default.
    val amountEnv = env<coins>("AMOUNT");
    var requested: coins;
    if (amountEnv != null) {
        requested = amountEnv;
    } else {
        // Use integer TON part as the default (good enough for a default; user can type exact amount).
        val defaultTonStr = format("{}", maxWithdrawable / 1000000000);
        val prompted = promptCoins(
            "AMOUNT_PROMPT",
            "Amount to withdraw (TON, empty = all available):",
            defaultTonStr,
        );
        // The prompt default returns the withdrawable maximum when user presses Enter.
        requested = prompted == 0 ? maxWithdrawable : prompted;
    }

    println(
        "Owner withdrawal: requested={:gram} available={:gram} max-with-this-message={:gram}",
        requested,
        available,
        maxWithdrawable,
    );

    confirmSend(
        format(
            "Owner withdrawal\n  pool:      {}\n  owner:     {}\n  requested: {:gram}\n  available: {:gram}\n  value:     {:gram}",
            pool.address,
            owner.address,
            requested,
            available,
            value,
        ),
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
        if (requested > available) {
            Assert.fail(
                format(
                    "OwnerWithdrawal succeeded but requested ({:gram}) exceeded available ({:gram})",
                    requested,
                    available,
                ),
            );
        }
        println(
            "OK: withdrew {:gram} from pool {} to owner {}",
            requested,
            pool.address,
            owner.address,
        );
    } else {
        // Expect a refund because requested exceeded the on-chain cap
        // (available minus the incoming message value).
        val refundTx = res.findTransaction<RefundMessage>({
            from: pool.address,
            to: owner.address,
        });
        if (refundTx == null) {
            Assert.fail(
                "OwnerWithdrawal was refused but no refund transaction was observed",
            );
        }
        val refundMsg = refundTx.loadBody<RefundMessage>();
        if (refundMsg.context.errorCode == 0) {
            Assert.fail("OwnerWithdrawal refund carried a zero error code");
        }
        if (!(requested > maxWithdrawable)) {
            Assert.fail(
                format(
                    "OwnerWithdrawal was refunded but requested ({:gram}) did not exceed the withdrawable maximum ({:gram})",
                    requested,
                    maxWithdrawable,
                ),
            );
        }
        println(
            "OK: withdrawal refused (error={}) since requested={:gram} > max-withdrawable={:gram}",
            refundMsg.context.errorCode,
            requested,
            maxWithdrawable,
        );
    }

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
