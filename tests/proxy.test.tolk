import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@contracts/fees"
import "@contracts/messages"
import "@contracts/types"
import "@tests/elector-utils"
import "@tests/test-utils"
import "@wrappers/Proxy.gen"

fun setupProxyTestContext(): (Proxy, Treasury, Treasury, Treasury, address) {
    val (elector, _stakes, _limits) = setupElector();
    val validator = testing.treasury("validator");
    val otherWallet = testing.treasury("otherWallet");
    val pool = testing.treasury("pool");

    val proxy = Proxy.fromStorage({
        validator: validator.address,
        roundParity: false,
        pool: pool.address,
    });

    proxy.deploy(pool.address, { value: ton("100") });
    proxy.sendInitProxy(pool.address, DEFAULT_QUERY_ID, pool.address, { value: ton("100") });

    return (proxy, validator, otherWallet, pool, elector.address);
}

fun assertUnauthorizedMessageIsNotRelayed(
    proxy: Proxy,
    sender: address,
    pool: address,
    elector: address,
    body: cell,
) {
    val res = proxy.sendAny(sender, body, { value: ton("1"), bounce: true });
    expect(res).toHaveSuccessfulTx<ProxyRefundWrongSender>({
        from: proxy.address,
        to: sender,
    });
    expect(res.findTransaction({ from: proxy.address, to: pool }) == null).toBeTrue();
    expect(res.findTransaction({ from: proxy.address, to: elector }) == null).toBeTrue();
}

get fun `test proxy should only send elector<->pool`() {
    val (proxy, validator, otherWallet, pool, electorAddr) = setupProxyTestContext();

    val proxyData = ProxyResponseData {
        validator: validator.address,
        parity: false,
    };

    // Pool -> elector messages
    assertUnauthorizedMessageIsNotRelayed(
        proxy,
        otherWallet.address,
        pool.address,
        electorAddr,
        NewStake {
            queryId: DEFAULT_QUERY_ID,
            value: ton("10"),
            signedBody: beginCell().storeUint(0, 32).endCell().beginParse(),
        }.toCell(),
    );
    assertUnauthorizedMessageIsNotRelayed(
        proxy,
        otherWallet.address,
        pool.address,
        electorAddr,
        RecoverStakeCompat { queryId: DEFAULT_QUERY_ID }.toCell(),
    );

    // Elector -> pool messages
    assertUnauthorizedMessageIsNotRelayed(
        proxy,
        otherWallet.address,
        pool.address,
        electorAddr,
        NewStakeOk {
            queryId: DEFAULT_QUERY_ID,
            answer: 0,
            remaining: proxyData.toCell().beginParse(),
        }.toCell(),
    );
    assertUnauthorizedMessageIsNotRelayed(
        proxy,
        otherWallet.address,
        pool.address,
        electorAddr,
        NewStakeError {
            queryId: DEFAULT_QUERY_ID,
            reason: 0,
            remaining: proxyData.toCell().beginParse(),
        }.toCell(),
    );
    assertUnauthorizedMessageIsNotRelayed(
        proxy,
        otherWallet.address,
        pool.address,
        electorAddr,
        RecoverStakeOk {
            queryId: DEFAULT_QUERY_ID,
            remaining: proxyData.toCell().beginParse(),
        }.toCell(),
    );
    assertUnauthorizedMessageIsNotRelayed(
        proxy,
        otherWallet.address,
        pool.address,
        electorAddr,
        RecoverStakeError {
            queryId: DEFAULT_QUERY_ID,
            answer: 0,
            remaining: proxyData.toCell().beginParse(),
        }.toCell(),
    );
}

get fun `test NewStake from pool forwards full value and executes on proxy balance`() {
    val (proxy, validator, _otherWallet, pool, electorAddr) = setupProxyTestContext();
    val _proxyData = ProxyResponseData {
        validator: validator.address,
        parity: false,
    };

    val balanceAfterInit = testing.getAccountBalance(proxy.address);
    expect(balanceAfterInit as int).toBeApproxEqAbs(PROXY_MIN_STORAGE, ton("0.05"));

    val stakeValue = ton("1");
    val stakeRes = proxy.sendNewStake(
        pool.address,
        DEFAULT_QUERY_ID,
        stakeValue,
        beginCell().storeUint(0, 32).endCell().beginParse(),
        { value: stakeValue, bounce: true },
    );

    val forwardedStakeTx = stakeRes.findTransaction<NewStake>({
        from: proxy.address,
        to: electorAddr,
    });
    val inStakeTx = stakeRes.findTransaction<NewStake>({
        from: pool.address,
        to: proxy.address,
    });
    expect(forwardedStakeTx != null).toBeTrue();
    expect(inStakeTx != null).toBeTrue();
    val forwardedStakeMsg = forwardedStakeTx!.loadInMsg<NewStake>();
    expect(getInternalMessageValue(forwardedStakeMsg.info).grams).toEqual(stakeValue);
    expect(getTxComputePh(inStakeTx!).gasFees).toBeGreater(0);
    val balanceAfterNewStake = testing.getAccountBalance(proxy.address);
    expect(balanceAfterNewStake).toBeLess(balanceAfterInit);
    expect(balanceAfterNewStake).toBeGreater(PROXY_MIN_STORAGE / 2);
}

