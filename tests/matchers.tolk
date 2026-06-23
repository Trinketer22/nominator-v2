import "@acton/build"
import "@acton/fmt"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@contracts/messages"
import "@contracts/opcode"
import "@contracts/types"
import "@tests/test-utils"

struct RefundParameters {
    to: address
    from: address
    error: int = 0
    opTxParams: SearchParams? = null
    queryId: int? = null
    value: coins? = null
    initialBalance: coins? = null
    previousState: cell? = null
}

struct RotationParams {
    pool: address
    address: address
    vsetHash: uint256
    prevCount: int
    time: uint32? = null
}

fun Expectation<RoundData>.toRotate(self, params: RotationParams) {
    val proxyAddress = AutoDeployAddress {
        stateInit: {
            code: build("Proxy"),
            data: ProxyStorage {
                pool: params.pool,
                validator: params.address,
                roundParity: self.value.roundIndex % 2 > 0,
            }.toCell(),
        },
        workchain: MASTERCHAIN,
    }.calculateAddress();
    val lookup = self.value.users.get(proxyAddress);
    if (!lookup.isFound) {
        Assert.fail(
            format("Validator {} not found at {}", params.address, self.value.users),
        );
    }

    val usageRec = lookup.loadValue();

    if (usageRec.rotation.vsetHash != params.vsetHash) {
        Assert.fail(
            format(
                "Expected vset {} for {} got {} ",
                params.vsetHash,
                params.address,
                usageRec.rotation.vsetHash,
            ),
        );
    }
    if (usageRec.rotation.rotationCount != params.prevCount + 1) {
        Assert.fail(
            format(
                "Expected rotation count {} for {} got {} ",
                params.prevCount + 1,
                params.address,
                usageRec.rotation.rotationCount,
            ),
        );
    }
    if (params.time != null && params.time != usageRec.rotation.rotationTime) {
        Assert.fail(
            format(
                "Expected rotation time {} for {} got {} ",
                params.time,
                params.address,
                usageRec.rotation.rotationTime,
            ),
        );
    }
}

fun Expectation<SendResultList>.toHaveRefund<T>(self, params: RefundParameters) {
    val op = opcode<T>();
    var operationTx: TlbTransaction?;
    val refundTx = self
        .value
        .findTransaction<RefundMessage>({
            from: params.from,
            to: params.to,
            value: params.value,
        });

    if (params.opTxParams == null) {
        params.opTxParams = {
            from: params.to,
            to: params.from,
            opcode: op,
        };
    }
    operationTx = self.value.findTransaction(params.opTxParams!);

    if (refundTx == null) {
        Assert.fail(format("Failed to find refund in {}", self.value));
    }
    if (operationTx == null) {
        Assert.fail(
            format(
                "Can't find operation transaction in {}, hint: specify opTxParams",
                self.value,
            ),
        );
    }
    val refundMsg: RefundMessage = refundTx.loadBody<RefundMessage>();
    if (refundMsg.context.op != op) {
        Assert.fail(format("Expected refund for op {} got {}", params, refundMsg));
    }
    if (params.queryId != null && params.queryId != refundMsg.context.queryId) {
        Assert.fail(
            format(
                "Expected queryId {} got {} {}",
                params.queryId,
                refundMsg.context.queryId,
                refundMsg,
            ),
        );
    }

    if (refundMsg.context.errorCode != params.error) {
        Assert.fail(
            format(
                "Expected refund for op {} error {} got {}",
                op,
                params.error,
                refundMsg,
            ),
        );
    }
    if (params.initialBalance != null) {
        val balanceAfter = testing.getAccountBalance(params.from);
        val storageTx = getTxStorage(operationTx);
        if (balanceAfter != params.initialBalance - storageTx.storageFeesCollected) {
            Assert.fail(
                format(
                    "Expected {} to preserve balance {} got {}",
                    params.from,
                    params.initialBalance,
                    balanceAfter,
                ),
            );
        }
    }
    if (params.previousState != null) {
        val stateAfter = getAccountData(params.from);
        expect(stateAfter.hash()).toEqual(params.previousState.hash());
    }
}
