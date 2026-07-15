import "@stdlib/lisp-lists"
import "@stdlib/reflection"
import "@acton/build"
import "@acton/fmt"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/types/transaction"
import "@contracts/fees"
import "@contracts/messages"
import "@contracts/opcode"
import "@contracts/types"
import "@contracts/utils"
import "@tests/deploy-utils"
import "@tests/elector-utils"
import "@tests/matchers"
import "@tests/proxy-utils"
import "@tests/test-utils"
import "@tests/test-utils"
import "@wrappers/ElectorCode.gen"
import "@wrappers/PayoutItem.gen"
import "@wrappers/Pool.gen"
import "@wrappers/Proxy.gen"

fun assertPoolDepositInstant(pool: Pool, from: address, amount: coins) {
    val balanceBefore = testing.getAccountBalance(pool.address);
    val poolBefore = pool.getPoolData();
    val nominatorsBefore = poolBefore.nominators.load();

    var nmBefore = Nominator {
        share: 0,
        tonAmount: 0,
    };
    val nmLookup = nominatorsBefore.poolNominators.get(from);

    if (nmLookup.isFound) {
        nmBefore = nmLookup.loadValue();
    }

    // val res = pool.sendDepositMessage(from, {value:  amount});
    val res = net.send(
        from,
        createMessage({
            bounce: true,
            value: amount,
            dest: pool.address,
            body: beginCell().storeUint(0, 32).storeSlice("d".beginParse()),
        }),
    );
    res.giveName("Deposit request");

    val topUpTx = res.findTransaction({ to: pool.address, from, value: amount });
    assert(topUpTx != null, 42);
    val txStorage = getTxStorage(topUpTx);

    expect(res).toHaveTx(
        {
            to: from,
            from: pool.address,
            value: fun(amount: coins): bool {
                return amount < DEPOSIT_GAS;
            },
        },
    );

    val expIncrease = amount - DEPOSIT_GAS;
    val expShareInc = mulDivQuiet(expIncrease, poolBefore.poolSupply, poolBefore.nominatorsAmount);
    val poolAfter = pool.getPoolData();

    expect(poolAfter.nominatorsAmount).toEqual(poolBefore.nominatorsAmount + expIncrease);
    expect(poolAfter.poolSupply).toEqual(poolBefore.poolSupply + expShareInc);

    if (!nmLookup.isFound) {
        val nominators = poolAfter.nominators.load();
        expect(nominators.nmCount).toEqual(nominatorsBefore.nmCount + 1);
    }

    val balanceAfter = testing.getAccountBalance(pool.address);
    expect(balanceAfter).toEqual(balanceBefore + expIncrease - txStorage.storageFeesCollected);

    val nmAfter = pool.getNominatorData(from.getWorkchainAndHash().1);

    val initialShare = mulDivQuiet(
        nmBefore.share,
        poolBefore.nominatorsAmount,
        poolBefore.poolSupply,
    );

    expect(nmAfter.amount as int).toBeApproxEqAbs(initialShare + expIncrease, 1);
}

fun waitTillRecovery(pool: Pool, validator: address, elector: address): GetValidatorInfo {
    val curUsage = pool.getValidatorInfo(validator);
    if (curUsage.usage.prevRoundUsage == null) {
        Assert.fail(format("No recoverable usage record found {}", curUsage.usage));
    }

    val usage = curUsage.usage.prevRoundUsage!.usage;
    testing.setNow(usage.heldFor + usage.rotation.rotationTime + 61);
    testing.runTickTock(elector, true);
    testing.runTickTock(elector, true);
    return curUsage;
}

fun waitAndRecoverStake(pool: Pool, validator: address, elector: address): SendResultList {
    waitTillRecovery(pool, validator, elector);
    return pool.sendRecoverStakeCompat(validator, DEFAULT_QUERY_ID, { value: ton("1") });
}

fun setupPoolWithNominators(n: int = 10): (Pool, Treasury, Treasury, address, lisp_list<address>) {
    var (pool, owner, notOwner, validator) = setupDeployedPool();

    val minDepo = pool.getNominatorMinimalStake();
    var newNominators: lisp_list<address> = [];

    repeat (n) {
        val newAddress = address.fromWorkchainAndHash(BASECHAIN, random.uint256());
        val depoAmount = random.range(ton("100000")) + minDepo.minExpectedValue;
        newNominators.prependHead(newAddress);

        assertPoolDepositInstant(pool, newAddress, depoAmount);
    }

    val poolAfter = pool.getPoolData();
    val nominators = poolAfter.nominators.load();
    expect(nominators.nmCount).toEqual(n);

    return (pool, owner, notOwner, validator, newNominators);
}