get fun `test elector non-recovery-ok messages should not burn proxy reserve`() {
    val (proxy, validator, _otherWallet, pool, electorAddr) = setupProxyTestContext();
    val proxyData = ProxyResponseData {
        validator: validator.address,
        parity: false,
    };

    var balanceBefore = testing.getAccountBalance(proxy.address);
    var res = net.send(
        electorAddr,
        createMessage({
            bounce: false,
            dest: proxy.address,
            value: ton("1"),
            body: NewStakeOk {
                queryId: DEFAULT_QUERY_ID,
                answer: 0,
                remaining: proxyData.toCell().beginParse(),
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<NewStakeOk>({ from: proxy.address, to: pool.address });
    var balanceAfter = testing.getAccountBalance(proxy.address);
    expect(balanceAfter as int).toBeApproxEqAbs(balanceBefore, ton("0.02"));

    balanceBefore = testing.getAccountBalance(proxy.address);
    res = net.send(
        electorAddr,
        createMessage({
            bounce: false,
            dest: proxy.address,
            value: ton("1"),
            body: NewStakeError {
                queryId: DEFAULT_QUERY_ID,
                reason: 0,
                remaining: proxyData.toCell().beginParse(),
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<NewStakeError>({ from: proxy.address, to: pool.address });
    balanceAfter = testing.getAccountBalance(proxy.address);
    expect(balanceAfter as int).toBeApproxEqAbs(balanceBefore, ton("0.02"));

    balanceBefore = testing.getAccountBalance(proxy.address);
    res = net.send(
        electorAddr,
        createMessage({
            bounce: false,
            dest: proxy.address,
            value: ton("1"),
            body: RecoverStakeError {
                queryId: DEFAULT_QUERY_ID,
                answer: 0,
                remaining: proxyData.toCell().beginParse(),
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<RecoverStakeError>({ from: proxy.address, to: pool.address });
    balanceAfter = testing.getAccountBalance(proxy.address);
    expect(balanceAfter as int).toBeApproxEqAbs(balanceBefore, ton("0.02"));
}

get fun `test NewStakeError with enough value replenishes proxy balance`() {
    val (proxy, validator, _otherWallet, pool, electorAddr) = setupProxyTestContext();
    val proxyData = ProxyResponseData {
        validator: validator.address,
        parity: false,
    };

    val balanceStart = testing.getAccountBalance(proxy.address);
    expect(balanceStart).toEqual(PROXY_MIN_STORAGE);

    // 10 NewStakes are forwarded to elector (PAY_FEES_SEPARATELY uses proxy reserve for gas)
    repeat (10) {
        val stakeRes = proxy.sendNewStake(
            pool.address,
            DEFAULT_QUERY_ID,
            ton("1"),
            beginCell().storeUint(0, 32).endCell().beginParse(),
            { value: ton("1"), bounce: true },
        );
        expect(stakeRes).toHaveSuccessfulTx<NewStake>({ from: proxy.address, to: electorAddr });
    }
    val balanceAfterStakes = testing.getAccountBalance(proxy.address);
    // Balance may not drop if bounces return the value, but should never exceed start
    expect(balanceAfterStakes).toBeLess(balanceStart);

    // 10 NewStakeErrors from elector with enough value (>= PROXY_MIN_STORAGE * 2)
    // trigger replenish, restoring proxy to PROXY_MIN_STORAGE
    repeat (10) {
        val res = net.send(
            electorAddr,
            createMessage({
                bounce: false,
                dest: proxy.address,
                value: ton("20"),
                body: NewStakeError {
                    queryId: DEFAULT_QUERY_ID,
                    reason: 0,
                    remaining: proxyData.toCell().beginParse(),
                },
            }),
        );
        expect(res).toHaveSuccessfulTx<NewStakeError>({ from: proxy.address, to: pool.address });
    }
    val balanceAfterReplenish = testing.getAccountBalance(proxy.address);
    expect(balanceAfterReplenish).toEqual(PROXY_MIN_STORAGE);
}

get fun `test RecoverStakeOk with enough value replenishes proxy storage reserve`() {
    val (proxy, validator, _otherWallet, pool, electorAddr) = setupProxyTestContext();
    val proxyData = ProxyResponseData {
        validator: validator.address,
        parity: false,
    };

    // Spend some reserve first, so replenishment is meaningful.
    proxy.sendNewStake(
        pool.address,
        DEFAULT_QUERY_ID,
        ton("1"),
        beginCell().storeUint(0, 32).endCell().beginParse(),
        { value: ton("1"), bounce: true },
    );
    val balanceBeforeReplenish = testing.getAccountBalance(proxy.address);
    expect(balanceBeforeReplenish).toBeLessOrEqual(PROXY_MIN_STORAGE);

    val res = net.send(
        electorAddr,
        createMessage({
            bounce: false,
            dest: proxy.address,
            value: PROXY_MIN_STORAGE * 2 + ton("1"),
            body: RecoverStakeOk {
                queryId: DEFAULT_QUERY_ID,
                remaining: proxyData.toCell().beginParse(),
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ from: proxy.address, to: pool.address });
    val balanceAfterReplenish = testing.getAccountBalance(proxy.address);
    expect(balanceAfterReplenish).toEqual(PROXY_MIN_STORAGE);
}

get fun `test low RecoverStakeOk uses proxy balance and sends minimum`() {
    val (proxy, validator, _otherWallet, pool, electorAddr) = setupProxyTestContext();
    val proxyData = ProxyResponseData {
        validator: validator.address,
        parity: false,
    };

    val lowValue = ton("0.05");
    val beforeLowRecover = testing.getAccountBalance(proxy.address);
    val res = net.send(
        electorAddr,
        createMessage({
            bounce: false,
            dest: proxy.address,
            value: lowValue,
            body: RecoverStakeOk {
                queryId: DEFAULT_QUERY_ID,
                remaining: proxyData.toCell().beginParse(),
            },
        }),
    );

    val lowRecoverForwardTx = res.findTransaction<RecoverStakeOk>({
        from: proxy.address,
        to: pool.address,
    });
    expect(lowRecoverForwardTx != null).toBeTrue();
    val lowRecoverForwardMsg = lowRecoverForwardTx!.loadInMsg<RecoverStakeOk>();
    expect(getInternalMessageValue(lowRecoverForwardMsg.info).grams).toEqual(ton("0.1"));
    val afterLowRecover = testing.getAccountBalance(proxy.address);
    expect(afterLowRecover).toBeLess(beforeLowRecover);
}

get fun `test if timestamp is below mc timestamp return RecoverStakeError`() {
    val (proxy, validator, _otherWallet, pool, electorAddr) = setupProxyTestContext();

    val curTime = testing.getNow();
    expect(curTime).toNotEqual(0);

    var aboveExp: array<int> = [0, 1, random.range(1000) + 10];

    repeat (3) {
        val curDelta = aboveExp.pop();
        var res = net.send(
            pool.address,
            createMessage({
                bounce: false,
                value: ton("1"),
                dest: proxy.address,
                body: RecoverStakeCompat { queryId: curTime + curDelta },
            }),
        );

        expect(res).toHaveTx<RecoverStakeError>({ from: proxy.address, to: pool.address });
        expect(res).toNotHaveTx({ to: electorAddr });
    }

    // timestamp from the past should succeed
    var belowExp: array<int> = [1, random.range(1000) + 10];
    repeat (2) {
        val curDelta = belowExp.pop();
        val res = net.send(
            pool.address,
            createMessage({
                bounce: false,
                value: ton("1"),
                dest: proxy.address,
                body: RecoverStakeCompat { queryId: curTime - curDelta },
            }),
        );
        expect(res).toHaveSuccessfulTx({ to: electorAddr, from: proxy.address });
    }
}

get fun `test bounced NewStake should be forwarded to pool as NewStakeError`() {
    val (proxy, _validator, _otherWallet, pool, electorAddr) = setupProxyTestContext();
    val newStake = NewStake {
        queryId: DEFAULT_QUERY_ID,
        value: ton("100000"),
        signedBody: "test".beginParse(),
    };

    val bouncedBody = beginCell()
        .storeUint(0xFFFFFFFF, 32)
        .storeSlice(newStake.toCell().beginParse());
    val res = net.send(
        electorAddr,
        createMessage({
            bounce: false,
            value: ton("1"),
            dest: proxy.address,
            body: bouncedBody,
        }).bounced(),
    );

    expect(res).toHaveTx<NewStakeError>({ from: proxy.address, to: pool.address });
}

get fun `test bounced RecoverStakeCompat should be forwarded to pool as RecoverStakeError`() {
    val (proxy, _validator, _otherWallet, pool, electorAddr) = setupProxyTestContext();
    val recoverStake = RecoverStakeCompat { queryId: DEFAULT_QUERY_ID };

    val bouncedBody = beginCell()
        .storeUint(0xFFFFFFFF, 32)
        .storeSlice(recoverStake.toCell().beginParse());
    val res = net.send(
        electorAddr,
        createMessage({
            bounce: false,
            value: ton("1"),
            dest: proxy.address,
            body: bouncedBody,
        }).bounced(),
    );

    expect(res).toHaveTx<RecoverStakeError>({ from: proxy.address, to: pool.address });
}
