import "@stdlib/gas-payments"
import "@stdlib/lisp-lists"
import "@acton/io"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@contracts/errors"

import "@contracts/fees"
import "@contracts/messages"
import "@contracts/types"
import "@tests/elector-utils"
import "@tests/pool-utils"
import "@tests/test-utils"
import "@wrappers/PayoutItem.gen"
import "@wrappers/Pool.gen"

get fun `test chain of payout items could survive 5 years time and 10x gas price increase`() {
    val (elector, stakes, limits) = setupElector();
    val (
        pool,
        _owner,
        _notOwner,
        validator,
        _randomValidator,
        nominators,
    ) = setupFullyBookedPool();

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
    );

    var initialNominators = nominators;
    var testNominators: array<address> = [];
    val fiveYearsTime = 3600 * 24 * 365 * 5;

    var lastItem: address? = null;

    repeat (5) {
        val testNm = initialNominators.popHead();
        val (payout, _) = assertDelayedOperation(pool, testNm, true);
        lastItem = payout.address;
        testNominators.push(testNm);
    }

    testing.setNow(testing.getNow() + fiveYearsTime);

    var config = testing.getConfig();
    val prevPrices = config.getGasPrices(BASECHAIN);
    val pricesExt = prevPrices.other;
    val newPrices = GasPrices {
        flatGasLimit: prevPrices.flatGasLimit,
        flatGasPrice: prevPrices.flatGasPrice * 10,
        other: GasPricesExtended {
            gasPrice: pricesExt.gasPrice * 10,
            gasLimit: pricesExt.gasLimit,
            gasCredit: pricesExt.gasCredit,
            specialGasLimit: pricesExt.specialGasLimit,
            blockGasLimit: pricesExt.blockGasLimit,
            freezeDueLimit: pricesExt.freezeDueLimit,
            deleteDueLimit: pricesExt.deleteDueLimit,
        },
    };
    config.setGasPrices(newPrices, BASECHAIN);

    val oldFees = config.getMsgForwardPrices(BASECHAIN);

    val newFees = MsgForwardPrices {
        lumpPrice: oldFees.lumpPrice * 10,
        bitPrice: oldFees.bitPrice * 10,
        cellPrice: oldFees.cellPrice * 10,
        ihrPriceFactor: oldFees.ihrPriceFactor,
        firstFrac: oldFees.firstFrac,
        nextFrac: oldFees.nextFrac,
    };

    config.setMsgForwardPrices(newFees, BASECHAIN);
    testing.setConfig(config);

    val res = net.send(
        pool.address,
        createMessage({
            dest: lastItem!,
            bounce: false,
            value: PAYOUT_CHAIN_START - calculateForwardFee(BASECHAIN, 0, 0),
            body: PayoutBurnMessage {
                queryId: DEFAULT_QUERY_ID,
                distribution: { pendingShare: ton("1000"), pendingCoins: ton("20000") },
            },
        }),
    );

    println(res);
    repeat (5) {
        val testNm = testNominators.pop();
        expect(res).toHaveTx<WithdrawSuccess>({ from: pool.address, to: testNm });
    }
}

get fun `test arbitrary user can't trigger payout chain`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, notOwner, validator, nominators) = setupPoolWithNominators(40);

    val testNm = nominators.get(random.range(39));
    val nmHash = testNm.getWorkchainAndHash().1;
    val _nmBefore = pool.getNominatorData(nmHash);

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
    );

    val (withdrawalItem, _) = assertDelayedOperation(pool, testNm, true);
    val (depoItem, _) = assertDelayedOperation(pool, testNm, false);

    val testAddresses: array<address> = [testNm, owner.address, notOwner.address];
    var i = 2;

    while (i >= 0) {
        val curAddress = testAddresses.get(i);
        i -= 1;

        var res = net.send(
            curAddress,
            createMessage({
                bounce: false,
                value: DEFAULT_MSG_VALUE,
                dest: depoItem.address,
                body: PayoutBurnMessage {
                    queryId: DEFAULT_QUERY_ID,
                    distribution: { pendingShare: ton("1000"), pendingCoins: ton("2000") },
                },
            }),
        );

        expect(res).toNotHaveTx({ to: pool.address });
        expect(res).toHaveFailedTx<PayoutBurnMessage>({
            to: depoItem.address,
            exitCode: ErrorsPayout.InvalidSender,
        });

        res = net.send(
            curAddress,
            createMessage({
                bounce: false,
                value: DEFAULT_MSG_VALUE,
                dest: withdrawalItem.address,
                body: PayoutBurnMessage {
                    queryId: DEFAULT_QUERY_ID,
                    distribution: { pendingShare: ton("1000"), pendingCoins: ton("2000") },
                },
            }),
        );

        expect(res).toNotHaveTx({ to: pool.address });
        expect(res).toHaveFailedTx<PayoutBurnMessage>({
            to: withdrawalItem.address,
            exitCode: ErrorsPayout.InvalidSender,
        });
    }
}