fun setupFullyBookedPool(): (
    Pool,
    Treasury,
    Treasury,
    address,
    address,
    lisp_list<address>,
) {
    // Idea here is to create a maxed out pool
    // 127 validators + 1023 nominators
    // To test gas consumption at a maximum.

    var (pool, owner, notOwner, mainValidator, nominators) = setupPoolWithNominators(1023);

    val randomPickedIdx = random.range(127);
    var randomPickedValidator: address? = null;
    var curIdx = 0;
    repeat (127) {
        val newAddress = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());
        if (curIdx == randomPickedIdx) {
            randomPickedValidator = newAddress;
        }
        val res = pool.sendAddValidator(
            owner.address,
            42,
            newAddress,
            RoundAllowance.InAllRounds,
            null,
            { value: ton("1000") },
        );
        expect(res).toHaveRefund<AddValidator>({ from: pool.address, to: owner.address, error: 0 });
        res.giveName("Add validator");

        try {
            pool.getValidatorInfo(newAddress); // Would throw if not added
        } catch (_e) {
            Assert.fail("Failed to add validator");
        }
        curIdx += 1;
    }

    return (
        pool,
        owner,
        notOwner,
        mainValidator,
        randomPickedValidator!,
        nominators,
    );
}

fun assertPoolNewStake(
    validator: address,
    pool: Pool,
    elector: ElectorCode,
    elections: int,
    stake: coins,
): (RoundData, TonUsage, uint256) {
    val poolBefore = pool.getPoolData();

    val signedBody = getSignedBody(elections);
    val valInfoBefore = pool.getValidatorInfo(validator);
    val expectedProxy = getProxy(pool.address, validator, valInfoBefore.roundIndex % 2 > 0);
    val res = pool.sendNewStake(
        validator,
        DEFAULT_QUERY_ID,
        stake,
        signedBody,
        { value: ton("1") },
    );

    val validators = poolBefore.validators.load();

    val curRoundBefore = validators.curRound.load();
    val newStakeOk = reflect.serializationPrefixOf<NewStakeOk>().0;
    val _stakeTx = res.findTransaction<NewStake>({ from: validator, to: pool.address });
    val refundTx = res.findTransaction({
        to: validator,
        from: pool.address,
        opcode: opcode<RefundMessage>(),
    });
    if (refundTx != null) {
        val _refundMsg = refundTx.loadBody<RefundMessage>();
        // println("Refund msg {}", refundMsg);
    }
    expect(
        res,
    ).toHaveSuccessfulTx({ from: elector.address, to: expectedProxy.address, opcode: newStakeOk });
    expect(
        res,
    ).toHaveSuccessfulTx({ to: pool.address, from: expectedProxy.address, opcode: newStakeOk });

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    val curRound = validatorsAfter.curRound.load();
    expect(validatorsAfter.activeSlots).toEqual(validators.activeSlots + 1);
    expect(validatorsAfter.stakeUsed).toEqual(validators.stakeUsed + stake - ton("1"));
    // If new stake rotated the rounds
    if (valInfoBefore.rotated) {
        expect(curRound.used).toEqual(stake - ton("1"));
        expect(curRound.returned).toEqual(0);
        expect(validatorsAfter.vsetHash).toNotEqual(validators.vsetHash);
    } else {
        expect(curRound.used).toEqual(curRoundBefore.used + stake - ton("1"));
        expect(curRound.returned).toEqual(curRoundBefore.returned);
    }
    val curStake = curRound.users.get(expectedProxy.address.getHash());
    expect(curStake.isFound).toBeTrue();
    val stakeData = curStake.loadValue();
    expect(stakeData.tonUsed).toEqual(stake - ton("1"));
    expect(stakeData.validator).toEqual(validator);
    expect(stakeData.rotation.vsetHash).toEqual(
        testing.getConfig().getParamRaw(CUR_VSET_IDX).hash(),
    );
    expect(stakeData.rotation.rotationCount).toEqual(0);
    expect(stakeData.rotation.rotationTime).toEqual(testing.getNow());

    return (curRound, curStake.loadValue(), expectedProxy.address.getHash());
}

fun assertNewStakeFailed(
    errCode: int,
    validator: address,
    pool: Pool,
    _elector: address,
    elections: int,
    stake: coins,
) {
    val poolBefore = pool.getPoolData();
    val stateBefore = getAccountData(pool.address);
    val balanceBefore = testing.getAccountBalance(pool.address);
    val signedBody = getSignedBody(elections);
    val res = pool.sendNewStake(
        validator,
        DEFAULT_QUERY_ID,
        stake,
        signedBody,
        { value: ton("1") },
    );

    val stakeTx = res.findTransaction(
        {
            from: validator,
            to: pool.address,
            opcode: reflect.serializationPrefixOf<NewStake>().0,
        },
    )!;
    expect(stakeTx != null).toBeTrue();
    expect(stakeTx.outmsgCnt == 1);
    expect(res).toHaveRefund<NewStake>({
        from: pool.address,
        to: validator,
        error: errCode,
        initialBalance: balanceBefore,
        previousState: stateBefore,
    });

    val poolAfter = pool.getPoolData();
    expect(poolAfter).toEqual(poolBefore);
}

fun runRound(
    pool: Pool,
    elector: ElectorCode,
    stakes: StakesConfig,
    limits: ParticipantsConfig,
    validator: address,
    elections: int = 0,
    expectCloseAfter: bool = false,
    stake: coins? = null,
) {
    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    val _mainBefore = validators.mainValidatorData.load();
    var curBefore: ValidatorUsageRecords? = null;

    curBefore = pool.getValidatorInfo(validator).usage;

    if (stake == null) {
        stake = validators.minTonPerValidator + ton("1000");
    }

    if (elections == 0) {
        elections = announceElections(elector);
    }
    var (curRound, curStake, curProxy) = assertPoolNewStake(
        validator,
        pool,
        elector,
        elections,
        stake,
    );
    runElections(elector, stakes, limits);

    val res = pool.sendUpdateVset(validator, 123, { value: ton("1") });

    expect(res).toHaveSuccessfulTx({ from: validator, to: pool.address });
    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    val curVsetHash = testing.getConfig().getParamRaw(CUR_VSET_IDX).hash();
    expect(poolAfter.roundClosed).toEqual(expectCloseAfter);

    if (!expectCloseAfter) {
        expect(poolAfter.roundIndex).toEqual(poolBefore.roundIndex + 1);
        expect(validatorsAfter.vsetHash == curVsetHash >> 128);
        val prevRound = validatorsAfter.prevRound.load();
        expect(prevRound.used).toEqual(curRound.used);
        expect(prevRound.roundIndex).toEqual(curRound.roundIndex);

        val stakeLookup = prevRound.users.get(curProxy);
        expect(stakeLookup.isFound).toBeTrue();
        val stakeData = stakeLookup.loadValue();
        expect(stakeData.tonUsed).toEqual(curStake.tonUsed);
        expect(stakeData.validator).toEqual(curStake.validator);
        expect(stakeData.heldFor).toEqual(curStake.heldFor);
        expect(stakeData.rotation.vsetHash).toNotEqual(curStake.rotation.vsetHash);
        expect(stakeData.rotation.vsetHash).toEqual(curVsetHash);
    } else {
        expect(poolAfter.roundIndex).toEqual(poolBefore.roundIndex);
        expect(validatorsAfter.vsetHash == validators.vsetHash);
        val freshCurRound = validatorsAfter.curRound.load();
        val stakeLookup = freshCurRound.users.get(curProxy);
        expect(stakeLookup.isFound).toBeTrue();
        val stakeData = stakeLookup.loadValue();
        expect(stakeData.tonUsed).toEqual(curStake.tonUsed);
        expect(stakeData.validator).toEqual(curStake.validator);
        expect(stakeData.heldFor).toEqual(curStake.heldFor);
        expect(stakeData.rotation.vsetHash).toNotEqual(curStake.rotation.vsetHash);
        expect(stakeData.rotation.vsetHash).toEqual(curVsetHash);
        expect(stakeData.rotation.rotationTime).toNotEqual(curStake.rotation.rotationTime);
        expect(stakeData.rotation.rotationTime).toEqual(testing.getNow());
        expect(stakeData.rotation.rotationCount).toEqual(curStake.rotation.rotationCount + 1);
    }
}

fun setupPoolWithProfits(nominatorCount: int, roundsRun: int): (
    Pool,
    Treasury,
    Treasury,
    address,
    lisp_list<address>,
    SendResultList,
) {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, notOwner, validator, nominators) = setupPoolWithNominators(nominatorCount);

    var res: SendResultList? = null;
    if (roundsRun == 0) {
        Assert.fail("At least 1 round has to run");
    }
    repeat (roundsRun) {
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
        res = waitAndRecoverStake(pool, validator, elector.address);
    }
    return (
        pool,
        owner,
        notOwner,
        validator,
        nominators,
        res!,
    );
}

fun setupRandomValidator(
    pool: Pool,
    owner: address,
    limit: ValidatorLimit? = null,
    allowance: RoundAllowance = RoundAllowance.InAllRounds,
): address {
    val newAddress = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());

    val res = pool.sendAddValidator(
        owner,
        DEFAULT_QUERY_ID,
        newAddress,
        allowance,
        limit,
        { value: ton("1000") },
    );
    expect(res).toHaveRefund<AddValidator>({ from: pool.address, to: owner, error: 0 });

    try {
        pool.getValidatorInfo(newAddress); // Would throw if not added
    } catch (_e) {
        Assert.fail("Failed to add validator");
    }
    return newAddress;
}

fun assertDelayedOperation(
    pool: Pool,
    nm: address,
    isWithdrawal: bool = true,
    tonAmount: coins = 0,
): (PayoutItem, coins) {
    val balanceBefore = testing.getAccountBalance(pool.address);
    val poolBefore = pool.getPoolData();
    val nominators = poolBefore.nominators.load();
    var expectedIndex = 1;
    var operations: PendingOps? = null;
    var operationDelta: int;
    val rawLookup = nominators.poolNominators.get((nm));
    var rawDataBefore = Nominator {
        share: 0,
        tonAmount: 0,
        pendingDeposit: 0,
    };
    if (rawLookup.isFound) {
        rawDataBefore = rawLookup.loadValue();
    }
    //val rawDataBefore = nominators.poolNominators.mustGet(nm, 42);
    var comment: slice;
    var resultName: string;
    var incomingValue: coins;

    if (isWithdrawal) {
        if (tonAmount == 0) {
            tonAmount = WITHDRAWAL_GAS;
        }
        operationDelta = rawDataBefore.share;
        incomingValue = tonAmount;
        comment = "w".beginParse();
        resultName = "Withdrawal request delayed";
        if (nominators.pendingWithdrawals != null) {
            operations = nominators.pendingWithdrawals.load();
            expectedIndex = operations.index + 1;
        }
    } else {
        if (tonAmount == 0) {
            tonAmount = pool.getNominatorMinimalStake().minExpectedValue;
        }
        incomingValue = tonAmount - DEPOSIT_GAS;
        operationDelta = incomingValue;
        comment = "d".beginParse();
        resultName = "Deposit request delayed";
        if (nominators.pendingDeposits != null) {
            operations = nominators.pendingDeposits.load();
            expectedIndex = operations.index + 1;
        }
    }

    val res = net.send(
        nm,
        createMessage({
            bounce: true,
            dest: pool.address,
            value: tonAmount,
            body: beginCell().storeUint(0, 32).storeSlice(comment).endCell(),
        }),
    );
    res.giveName(resultName);
    // println(res);
    val refundTx = res.findTransaction<RefundMessage>({ from: pool.address });
    if (refundTx != null) {
        // println(refundTx.loadBody<RefundMessage>());
    }

    val poolAfter = pool.getPoolData();
    val newPayoutState = AutoDeployAddress {
        stateInit: ContractState {
            data: ItemStorageNotInitialized {
                data: StaticData {
                    pool: pool.address,
                    index: expectedIndex,
                    roundIndex: poolAfter.roundIndex,
                    isWithdrawal,
                    next: null,
                    prev: null,
                },
            }.toCell(),
            code: build("PayoutItem"),
        },
        toShard: { fixedPrefixLength: 4, closeTo: pool.address },
    };

    val newPayout = PayoutItem.fromAddress(newPayoutState.calculateAddress());
    val sameShardAddress = newPayout
        .address
        .calculateSameAddressInAnotherShard({ fixedPrefixLength: 4, closeTo: pool.address });
    expect(newPayout.address).toEqual(sameShardAddress);
    expect(res).toHaveSuccessfulDeploy({
        from: pool.address,
        to: newPayout.address,
    });
    val deployTx = res.findTransaction({
        from: pool.address,
        to: newPayout.address,
        opcode: opcode<PayoutInitMessage>(),
    });

    expect(deployTx != null).toBeTrue();
    val storageTx = getTxStorage(deployTx!);
    val balanceAfter = testing.getAccountBalance(pool.address);
    if (isWithdrawal) {
        expect(balanceAfter - storageTx.storageFeesCollected).toEqual(balanceBefore);
    } else {
        expect(balanceAfter).toBeGreater(balanceBefore);
    }
    // println(res);

    val nmAfter = poolAfter.nominators.load();

    var opsAfter: Cell<PendingOps>? = null;
    if (isWithdrawal) {
        opsAfter = nmAfter.pendingWithdrawals;
    } else {
        opsAfter = nmAfter.pendingDeposits;
    }

    expect(opsAfter != null).toBeTrue();
    val opsParsed = opsAfter!.load();

    if (operations != null) {
        expect(opsParsed.pendingAmount).toEqual(operations.pendingAmount + operationDelta);
    } else {
        expect(opsParsed.pendingAmount).toEqual(operationDelta);
    }

    val rawDataAfter = nmAfter.poolNominators.mustGet(nm, 42);
    if (isWithdrawal) {
        expect(poolAfter.pendingWithdrawals).toEqual(
            poolBefore.pendingWithdrawals + rawDataBefore.share,
        );
        expect(rawDataAfter.pendingWithdrawal).toEqual(
            rawDataBefore.pendingWithdrawal + rawDataBefore.share,
        );
        expect(rawDataAfter.share).toEqual(0);
        expect(rawDataAfter.withdrawalIndex).toEqual(poolAfter.roundIndex + ROUNDS_DELAY);
    } else {
        expect(poolAfter.pendingDeposits).toEqual(poolBefore.pendingDeposits + incomingValue);
        expect(rawDataAfter.pendingDeposit).toEqual(rawDataBefore.pendingDeposit + incomingValue);
    }

    return (newPayout, rawDataBefore.share);
}

fun asssertSimpleWithdawal(pool: Pool, nm: address) {
    val nmData = pool.getNominatorData(nm.getWorkchainAndHash().1);
    val poolBefore = pool.getPoolData();
    val nominators = lazy poolBefore.nominators.load();
    val nmRaw = nominators.poolNominators.mustGet(nm, 42);

    val testValue = getRandomValue(ton("0.1"), ton("10"));

    val balanceBefore = testing.getAccountBalance(pool.address);
    val res = net.send(
        nm,
        createMessage({
            bounce: true,
            dest: pool.address,
            value: testValue,
            body: beginCell().storeUint(0, 32).storeSlice("w".beginParse()).endCell(),
        }),
    );
    // println(res);
    res.giveName("Withdrawal request simple");

    val balanceAfter = testing.getAccountBalance(pool.address);

    val reqTx = res.findTransaction({ to: pool.address, from: nm })!;
    val lumpPrice = testing.getConfig().getMsgForwardPrices(BASECHAIN).lumpPrice;
    val fwdFees = reqTx.outmsgCnt == 1 ? lumpPrice as coins : (lumpPrice * 2) as coins;
    expect(reqTx != null).toBeTrue();

    val withdrawalCompute = getTxComputePh(reqTx);
    val withdrawalStorage = getTxStorage(reqTx);

    val poolAfter = pool.getPoolData();
    val nmRawAfter = poolAfter.nominators.load();
    expect(nmRawAfter.nmCount).toEqual(nominators.nmCount - 1);
    expect(poolAfter.poolSupply).toEqual(poolBefore.poolSupply - nmRaw.share);
    expect(poolAfter.nominatorsAmount).toEqual(poolBefore.nominatorsAmount - nmData.amount);
    expect(balanceAfter).toEqual(
        balanceBefore - nmData.amount - withdrawalStorage.storageFeesCollected,
    );

    expect(res).toHaveTx({
        from: pool.address,
        to: nm,
        value: testValue + nmData.amount - withdrawalCompute.gasFees - fwdFees,
    });
}

fun getMaxOwnerShare(pool: Pool): int {
    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    val curBalance = testing.getAccountBalance(pool.address) - POOL_MIN_STORAGE -
    poolBefore.pendingDeposits;

    val fullBalance = curBalance + validators.stakeUsed;
    val ownerTheoreticalMax = fullBalance - poolBefore.nominatorsAmount -
    pool.getMaxPunishment(0) * validators.activeSlots;

    return min(curBalance, ownerTheoreticalMax);
}
