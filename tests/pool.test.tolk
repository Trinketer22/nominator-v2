import "@stdlib/gas-payments"
import "@stdlib/lisp-lists"
import "@stdlib/tvm-lowlevel"
import "@acton/io"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"
import "@acton/tlb/maybe"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/errors"

import "@contracts/fees"
import "@contracts/messages"
import "@contracts/opcode"
import "@contracts/types"
import "@contracts/utils"
import "@tests/deploy-utils"
import "@tests/elector-utils"
import "@tests/matchers"
import "@tests/pool-utils"
import "@tests/test-utils"
import "@wrappers/ElectorCode.gen"
import "@wrappers/PayoutItem.gen"
import "@wrappers/Pool.gen"

@test.fuzz(10)
get fun `test simple pool deposit`(nmAddress: address, nmStake: coins) {
    var (pool, _owner, _notOwner, _validaotr) = setupDeployedPool();
    val (_, _validatorSettings, nmSettings) = defaultDeployParams();
    val boundStake = fuzz.bound(nmStake, nmSettings.minStake + DEPOSIT_GAS, ton("100000"));
    assertPoolDepositInstant(pool, nmAddress, boundStake);

    val nmHash = nmAddress.getWorkchainAndHash().1;
    val nmBefore = pool.getNominatorData(nmHash);
    expect(nmBefore.amount).toEqual(boundStake - DEPOSIT_GAS);
    var additional = 0;

    // Theese 3 deposits should stack on each other
    repeat (3) {
        val randomAmount = random.range(ton("100000")) + nmSettings.minStake + DEPOSIT_GAS;
        additional += randomAmount - DEPOSIT_GAS;
        assertPoolDepositInstant(pool, nmAddress, randomAmount);
    }

    val nmAfter = pool.getNominatorData(nmHash);
    expect(nmAfter.amount).toEqual(nmBefore.amount + additional);
}

get fun `test existing nominator should be able to deposit in full pool`() {
    val (_, _validatorSettings, nmSettings) = defaultDeployParams();
    val (
        pool,
        _owner,
        _notOwner,
        _validator,
        _randomValidator,
        nominators,
    ) = setupFullyBookedPool();

    val randomNm = nominators.get(random.range(1022));
    val nmHash = randomNm.getHash();

    val nmBefore = pool.getNominatorData(nmHash);
    var additional = 0;

    repeat (3) {
        val randomAmount = random.range(ton("100000")) + nmSettings.minStake + DEPOSIT_GAS;
        additional += randomAmount - DEPOSIT_GAS;
        assertPoolDepositInstant(pool, randomNm, randomAmount);
    }

    val nmAfter = pool.getNominatorData(nmHash);
    expect(nmAfter.amount).toEqual(nmBefore.amount + additional);
}

get fun `test should not allow deposits below the minStake + DEPOSIT_GAS`() {
    var (pool, _owner, _notOwner, _validaotr) = setupDeployedPool();
    val testNm = testing.treasury("testnm");

    val (_ownerShare, _valSetting, nmSettings) = defaultDeployParams();

    val requiredValue = pool.getNominatorMinimalStake();
    expect(requiredValue.minExpectedValue).toEqual(nmSettings.minStake + DEPOSIT_GAS);
    var res = pool.sendTextComment(
        testNm.address,
        "d".beginParse(),
        { value: requiredValue.minExpectedValue - 1 },
    );

    expect(res).toHaveRefund<TextComment>({
        to: testNm.address,
        from: pool.address,
        error: ErrorsPool.NotEnoughGas,
    });

    res = pool.sendTextComment(
        testNm.address,
        "d".beginParse(),
        { value: requiredValue.minExpectedValue },
    );

    expect(res).toHaveTx<DepositSuccess>({ from: pool.address, to: testNm.address });
    val amountAfter = pool.getNominatorData(testNm.address.getWorkchainAndHash().1);
    expect(amountAfter.amount).toEqual(nmSettings.minStake);
}

get fun `test text comment messages should be parsed strictly`() {
    val (_elector, _stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, _validator, nominators) = setupPoolWithNominators(10);

    var testNominators = nominators;
    val testNominator = testNominators.popHead();

    val stateBefore = getAccountData(pool.address);

    // Cell underflow will trigger, because parser finds the exitsing prefix, but data left in the cell
    val underflowPrefixes: array<string> = ["dadada", "wawawa", "rarara"];
    val validPrefixes: array<string> = ["d", "w", "r"];
    var prefixIdx = 0;
    repeat (3) {
        val testPfx = underflowPrefixes.get(prefixIdx);
        val res = pool.sendTextComment(testNominator, testPfx.beginParse());
        expect(res).toHaveRefund<TextComment>({
            from: pool.address,
            to: testNominator,
            previousState: stateBefore,
            error: VmExitCode.CellUnderflow,
        });
        prefixIdx += 1;
    }

    prefixIdx = 0;

    repeat (3) {
        val tailPfx = underflowPrefixes.get(prefixIdx);
        val testPfx = beginCell()
            .storeSlice(validPrefixes.get(prefixIdx).beginParse())
            .storeRef(tailPfx.toCell())
            .endCell();

        val res = pool.sendTextComment(testNominator, testPfx.beginParse());
        expect(res).toHaveRefund<TextComment>({
            from: pool.address,
            to: testNominator,
            previousState: stateBefore,
            error: VmExitCode.CellUnderflow,
        });
    }

    // Completely invalid prefix will return InvalidMessage
    val res = pool.sendTextComment(testNominator, "ToTheM00n".beginParse());

    expect(res).toHaveRefund<TextComment>({
        from: pool.address,
        to: testNominator,
        error: ErrorsPool.InvalidMessage,
    });

    repeat (3) {}
}

get fun `test pool has a limit of 1023 nominators`() {
    val (
        pool,
        _owner,
        _notOwner,
        _validator,
        _randomValidator,
        _nominators,
    ) = setupFullyBookedPool();

    val testNm = testing.treasury("testNm");

    val poolBefore = pool.getPoolData();
    val nmBefore = poolBefore.nominators.load();
    expect(nmBefore.nmCount).toEqual(1023);
    val res = pool.sendTextComment(
        testNm.address,
        "d".beginParse(),
        { value: ton("1000000") },
    );

    expect(res).toHaveRefund<TextComment>({
        to: testNm.address,
        from: pool.address,
        error: ErrorsPool.TooManyNominators,
    });
}

get fun `test nominator from masterchain should be allowed`() {
    var (pool, _owner, _notOwner, _validaotr) = setupDeployedPool();
    val bcNominator = randomAddress("Test nominator", BASECHAIN);
    val mcNominator = randomAddress("Test nominator", MASTERCHAIN);

    val minValue = pool.getNominatorMinimalStake().minExpectedValue;
    val maxValue = ton("100000");
    val depoBc = getRandomValue(minValue, maxValue);
    val depoMc = getDifferentValue(depoBc, minValue, maxValue);

    assertPoolDepositInstant(pool, bcNominator, depoBc);
    assertPoolDepositInstant(pool, mcNominator, depoMc);

    // practically it is already checked in assertPoolDepositInstant
    // But for illustative purposes

    var nmData = pool.getNominatorData(mcNominator.getWorkchainAndHash().1);

    expect(nmData.amount).toEqual(depoMc - DEPOSIT_GAS);

    nmData = pool.getNominatorData(bcNominator.getWorkchainAndHash().1);

    expect(nmData.amount).toEqual(depoBc - DEPOSIT_GAS);
}

get fun `test simple withdrawal`() {
    val (pool, _owner, _notOwner, _validator, nominators) = setupPoolWithNominators(10);
    val pickNm = nominators.get(random.range(10 - 1));
    asssertSimpleWithdawal(pool, pickNm);
}

get fun `test withdrawal should reject when no deposit ever made`() {
    val (pool, _owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    val _randomHash = random.uint256();
    val randomAddres = address.fromWorkchainAndHash(BASECHAIN, random.uint256());

    val poolBefore = getAccountData(pool.address);
    val res = pool.sendTextComment(randomAddres, "w".beginParse(), { value: ton("1") });

    expect(res).toHaveRefund<TextComment>({
        to: randomAddres,
        from: pool.address,
        previousState: poolBefore,
        error: ErrorsPool.DepositNotFound,
    });
}

get fun `test withdrawal should reject when no deposit ever made (round closed)`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    runRound(pool, elector, stakes, limits, validator);
    val _randomHash = random.uint256();
    val randomAddres = address.fromWorkchainAndHash(BASECHAIN, random.uint256());

    val poolBefore = getAccountData(pool.address);
    val res = pool.sendTextComment(randomAddres, "w".beginParse(), { value: ton("1") });

    expect(res).toHaveRefund<TextComment>({
        to: randomAddres,
        from: pool.address,
        previousState: poolBefore,
        error: ErrorsPool.DepositNotFound,
    });
}

get fun `test simple withdrawal on large nm dict`() {
    val (pool, _owner, _notOwner, _validator, nominators) = setupPoolWithNominators(1023);

    val pickNm = nominators.get(random.range(1023 - 1));
    asssertSimpleWithdawal(pool, pickNm);
}

@test.fuzz(1)
get fun `test validator should be able to stake`(
    stakeVal: coins,
    _queryId: uint64,
    _publicKey: uint256,
) {
    val (elector, _stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(100);

    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();

    val boundStake = fuzz.bound(
        stakeVal,
        validators.minTonPerValidator + ton("1"),
        validators.maxTonPerValidator,
    );
    val elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, boundStake);
}

get fun `test if pool received profit, nominators stake should increase in price`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

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

    val testNm = nominators.get(random.range(40 - 1));
    val nmHash = testNm.getWorkchainAndHash().1;
    val poolBefore = pool.getPoolData();
    val nmBefore = pool.getNominatorData(nmHash);

    val res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    val poolAfter = pool.getPoolData();
    expect(poolAfter.roundClosed).toBeFalse();
    // Profit should propagate to nominatorsAmount
    expect(poolAfter.nominatorsAmount).toBeGreater(poolBefore.nominatorsAmount);

    // And be visible for each individual nominator
    val nmAfter = pool.getNominatorData(nmHash);
    expect(nmAfter.amount).toBeGreater(nmBefore.amount);

    asssertSimpleWithdawal(pool, testNm);
}

get fun `test if nominators accured profit, they should be able to withdraw rewards`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

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

    val testNm = nominators.get(random.range(40 - 1));
    val nmHash = testNm.getWorkchainAndHash().1;
    val nmBefore = pool.getNominatorData(nmHash);

    val poolBefore = pool.getPoolData();
    val rawNominators = poolBefore.nominators.load();

    val _res = waitAndRecoverStake(pool, validator, elector.address);

    val nmAfter = pool.getNominatorData(nmHash);
    expect(nmAfter.amount).toBeGreater(nmBefore.amount);

    val profit = nmAfter.amount - nmBefore.amount;
    expect(profit).toBeGreater(rawNominators.minWithdrawableReward);

    val inValue = ton("1");
    val getReward = pool.sendTextComment(
        testNm,
        "r".beginParse(),
        { value: inValue },
    );

    val rewardTx = getReward.findTransaction<TextComment>({
        from: testNm,
        to: pool.address,
    });

    val msgTx = getReward.findTransaction<WithdrawSuccess>({
        from: pool.address,
        to: testNm,
    });

    expect(rewardTx != null && msgTx != null).toBeTrue();
    val rewardMsg = msgTx!.loadInMsg<WithdrawSuccess>();
    val rewardCompute = getTxComputePh(rewardTx!);

    val lump = testing.getConfig().getMsgForwardPrices(BASECHAIN).lumpPrice;
    expect(getInternalMessageValue(rewardMsg.info).grams).toEqual(
        profit + inValue - rewardCompute.gasFees - lump,
    );

    val afterReward = pool.getNominatorData(nmHash);
    // One nanoton off is ok
    expect(afterReward.amount as int).toBeApproxEqAbs(nmBefore.amount, 1);
    // If those are different, after reward should be greater.
    if (afterReward.amount != nmBefore.amount) {
        expect(afterReward.amount).toBeGreater(nmBefore.amount);
    }
}

get fun `test reward should be claimable in pending mode`() {
    val (elector, stakes, limits) = setupElector();
    val (
        pool,
        _owner,
        _notOwner,
        validator,
        nominators,
        _recoverResult,
    ) = setupPoolWithProfits(40, 1);

    // Now run another rounds to close
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
    );

    val testNm = nominators.get(random.range(40 - 1));
    val nmHash = testNm.getWorkchainAndHash().1;

    val inValue = ton("1");
    val _getReward = pool.sendTextComment(
        testNm,
        "r".beginParse(),
        { value: inValue },
    );

    val poolBefore = pool.getPoolData();
    val rawNominators = poolBefore.nominators.load();
    val rawNm = rawNominators.poolNominators.mustGet(testNm, 42);

    expect(rawNm.share).toBeGreater(0);

    val res = waitAndRecoverStake(pool, validator, elector.address);
    val notificationTx = res.findTransaction<StakeReturned>({
        from: pool.address,
        to: validator,
    });
    // println(res);
    expect(notificationTx != null).toBeTrue();
    val notification = notificationTx!.loadBody<StakeReturned>();
    val nominatorsProfit = (notification.returned - notification.used) / 2;

    val burnNofificationTx = res.findTransaction<PayoutBurnNotification>({ to: pool.address });
    expect(burnNofificationTx != null).toBeTrue();
    val gasFees = getTxComputePh(burnNofificationTx!).gasFees;
    val fwdFees = testing.getConfig().getMsgForwardPrices(BASECHAIN).lumpPrice;
    val notificationValue = getInternalMessageInfo(
        burnNofificationTx!.loadInMsg<PayoutBurnNotification>().info,
    )
        .value
        .grams;
    val rateWithRewards = mulDivFloor(
        rawNm.pendingWithdrawal,
        poolBefore.nominatorsAmount + nominatorsProfit,
        poolBefore.poolSupply,
    );
    val expectedValue = rateWithRewards + notificationValue - gasFees - fwdFees;

    val withdrawTx = res.findTransaction<WithdrawSuccess>({ from: pool.address, to: testNm });
    expect(withdrawTx).toBeNotNull();
    val withdrawMsg = withdrawTx!.loadInMsg<WithdrawSuccess>();
    val withdrawBody = withdrawMsg.loadBody();
    val actualValue = getInternalMessageValue(withdrawMsg.info).grams;
    // println(format("Rate with rewards {} expected {} actual {}", rateWithRewards, expectedValue, actualValue));
    expect(actualValue as int).toBeApproxEqAbs(expectedValue, 1000);

    val nmAfter = pool.getNominatorData(nmHash);
    expect(nmAfter.amount).toEqual(withdrawBody.left);
    expect(nmAfter.withdrawFound).toBeFalse();
}

get fun `test reward withdrawal should be rejected when sender has no deposit`() {
    val (pool, _owner, _notOwner, _validator) = setupDeployedPool();
    val stranger = testing.treasury("Stranger");
    val stateBefore = getAccountData(pool.address);
    val res = pool.sendTextComment(
        stranger.address,
        "r".beginParse(),
        { value: DEFAULT_MSG_VALUE },
    );
    expect(
        res,
    ).toHaveRefund<TextComment>({ from: pool.address, to: stranger.address, error: ErrorsPool.DepositNotFound, previousState: stateBefore });
}

get fun `test reward withdrawal should be rejected when no profit has been accrued`() {
    val (pool, _owner, _notOwner, _validator) = setupDeployedPool();
    val testNm = testing.treasury("TestNominator");
    val depo = pool.getNominatorMinimalStake().minExpectedValue;
    assertPoolDepositInstant(pool, testNm.address, depo);
    val stateBefore = getAccountData(pool.address);
    val res = pool.sendTextComment(testNm.address, "r".beginParse(), { value: DEFAULT_MSG_VALUE });
    expect(
        res,
    ).toHaveRefund<TextComment>({ from: pool.address, to: testNm.address, error: ErrorsPool.RewardIsBelowMinimal, previousState: stateBefore });
}

get fun `test reward withdrawal should be rejected when share delta is zero`() {
    val customNmSettings = NominatorsSettings {
        maxNominators: 1023,
        minStake: ton("1000"),
        minWithdrawableRewards: 0,
        whitelist: [],
    };
    val (pool, _owner, _notOwner, _validator) = setupDeployedPool({
        nominatorsSettings: customNmSettings,
    });
    val testNm = testing.treasury("TestNominator");
    val depo = pool.getNominatorMinimalStake().minExpectedValue;
    assertPoolDepositInstant(pool, testNm.address, depo);
    val stateBefore = getAccountData(pool.address);
    val res = pool.sendTextComment(testNm.address, "r".beginParse(), { value: DEFAULT_MSG_VALUE });
    expect(
        res,
    ).toHaveRefund<TextComment>({ from: pool.address, to: testNm.address, error: ErrorsPool.NothingToWithdraw, previousState: stateBefore });
}

get fun `test if pool received loss, nominators stake should decrease in price`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

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

    val valInfo = waitTillRecovery(pool, validator, elector.address);

    val testNm = nominators.get(random.range(40 - 1));
    val nmHash = testNm.getWorkchainAndHash().1;
    val poolBefore = pool.getPoolData();
    val nmBefore = pool.getNominatorData(nmHash);

    // Let's say we got 3% loss

    val used = valInfo.usage.prevRoundUsage!.usage.tonUsed;
    val returnedStake = mulDivFloor(used, 9700, 10000);
    val expectedLoss = returnedStake - calculateGasFee(BASECHAIN, RECOVER_STAKE_OK_GAS) - used;

    expect(expectedLoss).toBeLess(0);
    val nominatorsLoss = expectedLoss / 2;
    val expectedProxy = valInfo.usage.prevRoundUsage!.proxy;

    val res = net.send(
        address.fromWorkchainAndHash(MASTERCHAIN, expectedProxy),
        createMessage({
            bounce: false,
            dest: pool.address,
            value: returnedStake,
            body: RecoverStakeOk {
                queryId: 0,
                remaining: ProxyResponseData {
                    validator,
                    parity: false, // W're returning round 0 stake
                }.toCell()
                    .beginParse(),
            },
        }),
    );
    // println(res);

    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    val poolAfter = pool.getPoolData();
    expect(poolAfter.roundClosed).toBeFalse();
    // Profit should propagate to nominatorsAmount
    expect(poolAfter.nominatorsAmount as int).toBeApproxEqAbs(
        poolBefore.nominatorsAmount + nominatorsLoss,
        1,
    );

    // And be visible for each individual nominator
    val nmAfter = pool.getNominatorData(nmHash);
    expect(nmAfter.amount).toBeLess(nmBefore.amount);

    asssertSimpleWithdawal(pool, testNm);
}

get fun `test extreme slashing should not throw exceeds recovered value`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

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

    val valInfo = waitTillRecovery(pool, validator, elector.address);

    val testNm = nominators.get(random.range(40 - 1));
    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    val nmBefore = pool.getNominatorData(testNm.getWorkchainAndHash().1);

    val used = valInfo.usage.prevRoundUsage!.usage.tonUsed;
    val expectedProxy = valInfo.usage.prevRoundUsage!.proxy;

    // Simulate 99.9% slash. practically the proxy will send guaranteed minimum of 0.1 TON
    val slashedReturn = calculateGasFee(BASECHAIN, RECOVER_STAKE_OK_GAS) - 1;

    val res = net.send(
        address.fromWorkchainAndHash(MASTERCHAIN, expectedProxy),
        createMessage({
            bounce: false,
            dest: pool.address,
            value: slashedReturn,
            body: RecoverStakeOk {
                queryId: 0,
                remaining: ProxyResponseData {
                    validator,
                    parity: false,
                }.toCell()
                    .beginParse(),
            },
        }),
    );

    // The transaction must always succeed.
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();

    // StakeReturned should be emitted with returned = 0 (clamped)
    val refundTx = res.findTransaction<StakeReturned>({
        from: pool.address,
        to: validator,
    });
    expect(refundTx).toBeNotNull();
    val refundMsg = refundTx!.loadInMsg<StakeReturned>();
    expect(refundMsg.loadBody().returned).toEqual(0);

    // Validator still receives round result info, but without value.
    // Just for logging purposes
    expect(getInternalMessageValue(refundMsg.info).grams).toEqual(0);

    // Loss should propagate to nominatorsAmount
    // profit = 0 (clamped returned) - tonUsed = -tonUsed
    val expectedProfit = -used;
    val ownerShare = mulDivFloor(expectedProfit, poolBefore.ownerShare, SHARE_BASE);
    val nominatorsProfit = expectedProfit - ownerShare;
    expect(poolAfter.nominatorsAmount as int).toBeApproxEqAbs(
        poolBefore.nominatorsAmount + nominatorsProfit,
        1,
    );

    // Nominator stake should decrease
    val nmAfter = pool.getNominatorData(testNm.getWorkchainAndHash().1);
    expect(nmAfter.amount).toBeLess(nmBefore.amount);

    // Even-round usageState bit should be cleared (parity: false = even)
    val validatorAfter = pool.getValidatorInfo(validator);
    expect(validatorAfter.validator.usageState & 2).toEqual(0);

    // stakeUsed should be decremented
    expect(validatorsAfter.stakeUsed).toEqual(validators.stakeUsed - used);

    // activeSlots should be decremented
    expect(validatorsAfter.activeSlots).toEqual(validators.activeSlots - 1);
}

get fun `test stake profit smaller than refundBonus should not award bonus`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

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

    val valInfo = waitTillRecovery(pool, validator, elector.address);

    val testNm = nominators.get(random.range(40 - 1));
    val nmHash = testNm.getWorkchainAndHash().1;
    val poolBefore = pool.getPoolData();
    val nmBefore = pool.getNominatorData(nmHash);
    val validators = poolBefore.validators.load();

    val used = valInfo.usage.prevRoundUsage!.usage.tonUsed;
    val refundBonus = validators.refundBonus;
    val expectedProxy = valInfo.usage.prevRoundUsage!.proxy;

    // Craft a returned value that is profitable (returned > used)
    // but whose profit is smaller than refundBonus (returned <= used + refundBonus).

    val returnPricipal = used + refundBonus / 2;
    val recoveredValue = returnPricipal + calculateGasFee(BASECHAIN, RECOVER_STAKE_OK_GAS);

    val res = net.send(
        address.fromWorkchainAndHash(MASTERCHAIN, expectedProxy),
        createMessage({
            bounce: false,
            dest: pool.address,
            value: recoveredValue,
            body: RecoverStakeOk {
                queryId: 0,
                remaining: ProxyResponseData {
                    validator,
                    parity: false, // Returning round 0 stake
                }.toCell()
                    .beginParse(),
            },
        }),
    );

    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    val poolAfter = pool.getPoolData();
    expect(poolAfter.roundClosed).toBeFalse();

    val expectedProfit = returnPricipal - used;
    expect(expectedProfit).toBeGreater(0);
    expect(expectedProfit).toBeLess(refundBonus);

    val ownerShare = mulDivFloor(expectedProfit, poolBefore.ownerShare, SHARE_BASE);
    val nominatorsProfit = expectedProfit - ownerShare;

    // If the bonus were erroneously paid, profit would be negative refundBonus / 2
    // and nominatorsAmount would decrease instead.
    expect(poolAfter.nominatorsAmount as int).toBeApproxEqAbs(
        poolBefore.nominatorsAmount + nominatorsProfit,
        1,
    );

    // Each nominator should see their stake increase in price
    val nmAfter = pool.getNominatorData(nmHash);
    expect(nmAfter.amount).toBeGreater(nmBefore.amount);

    // RoundInfoMessage should report the profit without bonus deduction
    val reportTx = res.findTransaction<RoundInfoMessage>({ from: pool.address });
    expect(reportTx).toBeNotNull();
    val infoBody = reportTx!.loadBody<RoundInfoMessage>();
    expect(infoBody.info.used).toEqual(used);
    expect(infoBody.info.returned).toEqual(returnPricipal);
    expect(infoBody.info.returned - infoBody.info.used).toEqual(expectedProfit);
}

get fun `test deep losses should put pool nm operations into insolvent state`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

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

    val valInfo = waitTillRecovery(pool, validator, elector.address);

    val testNm = nominators.get(random.range(40 - 1));

    // Let's say we now got 10% loss

    val used = valInfo.usage.prevRoundUsage!.usage.tonUsed;
    val expectedProxy = valInfo.usage.prevRoundUsage!.proxy;
    val returnedStake = mulDivFloor(used, 9000, 10000);
    var res = net.send(
        address.fromWorkchainAndHash(MASTERCHAIN, expectedProxy),
        createMessage({
            bounce: false,
            dest: pool.address,
            value: returnedStake,
            body: RecoverStakeOk {
                queryId: 0,
                remaining: ProxyResponseData {
                    validator,
                    parity: false, // W're returning round 0 stake
                }.toCell()
                    .beginParse(),
            },
        }),
    );
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    val poolAfter = pool.getPoolData();
    // Projected total balance
    val poolBalance = testing.getAccountBalance(pool.address) +
    poolAfter.validators.load().stakeUsed;
    // Less than total nominators obligations
    expect(poolBalance).toBeLess(poolAfter.nominatorsAmount);

    val stateBefore = getAccountData(pool.address);
    // So no withdrawals accepted
    res = pool.sendTextComment(
        testNm,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    expect(
        res,
    ).toHaveRefund<TextComment>({
        to: testNm,
        from: pool.address,
        error: ErrorsPool.Insolvent,
        previousState: stateBefore,
        initialBalance: testing.getAccountBalance(
            pool.address,
        ),
    });

    // Including rewards
    res = pool.sendTextComment(
        testNm,
        "r".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    expect(
        res,
    ).toHaveRefund<TextComment>({
        to: testNm,
        from: pool.address,
        error: ErrorsPool.Insolvent,
        previousState: stateBefore,
        initialBalance: testing.getAccountBalance(
            pool.address,
        ),
    });

    // And most importantly deposits
    res = pool.sendTextComment(
        testNm,
        "d".beginParse(),
        { value: stakes.minStake * 2 },
    );
    expect(
        res,
    ).toHaveRefund<TextComment>({
        to: testNm,
        from: pool.address,
        error: ErrorsPool.Insolvent,
        previousState: stateBefore,
        initialBalance: testing.getAccountBalance(
            pool.address,
        ),
    });
    val ownerRes = pool.sendOwnerWithdrawal(
        owner.address,
        DEFAULT_QUERY_ID,
        ton("1"),
        { value: DEFAULT_MSG_VALUE },
    );
    expect(ownerRes).toHaveRefund<OwnerWithdrawal>({
        from: pool.address,
        to: owner.address,
        previousState: stateBefore,
        initialBalance: testing.getAccountBalance(pool.address),
        error: ErrorsPool.Insolvent,
    });
    // Since owner share got hit, new stake should hit OwnerShareIsUndercapitalized
    val elections = announceElections(elector);
    assertNewStakeFailed(
        ErrorsPool.OwnerShareIsUndercapitalized,
        validator,
        pool,
        elector.address,
        elections,
        stakes.minStake * 2,
    );

    // But recovery should work, since recovery brings potential profit.
    // Let's organize some nice profit to definitely cover the previous loss on return
    runElections(elector, stakes, limits, ton("10000"));
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    val balanceAfter = testing.getAccountBalance(pool.address);
    expect(balanceAfter).toBeGreater(poolAfter.nominatorsAmount);

    // All operations should work again
    asssertSimpleWithdawal(pool, testNm);
    val depositor = testing.treasury("Depositor");
    assertPoolDepositInstant(pool, depositor.address, stakes.minStake * 2);

    var rewardNm = nominators.get(random.range(41));
    while (rewardNm == testNm) {
        rewardNm = nominators.get(random.range(41));
    }

    res = pool.sendTextComment(
        rewardNm,
        "r".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    expect(res).toHaveTx<WithdrawSuccess>({ to: rewardNm });
}

get fun `test in open round, if pool doesn't have enough balance to withdraw, it shold make withdrawal pending`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, _owner, _notOwner, validaotr) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    var initialDeposit = ton("100000");
    assertPoolDepositInstant(pool, fatNm.address, initialDeposit);
    initialDeposit -= DEPOSIT_GAS;
    // During round some stakes will be taken
    runRound(pool, elector, stakes, limits, validaotr);

    val poolBefore = pool.getPoolData();
    expect(poolBefore.pendingWithdrawals).toEqual(0);
    expect(poolBefore.roundClosed).toBeFalse();
    expect(testing.getAccountBalance(pool.address)).toBeLess(initialDeposit);

    val res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    val poolAfter = pool.getPoolData();
    // pendingWithdrawals is nominated in shares, but in first round it's 1/1, so it's ok
    expect(poolAfter.pendingWithdrawals).toEqual(initialDeposit);

    expect(res).toHaveSuccessfulTx<PayoutInitMessage>({ from: pool.address });
}

get fun `test pool should halt if withdrawals can't be processed`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    val simpleFolk = testing.treasury("peasant");
    var lagreDepo = ton("100000");
    var smallDepo = lagreDepo / 10;

    assertPoolDepositInstant(pool, simpleFolk.address, smallDepo);
    assertPoolDepositInstant(pool, fatNm.address, lagreDepo);
    lagreDepo -= DEPOSIT_GAS;
    smallDepo -= DEPOSIT_GAS;
    val stake = lagreDepo / 2;
    // During round some stakes will be taken

    var elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);
    //runRound(pool, elector, stakes, limits, validator);

    // Now in the same round FatCat for some reason withdraws
    var res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    // Bringing this case further, this withdrawals won't be fullfiled on the next round,
    // because taken funds are now validating
    // Pool should become halted, till the funds return

    assertNewStakeFailed(
        ErrorsPool.NotEnoughPoolBalance,
        validator,
        pool,
        elector.address,
        elections,
        stakes.minStake * 2,
    );

    runElections(elector, stakes, limits);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: ton("1") });

    poolAfter = pool.getPoolData();
    expect(poolAfter.halted).toBeTrue();
    expect(poolAfter.roundClosed).toBeFalse();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    assertNewStakeFailed(
        ErrorsPool.PoolIsHalted,
        validator,
        pool,
        elector.address,
        elections,
        stakes.minStake * 2,
    );

    // Now if others want out, they can't till the pool unhalts

    // Witdhrawals should go pending
    assertDelayedOperation(pool, simpleFolk.address, true);
    /*
    res = pool.sendTextComment(simpleFolk.address, "w".beginParse(), { value: ton("1") });
    expect(
        res,
    ).toHaveRefund<TextComment>({ from: pool.address, to: simpleFolk.address, error: ErrorsPool.PoolIsHalted, previousState: stateBefore });
    */

    // And no one should be able to deposit either

    val depositor = testing.treasury("Depositor");

    // Deposit goes pending because the round rotated (hasPrevUsage), even while halted
    assertDelayedOperation(pool, depositor.address, false, smallDepo);
    /*
    res = pool.sendTextComment(
        depositor.address,
        "d".beginParse(),
        { value: smallDepo + DEPOSIT_GAS },
    );
    expect(
        res,
    ).toHaveRefund<TextComment>({ from: pool.address, to: depositor.address, error: ErrorsPool.PoolIsHalted, previousState: stateBefore });
    */

    val stateBefore = getAccountData(pool.address);
    // Key change here that it is not rejected by halted state anymore
    res = pool.sendTextComment(simpleFolk.address, "r".beginParse(), { value: ton("1") });
    expect(
        res,
    ).toHaveRefund<TextComment>({ from: pool.address, to: simpleFolk.address, error: ErrorsPool.RewardIsBelowMinimal, previousState: stateBefore });

    // And owner shouldn't be able to withdraw either
    res = pool.sendOwnerWithdrawal(owner.address, DEFAULT_QUERY_ID, ton("1"), { value: ton("1") });
    expect(
        res,
    ).toHaveRefund<OwnerWithdrawal>({ from: pool.address, to: owner.address, error: ErrorsPool.PoolIsHalted, previousState: stateBefore });

    // Elections are going without pool taking part
    elections = announceElections(elector);
    runElections(elector, stakes, limits);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: ton("1") });

    res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    // println(res);

    poolAfter = pool.getPoolData();
    expect(poolAfter.halted).toBeFalse();
    expect(poolAfter.pendingWithdrawals).toEqual(0);
    expect(poolAfter.pendingDeposits).toEqual(0);

    expect(res).toHaveTx<WithdrawSuccess>({
        from: pool.address,
        to: fatNm.address,
        value: fun(amount) {
            return amount >= lagreDepo;
        },
    });

    // Withdrawals work again
    asssertSimpleWithdawal(pool, depositor.address);
    // Deposits too
    assertPoolDepositInstant(pool, depositor.address, smallDepo * 2);

    // Most importantly new stake
    elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stakes.minStake * 2);
}

get fun `test if withdrawal has failed, the nominator should be notified and able to retry immediately`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");

    val ownerFunds = stakes.minStake * 2;
    // Owner's cushion. Later it lets the second stake exceed the nominator funds,
    // so the owner can overdraw the liquid balance while the stake is still recoverable
    net.send(
        owner.address,
        createMessage({
            bounce: false,
            dest: pool.address,
            value: ownerFunds,
            body: AddFunds { queryId: DEFAULT_QUERY_ID },
        }),
    );

    val stake = ton("100000");
    assertPoolDepositInstant(pool, fatNm.address, stake);

    // First stake locks the nominator funds in the elector
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
        stake,
    );
    // Second stake is covered by the owner's cushion and stays in the elector
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
        ownerFunds,
    );

    // Closed round forces the withdrawal into the pending queue
    val (_, sharesBefore) = assertDelayedOperation(pool, fatNm.address, true);

    waitTillRecovery(pool, validator, elector.address);

    val validatorStatus = pool.getValidatorInfo(validator);
    val expectedProxyHash = validatorStatus.usage.prevRoundUsage!.proxy;
    val expectedProxy = address.fromWorkchainAndHash(MASTERCHAIN, expectedProxyHash);

    val proxyParity = false;

    // Recovering the stake kickstarts the payout chain.
    val recoverIter = testing.createTraceIterationCursor(
        expectedProxy,
        createMessage<RecoverStakeOk>({
            bounce: false,
            dest: pool.address,
            body: RecoverStakeOk {
                queryId: DEFAULT_QUERY_ID,
                remaining: ProxyResponseData {
                    validator,
                    parity: proxyParity,
                }.toCell()
                    .beginParse(),
            },
            value: stake,
        }),
    );

    recoverIter.executeTill<PayoutBurnMessage>({ from: pool.address });

    // Right in between, the owner cushion comes back slashed in half.
    // The loss is shared with the nominators, so nominatorsAmount drops,
    // and with it the pending withdrawals estimate in the owner liquid gate
    val nmAmountBeforeSlash = pool.getPoolData().nominatorsAmount;

    val validatorStatusAfter = pool.getValidatorInfo(validator);
    val slashedProxyHash = validatorStatusAfter.usage.prevRoundUsage!.proxy;
    // Two consecutive stakes always rotate between the even and the odd proxy
    val slashedParity = slashedProxyHash != expectedProxyHash;

    val slashIter = testing.createTraceIterationCursor(
        address.fromWorkchainAndHash(MASTERCHAIN, slashedProxyHash),
        createMessage<RecoverStakeOk>({
            bounce: false,
            dest: pool.address,
            body: RecoverStakeOk {
                queryId: DEFAULT_QUERY_ID,
                remaining: ProxyResponseData {
                    validator,
                    parity: slashedParity,
                }.toCell()
                    .beginParse(),
            },
            value: ownerFunds / 2,
        }),
    );

    val slashRes = slashIter.executeAllRemaining();
    expect(slashRes).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    expect(pool.getPoolData().nominatorsAmount).toBeLess(nmAmountBeforeSlash);

    // Owner withdraws right in between. The gate reserves the pending payout at the
    // post-slash spot rate, while the notification still bills at the pre-slash frozen
    // rate, so the nominators' half of the loss (~5000) plus the punishment reserve
    // slack (~590) becomes withdrawable. Any amount within (~10600, ~15600) both passes
    // the gate and leaves the pool unable to afford the frozen payout; the midpoint
    // keeps ~2400 margin from either bound
    val poolBefore = pool.getPoolData();
    val nominatorsBefore = poolBefore.nominators.load();
    val fatNmBefore = nominatorsBefore.poolNominators.mustGet(fatNm.address, 42);

    val ownerIter = testing.createTraceIterationCursor(
        owner.address,
        createMessage<OwnerWithdrawal>({
            bounce: true,
            dest: pool.address,
            body: OwnerWithdrawal {
                queryId: DEFAULT_QUERY_ID,
                amount: ton("13000"),
            },
            value: ton("1"),
        }),
    );

    val ownerRes = ownerIter.executeAllRemaining();
    expect(ownerRes).toHaveSuccessfulTx<OwnerWithdrawalSuccess>({
        from: pool.address,
        to: owner.address,
    });

    // Burn notification arrives, pool can't afford the frozen payout anymore
    val recoverRes = recoverIter.executeAllRemaining();

    // Payout is not settled, nominator is notified instead
    expect(recoverRes).toNotHaveTx<WithdrawSuccess>({ from: pool.address, to: fatNm.address });
    expect(recoverRes).toHaveTx({
        from: pool.address,
        to: fatNm.address,
        value: fun(value) {
            return value < ton("0.05") && value > 0;
        },
        body: (0 as uint32, "Withdrawal has failed, retry later").toCell(),
    });

    // Withdrawal is reset, but stays pending, so nominator can retry
    val poolAfter = pool.getPoolData();
    val nominatorsAfter = poolAfter.nominators.load();
    val fatNmAfter = nominatorsAfter.poolNominators.mustGet(fatNm.address, 42);

    expect(poolAfter.pendingWithdrawals).toEqual(fatNmBefore.pendingWithdrawal);
    expect(poolAfter.nominatorsAmount).toEqual(poolBefore.nominatorsAmount);
    expect(poolAfter.poolSupply).toEqual(poolBefore.poolSupply);
    expect(nominatorsAfter.nmCount).toEqual(nominatorsBefore.nmCount);
    expect(fatNmAfter.pendingWithdrawal).toEqual(fatNmBefore.pendingWithdrawal);
    expect(fatNmAfter.withdrawalIndex).toEqual(0);

    // Invariants still hold
    assertPoolInvariants(pool);

    // Make sure nominator can actually retry
    var (_, sharesAfter) = assertDelayedOperation(pool, fatNm.address, true);
    expect(sharesAfter).toEqual(sharesBefore);

    expect(sharesAfter).toBeGreater(0);
}

get fun `test halted should not be able to lift with excessive value attached to updateVset`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    var lagreDepo = ton("100000");
    val excessiveValue = lagreDepo * 2;

    assertPoolDepositInstant(pool, fatNm.address, lagreDepo);
    lagreDepo -= DEPOSIT_GAS;
    val stake = lagreDepo / 2;

    var elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);

    var res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    runElections(elector, stakes, limits);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: excessiveValue });

    poolAfter = pool.getPoolData();
    expect(poolAfter.halted).toBeTrue();
    expect(poolAfter.roundClosed).toBeFalse();
}

get fun `test halted should not be able to lift with excessive value attached to deposit`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    var lagreDepo = ton("100000");

    assertPoolDepositInstant(pool, fatNm.address, lagreDepo);
    lagreDepo -= DEPOSIT_GAS;
    val stake = lagreDepo / 2;

    var elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);

    var res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    runElections(elector, stakes, limits);

    val excessiveValue = lagreDepo * 2;
    res = pool.sendTextComment(fatNm.address, "d".beginParse(), { value: excessiveValue });

    poolAfter = pool.getPoolData();
    expect(poolAfter.halted).toBeTrue();
    expect(poolAfter.roundClosed).toBeFalse();
}

get fun `test halted should not be able to lift with excessive value attached to withdrawal`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    val simpleFolk = testing.treasury("peasant");
    var lagreDepo = ton("100000");
    var smallDepo = lagreDepo / 10;

    assertPoolDepositInstant(pool, fatNm.address, lagreDepo);
    assertPoolDepositInstant(pool, simpleFolk.address, smallDepo);
    lagreDepo -= DEPOSIT_GAS;
    val stake = lagreDepo / 2;

    var elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);

    var res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    runElections(elector, stakes, limits);

    val excessiveValue = lagreDepo * 2;
    res = pool.sendTextComment(simpleFolk.address, "w".beginParse(), { value: excessiveValue });
    poolAfter = pool.getPoolData();
    expect(poolAfter.halted).toBeTrue();
    expect(poolAfter.roundClosed).toBeFalse();
}

get fun `test halted should not be able to lift with excessive value attached to NewStake`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    val simpleFolk = testing.treasury("peasant");
    var lagreDepo = ton("100000");
    var smallDepo = lagreDepo / 10;

    assertPoolDepositInstant(pool, fatNm.address, lagreDepo);
    assertPoolDepositInstant(pool, simpleFolk.address, smallDepo);
    lagreDepo -= DEPOSIT_GAS;
    val stake = lagreDepo / 2;

    var elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);

    var res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    runElections(elector, stakes, limits);

    expect(pool.getPoolData().halted).toBeFalse();
    val excessiveValue = lagreDepo * 2;
    elections = announceElections(elector);
    res = pool.sendNewStake(
        validator,
        DEFAULT_QUERY_ID,
        stake,
        getSignedBody(elections),
        { value: excessiveValue },
    );

    expect(
        res,
    ).toHaveRefund<NewStake>({ from: pool.address, to: validator, error: ErrorsPool.PoolIsHalted });
}

get fun `test halted should not be able to lift with excessive value attached to RecoverStake`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, _owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    var lagreDepo = ton("100000");

    assertPoolDepositInstant(pool, fatNm.address, lagreDepo);
    lagreDepo -= DEPOSIT_GAS;
    val stake = lagreDepo / 2;

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
        stake,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
        stake,
    );

    var res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    expect(pool.getPoolData().halted).toBeFalse();
    waitTillRecovery(pool, validator, elector.address);
    val excessiveValue = lagreDepo * 2;
    res = pool.sendRecoverStakeCompat(validator, DEFAULT_QUERY_ID, { value: excessiveValue });

    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    expect(res).toNotHaveTx<PayoutBurnMessage>();

    poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);
    expect(poolAfter.halted).toBeTrue();
}

get fun `test halted should not be able to lift with excessive value attached to RecoverStakeUnrestricted`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, _owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    var lagreDepo = ton("100000");

    assertPoolDepositInstant(pool, fatNm.address, lagreDepo);
    lagreDepo -= DEPOSIT_GAS;
    val stake = lagreDepo / 2;

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
        stake,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
        stake,
    );

    var res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    expect(pool.getPoolData().halted).toBeFalse();
    waitTillRecovery(pool, validator, elector.address);
    val excessiveValue = lagreDepo * 2;
    res = pool.sendRecoverStakeUnrestricted(
        validator,
        DEFAULT_QUERY_ID,
        validator,
        ton("1"),
        { value: excessiveValue },
    );

    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    expect(res).toNotHaveTx<PayoutBurnMessage>();

    poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);
    expect(poolAfter.halted).toBeTrue();
}

get fun `test halted should not be able to lift with excessive value attached to reward withdrawal`() {
    val (elector, stakes, limits) = setupElector();

    var (pool, owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");
    val simpleFolk = testing.treasury("peasant");
    var lagreDepo = ton("100000");
    var smallDepo = lagreDepo / 10;

    assertPoolDepositInstant(pool, fatNm.address, lagreDepo);
    assertPoolDepositInstant(pool, simpleFolk.address, smallDepo);
    lagreDepo -= DEPOSIT_GAS;
    val stake = lagreDepo / 2;

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
        stake,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
        stake,
    );

    var res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    // acrued some reward
    expect(pool.getNominatorData(simpleFolk.address.getHash()).reward).toBeGreater(0);

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
        stake,
    );
    res = pool.sendTextComment(
        fatNm.address,
        "w".beginParse(),
        { value: WITHDRAWAL_GAS },
    );
    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(lagreDepo);

    res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    poolAfter = pool.getPoolData();
    expect(poolAfter.halted).toBeTrue();
    expect(poolAfter.roundClosed).toBeFalse();

    runElections(elector, stakes, limits);

    val excessiveValue = lagreDepo * 2;
    res = pool.sendTextComment(simpleFolk.address, "r".beginParse(), { value: excessiveValue });
    poolAfter = pool.getPoolData();
    expect(poolAfter.halted).toBeTrue();
    // Round closed again, but halted is not lifted
    expect(poolAfter.roundClosed).toBeTrue();
}

get fun `test deposit should be able to rotate round if vset is changed`() {
    val (_elector, stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);
    val testAddr = address.fromWorkchainAndHash(BASECHAIN, random.uint256());
    val stake = stakes.minStake * 2;

    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    var newVset = updateVsetHash();

    assertPoolDepositInstant(pool, testAddr, stake);

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    expect(validatorsAfter.vsetHash).toNotEqual(validators.vsetHash);
    expect(validatorsAfter.vsetHash).toEqual(newVset >> 128);
    val prevRoundAfter = validatorsAfter.prevRound.load();
    val curRoundAfter = validatorsAfter.curRound.load();
    val curRoundBefore = validators.curRound.load();
    expect(prevRoundAfter.used).toEqual(curRoundBefore.used);
    expect(prevRoundAfter.returned).toEqual(curRoundBefore.returned);
    expect(prevRoundAfter.roundIndex).toEqual(curRoundBefore.roundIndex);
    expect(curRoundAfter.users.isEmpty()).toBeTrue();
    expect(curRoundAfter.used).toEqual(0);
    expect(curRoundAfter.returned).toEqual(0);
    expect(poolAfter.roundIndex).toEqual(poolBefore.roundIndex + 1);
}

get fun `test deposit should go pending and rotate round if vset is changed and current round has stakes`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);
    val testAddr = address.fromWorkchainAndHash(BASECHAIN, random.uint256());
    val stake = stakes.minStake * 2;

    val elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);

    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    var newVset = updateVsetHash();

    assertDelayedOperation(pool, testAddr, false, stake);

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    expect(validatorsAfter.vsetHash).toNotEqual(validators.vsetHash);
    expect(validatorsAfter.vsetHash).toEqual(newVset >> 128);
    val prevRoundAfter = validatorsAfter.prevRound.load();
    val curRoundAfter = validatorsAfter.curRound.load();
    val curRoundBefore = validators.curRound.load();
    expect(prevRoundAfter.used).toEqual(curRoundBefore.used);
    expect(prevRoundAfter.returned).toEqual(curRoundBefore.returned);
    expect(prevRoundAfter.roundIndex).toEqual(curRoundBefore.roundIndex);
    expect(curRoundAfter.users.isEmpty()).toBeTrue();
    expect(curRoundAfter.used).toEqual(0);
    expect(curRoundAfter.returned).toEqual(0);
    expect(poolAfter.roundIndex).toEqual(poolBefore.roundIndex + 1);
}

get fun `test withdrawal should be able to rotate round if vset is changed`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(10);
    val stake = stakes.minStake * 2;
    val elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);

    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    var newVset = updateVsetHash();

    val testNm = nominators.get(0);
    asssertSimpleWithdawal(pool, testNm);

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    expect(validatorsAfter.vsetHash).toNotEqual(validators.vsetHash);
    expect(validatorsAfter.vsetHash).toEqual(newVset >> 128);
    val prevRoundAfter = validatorsAfter.prevRound.load();
    val curRoundAfter = validatorsAfter.curRound.load();
    val curRoundBefore = validators.curRound.load();
    expect(prevRoundAfter.used).toEqual(curRoundBefore.used);
    expect(prevRoundAfter.returned).toEqual(curRoundBefore.returned);
    expect(prevRoundAfter.roundIndex).toEqual(curRoundBefore.roundIndex);
    expect(curRoundAfter.users.isEmpty()).toBeTrue();
    expect(curRoundAfter.used).toEqual(0);
    expect(curRoundAfter.returned).toEqual(0);
    expect(poolAfter.roundIndex).toEqual(poolBefore.roundIndex + 1);
}

get fun `test if round is about to close after rotation, withdrawal has to rotate round and go pending`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(20);
    val stake = stakes.minStake * 2;

    val testNm = nominators.get(random.range(19));

    var elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);
    updateVsetHash();
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stake);

    updateVsetHash();
    val poolBefore = pool.getPoolData();
    assertDelayedOperation(pool, testNm, true);

    val poolAfter = pool.getPoolData();

    expect(poolBefore.roundClosed).toBeFalse();
    expect(poolAfter.roundClosed).toBeTrue();
    expect(poolAfter.roundIndex).toEqual(poolBefore.roundIndex);
}

get fun `test in closed round, withdraw should be carried in pending mode and be fullfilled at the end of the round`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

    var testNominators = nominators;

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

    var nmLookup: map<address, coins> = [];

    var testNominator = testNominators.popHead();
    val poolBefore = pool.getPoolData();
    val nmBefore = poolBefore.nominators.load();

    var (testItem, sharesBurned) = assertDelayedOperation(pool, testNominator, true);
    var prevItemAddr = testItem.address;
    var prevItemData = testItem.getPayoutInfo();

    nmLookup.set(testNominator, sharesBurned);
    repeat (4) {
        testNominator = testNominators.popHead();

        var (testItem, burnt) = assertDelayedOperation(pool, testNominator, true);

        nmLookup.set(testNominator, burnt);
        sharesBurned += burnt;
        val itemData = testItem.getPayoutInfo();
        expect(itemData.owner).toEqual(testNominator);
        expect(itemData.owner).toNotEqual(prevItemData.owner);
        expect(itemData.data.roundIndex).toEqual(prevItemData.data.roundIndex);
        expect(itemData.data.next).toEqual(prevItemAddr);
        expect(prevItemData.data.prev).toEqual(testItem.address);
        prevItemData = itemData;
        prevItemAddr = testItem.address;
    }

    val res = waitAndRecoverStake(pool, validator, elector.address);
    // println(res);
    val recoverTx = res.findTransaction<RecoverStakeOk>({ to: pool.address });
    val stakeReturnedTx = res.findTransaction<StakeReturned>({ from: pool.address, to: validator });
    expect(recoverTx != null).toBeTrue();
    expect(stakeReturnedTx != null).toBeTrue();
    val stakeReturned = stakeReturnedTx!.loadBody<StakeReturned>();
    val recoveryProfit = stakeReturned.returned - stakeReturned.used;
    val ownerProfit = mulDivFloor(recoveryProfit, poolBefore.ownerShare, SHARE_BASE);
    val nominatorsRecoveryProfit = recoveryProfit - ownerProfit;
    expect(res).toHaveSuccessfulTx<PayoutBurnNotification>({ to: pool.address });
    expect(res).toHaveSuccessfulTx<PayoutBurnMessage>({ from: pool.address });
    val burnTx = res.findTransaction<PayoutBurnNotification>({ to: pool.address });
    expect(burnTx).toBeNotNull();
    val burnBody = burnTx!.loadBody<PayoutBurnNotification>();
    var lookup = nmLookup.findFirst();
    val poolAfter = pool.getPoolData();
    expect(poolAfter.poolSupply).toEqual(poolBefore.poolSupply - sharesBurned);
    val nmAfter = poolAfter.nominators.load();
    expect(poolAfter.pendingWithdrawals).toEqual(0);
    // 4 in a loop 1 in unroll
    expect(nmAfter.nmCount).toEqual(nmBefore.nmCount - 5);
    expect(nmAfter.pendingWithdrawals == null).toBeTrue();
    var totalWithdrwn = 0;
    while (lookup.isFound) {
        val curAddress = lookup.getKey();
        val curValue = lookup.loadValue();
        totalWithdrwn += mulDivFloor(
            curValue,
            burnBody.distribution.pendingCoins,
            burnBody.distribution.pendingShare,
        );
        expect(res).toHaveTx<WithdrawSuccess>({
            to: curAddress,
            value: fun(msgValue: coins) {
                return msgValue >= curValue;
            },
        });
        lookup = nmLookup.iterateNext(lookup);
        expect(nmAfter.poolNominators.exists(curAddress)).toBeFalse();
    }
    expect(poolAfter.nominatorsAmount).toEqual(
        poolBefore.nominatorsAmount + nominatorsRecoveryProfit - totalWithdrwn,
    );
}

get fun `test pending withdrawal should be retryable in three rounds`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

    var testNominators = nominators;

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

    var testNominator = testNominators.popHead();
    val poolBefore = pool.getPoolData();

    var (testItem, sharesBurned) = assertDelayedOperation(pool, testNominator, true);

    // Hash doesn't matter since we don't expect to unfreeze
    val frozenItem = TlbAccountStateFrozen { stateHash: random.uint256() };
    testing.setShardAccount(
        testItem.address,
        TlbShardAccount {
            account: (TlbAccountInfo {
                addr: testItem.address,
                storage: TlbAccountStorage {
                    lastTransLt: 0,
                    balance: TlbCurrencyCollection {
                        grams: 0,
                        other: [],
                    },
                    state: frozenItem,
                },
                storageStat: TlbStorageInfo {
                    used: TlbStorageUsed {
                        cells: 0,
                        bits: 0,
                    },
                    storageExtra: TlbStorageExtraNone {},
                    lastPaid: 0,
                    duePayment: TlbNone {},
                },
            } as TlbAccount).toCell(),
            lastTransHash: 0,
            lastTransLt: 0,
        },
    );

    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    expect(pool.getPoolData().roundClosed).toBeTrue();
    var res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    expect(res).toNotHaveTx<WithdrawSuccess>({ from: pool.address, to: testNominator });

    var poolAfter = pool.getPoolData();
    expect(poolAfter.pendingWithdrawals).toEqual(sharesBurned);
    expect(poolAfter.roundClosed).toBeFalse();
    val nominatorsAfter = poolAfter.nominators.load();
    expect(nominatorsAfter.pendingWithdrawals).toBeNull();
    val nmData = nominatorsAfter.poolNominators.mustGet(testNominator, 42);
    expect(nmData.pendingWithdrawal).toEqual(sharesBurned);
    // One round has rotated already.
    expect(nmData.withdrawalIndex).toEqual(poolBefore.roundIndex + ROUNDS_DELAY);

    res = pool.sendTextComment(testNominator, "w".beginParse(), { value: WITHDRAWAL_GAS });
    expect(res).toHaveRefund<TextComment>({
        to: testNominator,
        from: pool.address,
        error: ErrorsPool.WithdrawalAlreadyRequested,
    });

    updateVsetHash(elector.address);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    res = pool.sendTextComment(testNominator, "w".beginParse(), { value: WITHDRAWAL_GAS });
    expect(res).toHaveRefund<TextComment>({
        to: testNominator,
        from: pool.address,
        error: ErrorsPool.WithdrawalAlreadyRequested,
    });

    updateVsetHash(elector.address);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    poolAfter = pool.getPoolData();
    expect(poolAfter.roundIndex).toEqual(nmData.withdrawalIndex);
    var (newItem, sharesWithdrawn) = assertDelayedOperation(pool, testNominator, true);
    expect(sharesWithdrawn).toEqual(sharesBurned);

    updateVsetHash(elector.address);
    res = pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    val withdrawTx = res.findTransaction<WithdrawSuccess>({ from: pool.address, to: testNominator });
    expect(withdrawTx).toBeNotNull();

    expect(
        getInternalMessageValue(withdrawTx!.loadInMsg<WithdrawSuccess>().info).grams,
    ).toBeGreaterOrEqual(nmData.tonAmount);
}

get fun `test pending deposit should be retryable in three rounds`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(40);

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

    val testNominator = testing.treasury("Depositor").address;
    val poolBefore = pool.getPoolData();

    val minStake = pool.getNominatorMinimalStake().minExpectedValue;
    val depoAmount = random.range(ton("10000")) + minStake;

    var (testItem, depositedAmount) = assertDelayedOperation(
        pool,
        testNominator,
        false,
        depoAmount,
    );

    // Freeze the payout item to simulate a stalled chain
    val frozenItem = TlbAccountStateFrozen { stateHash: random.uint256() };
    testing.setShardAccount(
        testItem.address,
        TlbShardAccount {
            account: (TlbAccountInfo {
                addr: testItem.address,
                storage: TlbAccountStorage {
                    lastTransLt: 0,
                    balance: TlbCurrencyCollection {
                        grams: 0,
                        other: [],
                    },
                    state: frozenItem,
                },
                storageStat: TlbStorageInfo {
                    used: TlbStorageUsed {
                        cells: 0,
                        bits: 0,
                    },
                    storageExtra: TlbStorageExtraNone {},
                    lastPaid: 0,
                    duePayment: TlbNone {},
                },
            } as TlbAccount).toCell(),
            lastTransHash: 0,
            lastTransLt: 0,
        },
    );

    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    expect(pool.getPoolData().roundClosed).toBeTrue();
    var res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    expect(res).toNotHaveTx<PayoutBurnNotification>({ to: pool.address });

    // Chain stalled — aggregate preserved, cell nulled
    var poolAfter = pool.getPoolData();
    val nominatorsAfter = poolAfter.nominators.load();
    val nmData = nominatorsAfter.poolNominators.mustGet(testNominator, 42);
    val valAfter = poolAfter.validators.load();
    val expIdx = poolBefore.roundIndex + ROUNDS_DELAY;
    expect(valAfter.prevRound.load().users.isEmpty()).toBeFalse();
    expect(nmData.pendingDeposit).toEqual(depositedAmount);
    expect(nmData.share).toEqual(0);
    expect(nmData.depositIndex).toEqual(expIdx);
    expect(poolAfter.roundIndex).toBeLess(nmData.depositIndex);

    // Too early to retry — depositIndex > roundIndex, state unchanged
    res = pool.sendTextComment(testNominator, "d".beginParse(), { value: depoAmount });

    val poolAfterRetry = pool.getPoolData();
    val nmAfterRetry = poolAfterRetry.nominators.load().poolNominators.mustGet(testNominator, 42);
    expect(nmAfterRetry.pendingDeposit as int).toEqual(depositedAmount);
    expect(res).toHaveRefund<TextComment>({
        to: testNominator,
        from: pool.address,
        error: ErrorsPool.DepositAlreadyRequested,
    });

    updateVsetHash(elector.address);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    val poolBeforeLast = pool.getPoolData();
    expect(poolBeforeLast.roundIndex).toBeLess(expIdx);

    res = pool.sendTextComment(testNominator, "d".beginParse(), { value: depoAmount });
    expect(res).toHaveRefund<TextComment>({
        to: testNominator,
        from: pool.address,
        error: ErrorsPool.DepositAlreadyRequested,
    });

    res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    expect(res).toNotHaveTx<PayoutBurnNotification>({ to: pool.address });

    runElections(elector, stakes, limits);
    // Sync pool's vset hash with the new config
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    // Now announce new elections and stake
    val elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stakes.minStake * 2);
    runElections(elector, stakes, limits);
    updateVsetHash();
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    poolAfter = pool.getPoolData();
    expect(poolAfter.roundIndex).toBeGreaterOrEqual(nmData.depositIndex);

    // Retry — depositIndex <= roundIndex, hasPrevUsage true
    // Old pending is preserved in nominator record, new deposit accumulates
    val retryDepoAmount = random.range(ton("10000")) + minStake;
    val retryIncomingValue = retryDepoAmount - DEPOSIT_GAS;
    res = pool.sendTextComment(testNominator, "d".beginParse(), { value: retryDepoAmount });

    poolAfter = pool.getPoolData();
    expect(poolAfter.pendingDeposits).toEqual(depositedAmount + retryIncomingValue);
    val nmRetryData = poolAfter.nominators.load().poolNominators.mustGet(testNominator, 42);
    expect(nmRetryData.pendingDeposit).toEqual(depositedAmount + retryIncomingValue);

    // Need one more vset rotation for recovery (rotationCount >= 2)
    updateVsetHash(elector.address);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    // Process the chain — recover stake, then trigger rotation to process pending
    res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    val burnTx = res.findTransaction<PayoutBurnNotification>({ to: pool.address });
    expect(burnTx).toBeNotNull();

    // Deposit processed — shares minted, pending cleared, index reset
    poolAfter = pool.getPoolData();
    expect(poolAfter.pendingDeposits).toEqual(0);
    val nmFinal = pool.getNominatorData(testNominator.getWorkchainAndHash().1);
    // Should get exactly deposits from both attempts
    expect(nmFinal.amount as int).toBeApproxEqAbs(depositedAmount + retryIncomingValue, 1);
    expect(nmFinal.pendingDepositAmount).toEqual(0);
}

get fun `test in closed round, deposit should be carried in pending mode and be fullfilled at the end of the round`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

    var testNominators = nominators;

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

    var nmLookup: map<address, coins> = [];

    var testNominator = testNominators.popHead();
    val poolBefore = pool.getPoolData();
    val nmBefore = poolBefore.nominators.load();

    val minStake = pool.getNominatorMinimalStake().minExpectedValue;
    var curStake = random.range(ton("10000")) + minStake;
    var totalStake = curStake - DEPOSIT_GAS;
    var (testItem, _) = assertDelayedOperation(pool, testNominator, false, curStake);
    var prevItemAddr = testItem.address;
    var prevItemData = testItem.getPayoutInfo();

    nmLookup.set(testNominator, curStake - DEPOSIT_GAS);

    repeat (4) {
        testNominator = testNominators.popHead();

        curStake = random.range(ton("10000")) + minStake;
        var (testItem, _) = assertDelayedOperation(pool, testNominator, false, curStake);

        nmLookup.set(testNominator, curStake - DEPOSIT_GAS);
        totalStake += curStake - DEPOSIT_GAS;
        val itemData = testItem.getPayoutInfo();
        expect(itemData.owner).toEqual(testNominator);
        expect(itemData.owner).toNotEqual(prevItemData.owner);
        expect(itemData.data.roundIndex).toEqual(prevItemData.data.roundIndex);
        expect(itemData.data.next).toEqual(prevItemAddr);
        expect(prevItemData.data.prev).toEqual(testItem.address);
        prevItemData = itemData;
        prevItemAddr = testItem.address;
    }

    val res = waitAndRecoverStake(pool, validator, elector.address);
    // println(res);
    expect(res).toHaveSuccessfulTx<PayoutBurnNotification>({ to: pool.address });
    expect(res).toHaveSuccessfulTx<PayoutBurnMessage>({ from: pool.address });
    val returnedTx = res.findTransaction<StakeReturned>({ from: pool.address, to: validator });
    expect(returnedTx != null).toBeTrue();
    val returnedBody = returnedTx!.loadBody<StakeReturned>();
    val recoveryProfit = returnedBody.returned - returnedBody.used;
    val ownerProfit = mulDivFloor(recoveryProfit, poolBefore.ownerShare, SHARE_BASE);
    val nominatorsRecoveryProfit = recoveryProfit - ownerProfit;

    var lookup = nmLookup.findFirst();
    val burnTx = res.findTransaction<PayoutBurnNotification>({ to: pool.address })!;
    val burnBody = burnTx.loadBody<PayoutBurnNotification>();
    var expectedSharesMinted = 0;
    while (lookup.isFound) {
        expectedSharesMinted += mulDivFloor(
            lookup.loadValue(),
            burnBody.distribution.pendingShare,
            burnBody.distribution.pendingCoins,
        );
        lookup = nmLookup.iterateNext(lookup);
    }

    lookup = nmLookup.findFirst();
    val poolAfter = pool.getPoolData();
    expect(poolAfter.poolSupply).toEqual(poolBefore.poolSupply + expectedSharesMinted);
    expect(poolAfter.nominatorsAmount).toEqual(
        poolBefore.nominatorsAmount + totalStake + nominatorsRecoveryProfit,
    );
    val nmAfter = poolAfter.nominators.load();
    expect(poolAfter.pendingDeposits).toEqual(0);
    // 4 in a loop 1 in unroll
    expect(nmAfter.nmCount).toEqual(nmBefore.nmCount);
    expect(nmAfter.pendingDeposits == null).toBeTrue();
    while (lookup.isFound) {
        val curAddress = lookup.getKey();
        val curValue = lookup.loadValue();
        val stateBefore = nmBefore.poolNominators.mustGet(curAddress, 42);
        val curState = nmAfter.poolNominators.mustGet(curAddress, 42);

        expect(curState.share).toBeGreater(stateBefore.share);
        expect(curState.pendingDeposit).toEqual(0);
        expect(curState.tonAmount).toEqual(stateBefore.tonAmount + curValue);
        lookup = nmLookup.iterateNext(lookup);
    }
}

get fun `test nominator could first enter the pool via pending depo`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(40);

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

    val newNominator = testing.treasury("Out of da owen");
    val poolBefore = pool.getPoolData();
    val nmBefore = poolBefore.nominators.load();
    expect(nmBefore.poolNominators.exists(newNominator.address)).toBeFalse();

    val depoAmount = ton("10000");
    var (_depositItem, _gotShares) = assertDelayedOperation(
        pool,
        newNominator.address,
        false,
        depoAmount,
    );

    val poolAfter = pool.getPoolData();
    val nmAfter = poolAfter.nominators.load();
    val pendingNm = nmAfter.poolNominators.mustGet(newNominator.address, 42);
    expect(nmAfter.nmCount).toEqual(nmBefore.nmCount + 1);
    expect(pendingNm.share).toEqual(0);
    expect(pendingNm.pendingDeposit).toEqual(depoAmount - DEPOSIT_GAS);

    waitAndRecoverStake(pool, validator, elector.address);

    val afterRecovery = pool.getNominatorData(newNominator.address.getWorkchainAndHash().1);
    expect(afterRecovery.pendingDepositAmount).toEqual(0);
    // 1 nano off could be due to rounding
    expect(afterRecovery.amount as int).toBeApproxEqAbs(depoAmount - DEPOSIT_GAS, 1);
}

get fun `test nominator with both pending withdrawals and pending depo, should end up with correct balance`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

    val testNm = nominators.get(random.range(39));
    val nmHash = testNm.getWorkchainAndHash().1;

    val depoValue = random.range(ton("20000")) + ton("10000");

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
    // And now suddenly he deposits some back
    val (depoItem, _) = assertDelayedOperation(pool, testNm, false, depoValue);

    val poolBefore = pool.getPoolData();
    expect(poolBefore.pendingDeposits).toEqual(depoValue - DEPOSIT_GAS);
    expect(poolBefore.pendingWithdrawals).toBeGreater(0);

    val res = waitAndRecoverStake(pool, validator, elector.address);

    expect(
        res,
    ).toHaveSuccessfulTx<PayoutBurnNotification>({ from: withdrawalItem.address, to: pool.address });
    expect(
        res,
    ).toHaveSuccessfulTx<PayoutBurnNotification>({ from: depoItem.address, to: pool.address });

    val nmAfter = pool.getNominatorData(nmHash);

    expect(nmAfter.amount as int).toBeApproxEqAbs(depoValue - DEPOSIT_GAS, 1);
    expect(nmAfter.pendingDepositAmount).toEqual(0);

    val poolAfter = pool.getPoolData();
    val rawNms = poolAfter.nominators.load();

    expect(poolAfter.pendingDeposits).toEqual(0);
    expect(poolAfter.pendingWithdrawals).toEqual(0);
    expect(rawNms.pendingDeposits).toBeNull();
    expect(rawNms.pendingWithdrawals).toBeNull();
}

get fun `test that if any stakes used in prev round, deposit should become pending`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(40);

    val testNm = testing.treasury("testNominator");
    val depoValue = random.range(ton("20000")) + ton("10000");

    // No previous usage, so depo should be instant
    assertPoolDepositInstant(pool, testNm.address, depoValue);
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
    );

    val poolBefore = pool.getPoolData();
    expect(poolBefore.roundClosed).toBeFalse();

    assertDelayedOperation(pool, testNm.address, false, depoValue);
}

get fun `test if nominator has pending deposits, withdrawal should go pending`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(20);

    val randomNm = nominators.get(random.range(19));

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
    );

    val depoValue = random.range(ton("20000")) + ton("10000");

    // There are stakes in prev round, so depo will go pending
    assertDelayedOperation(pool, randomNm, false, depoValue);
    // But the withdrawal might have been instant, that would be no bueno
    assertDelayedOperation(pool, randomNm, true);
}

get fun `test that pending operations can only be claimed once`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

    var testNominators = nominators;

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

    val poolBefore = pool.getPoolData();
    val testNominator = testNominators.popHead();
    val depositor = testNominators.popHead();
    val nmData = pool.getNominatorData(testNominator.getWorkchainAndHash().1);

    var (testItem, _sharesBurned) = assertDelayedOperation(pool, testNominator, true);
    var (depositItem, _) = assertDelayedOperation(pool, depositor, false);

    var balanceBefore = testing.getAccountBalance(pool.address);
    val withdrawalMsg = createMessage({
        dest: pool.address,
        value: ton("0.1"),
        bounce: false,
        body: PayoutBurnNotification {
            owner: testNominator,
            queryId: 0,
            isWithdrawal: true,
            index: 1,
            roundIndex: 1,
            distribution: {
                pendingShare: poolBefore.poolSupply,
                pendingCoins: poolBefore.nominatorsAmount,
            },
        },
    });

    val depositMsg = createMessage({
        dest: pool.address,
        value: ton("0.1"),
        bounce: false,
        body: PayoutBurnNotification {
            owner: depositor,
            queryId: 0,
            isWithdrawal: false,
            index: 1, // Same index because deposit and withdrawal have separate indexes
            roundIndex: 1,
            distribution: {
                pendingShare: poolBefore.poolSupply,
                pendingCoins: poolBefore.nominatorsAmount,
            },
        },
    });

    val depositorBefore = pool.getNominatorData(depositor.getWorkchainAndHash().1);
    var res = net.send(testItem.address, withdrawalMsg);

    // once it works
    var balanceAfter = testing.getAccountBalance(pool.address);

    expect(res).toHaveTx<WithdrawSuccess>({ from: pool.address, to: testNominator });
    expect(balanceBefore - balanceAfter).toEqual(nmData.amount);
    balanceBefore = balanceAfter;

    repeat (5) {
        res = net.send(testItem.address, withdrawalMsg);

        expect(
            res,
        ).toHaveFailedTx<PayoutBurnNotification>({ from: testItem.address, to: pool.address, exitCode: ErrorsPool.DepositNotFound });
        expect(res).toNotHaveTx<WithdrawSuccess>({ from: pool.address, to: testNominator });
    }
    balanceAfter = testing.getAccountBalance(pool.address);
    expect(balanceAfter).toBeGreaterOrEqual(balanceBefore);

    balanceBefore = balanceAfter;

    res = net.send(depositItem.address, depositMsg);
    expect(res).toHaveSuccessfulTx<PayoutBurnNotification>({ to: pool.address });

    val depositorAfter = pool.getNominatorData(depositor.getWorkchainAndHash().1);

    expect(depositorAfter.amount).toBeGreater(depositorBefore.amount);
    expect(depositorAfter.pendingDepositAmount).toEqual(0);

    balanceBefore = testing.getAccountBalance(pool.address);
    repeat (5) {
        res = net.send(depositItem.address, depositMsg);

        expect(
            res,
        ).toHaveFailedTx<PayoutBurnNotification>({ from: depositItem.address, to: pool.address, exitCode: ErrorsPool.NothingToDeposit });
        expect(res).toNotHaveTx<WithdrawSuccess>({ from: pool.address, to: depositor });
    }

    balanceAfter = testing.getAccountBalance(pool.address);
    expect(balanceAfter).toBeGreaterOrEqual(balanceBefore);
}

get fun `test pending withdrawal triggered with less than WITHDRAWAL_GAS should be rejected`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(100);

    var testNominators = nominators;
    val testNominator = testNominators.popHead();

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

    val stateBefore = getAccountData(pool.address);
    val res = pool.sendTextComment(testNominator, "w".beginParse(), { value: WITHDRAWAL_GAS - 1 });

    expect(res).toHaveRefund<TextComment>({
        from: pool.address,
        to: testNominator,
        previousState: stateBefore,
        error: ErrorsPool.NotEnoughGas,
    });
}

get fun `test pending withdrawal should be allowed once per round`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(100);

    var testNominators = nominators;

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

    val testNominator = testNominators.popHead();

    var (_testItem, _sharesBurned) = assertDelayedOperation(pool, testNominator, true);

    val stateBefore = getAccountData(pool.address);
    val res = pool.sendTextComment(testNominator, "w".beginParse(), { value: WITHDRAWAL_GAS });

    expect(res).toHaveRefund<TextComment>({
        from: pool.address,
        to: testNominator,
        error: ErrorsPool.WithdrawalAlreadyRequested,
        previousState: stateBefore,
    });
}

get fun `test nominators that withdrawn/deposited in pending mode should bare round effects`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

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

    val depositorNm = nominators.get(random.range(40 - 1));
    var withdrawNm: address;

    do {
        withdrawNm = nominators.get(random.range(40 - 1));
    } while (withdrawNm == depositorNm);

    val withdrawHash = withdrawNm.getWorkchainAndHash().1;
    val depositHash = depositorNm.getWorkchainAndHash().1;

    val withdrawBefore = pool.getNominatorData(withdrawHash);
    val depositorBefore = pool.getNominatorData(depositHash);

    val poolBefore = pool.getPoolData();
    val nmRawBefore = poolBefore.nominators.load();
    val rawDepositorBefore = nmRawBefore.poolNominators.mustGet(depositorNm, 42);

    assertDelayedOperation(pool, withdrawNm, true);
    // Amount is share price
    assertDelayedOperation(pool, depositorNm, false, depositorBefore.amount);

    val res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    // The one withdrawing should get more than initial amount
    val withdrawTx = res.findTransaction<WithdrawSuccess>({
        to: withdrawNm,
    });
    expect(withdrawTx).toBeNotNull();

    val _withdrawMsg = withdrawTx!.loadInMsg<WithdrawSuccess>();
    // println(getInternalMessageValue(withdrawMsg.info).grams);

    expect(res).toHaveTx<WithdrawSuccess>({
        value: fun(value) {
            return value > withdrawBefore.amount;
        },
    });
    // The one depositing should get less shares for same amount
    val poolAfter = pool.getPoolData();
    val rawNmAfter = poolAfter.nominators.load();
    val rawDepositorAfter = rawNmAfter.poolNominators.mustGet(depositorNm, 42);

    expect(rawDepositorAfter.share).toBeGreater(rawDepositorBefore.share);
    // We have deposited same amount, but after profit, so it should not be 1/1 anymore
    expect(rawDepositorAfter.share).toBeLess(rawDepositorBefore.share * 2);
}

get fun `test in closed round, withdraw should become pending and be fullfilled at the end of the round(FULL POOL)`() {
    val (elector, stakes, limits) = setupElector();
    val (
        pool,
        owner,
        _notOwner,
        validator,
        _randomValidator,
        nominators,
    ) = setupFullyBookedPool();

    var testNominators = nominators;

    var elections = announceElections(elector);
    val poolInitial = pool.getPoolData();
    val validatorsInitial = poolInitial.validators.load();
    var valLookup = validatorsInitial.validators.findFirst();
    // Let's make a fully staked 32 slots
    while (valLookup.isFound) {
        val valAddress = valLookup.getKey();
        if (valAddress != validator) {
            assertPoolNewStake(valAddress, pool, elector, elections, stakes.minStake * 2);
        }
        valLookup = validatorsInitial.validators.iterateNext(valLookup);
    }
    assertPoolNewStake(validator, pool, elector, elections, stakes.minStake * 2);

    runElections(elector, stakes, limits);

    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    elections = announceElections(elector);

    valLookup = validatorsInitial.validators.findFirst();
    // Let's make a fully staked 32 slots
    while (valLookup.isFound) {
        val valAddress = valLookup.getKey();
        if (valAddress != validator) {
            assertPoolNewStake(valAddress, pool, elector, elections, stakes.minStake * 2);
        }
        valLookup = validatorsInitial.validators.iterateNext(valLookup);
    }
    assertPoolNewStake(validator, pool, elector, elections, stakes.minStake * 2);
    runElections(elector, stakes, limits);

    val fatUpd = pool.sendUpdateVset(owner.address, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    expect(
        fatUpd,
    ).toHaveSuccessfulTx<UpdateVset>({ from: owner.address, to: pool.address, aborted: false });

    var nmLookup: map<address, coins> = [];

    var testNominator = testNominators.popHead();
    val poolBefore = pool.getPoolData();

    var (testItem, sharesBurned) = assertDelayedOperation(pool, testNominator, true);
    var prevItemAddr = testItem.address;
    var prevItemData = testItem.getPayoutInfo();

    nmLookup.set(testNominator, sharesBurned);
    repeat (4) {
        testNominator = testNominators.popHead();

        var (testItem, burnt) = assertDelayedOperation(pool, testNominator, true);

        nmLookup.set(testNominator, burnt);
        sharesBurned += burnt;
        val itemData = testItem.getPayoutInfo();
        expect(itemData.owner).toEqual(testNominator);
        expect(itemData.owner).toNotEqual(prevItemData.owner);
        expect(itemData.data.roundIndex).toEqual(prevItemData.data.roundIndex);
        expect(itemData.data.next).toEqual(prevItemAddr);
        expect(prevItemData.data.prev).toEqual(testItem.address);
        prevItemData = itemData;
        prevItemAddr = testItem.address;
    }

    valLookup = validatorsInitial.validators.findFirst();
    // All validators out of prev round
    var totalProfit = 0;
    var nominatorsProfit = totalProfit;
    var ownerProfit = totalProfit;

    while (valLookup.isFound) {
        val valAddress = valLookup.getKey();
        if (valAddress != validator) {
            val res = waitAndRecoverStake(pool, valAddress, elector.address);

            val stakeReturnedTx = res.findTransaction<StakeReturned>({ from: pool.address, to: valAddress });
            expect(stakeReturnedTx).toBeNotNull();

            val stakeReturned = stakeReturnedTx!.loadBody<StakeReturned>();
            val stakeProfit = stakeReturned.returned - stakeReturned.used;
            val ownerProfitFromStake = mulDivFloor(stakeProfit, poolBefore.ownerShare, SHARE_BASE);
            val nmProfitFromStake = stakeProfit - ownerProfitFromStake;
            totalProfit += stakeProfit;
            ownerProfit += ownerProfitFromStake;
            nominatorsProfit += nmProfitFromStake;
        }
        valLookup = validatorsInitial.validators.iterateNext(valLookup);
    }
    val res = waitAndRecoverStake(pool, validator, elector.address);

    // println(res);
    //
    val recoverTx = res.findTransaction<RecoverStakeOk>({ to: pool.address });
    val stakeReturnedTx = res.findTransaction<StakeReturned>({ from: pool.address, to: validator });
    expect(recoverTx != null).toBeTrue();
    expect(stakeReturnedTx != null).toBeTrue();
    val stakeReturned = stakeReturnedTx!.loadBody<StakeReturned>();
    val lastStakeProfit = stakeReturned.returned - stakeReturned.used;

    nominatorsProfit += lastStakeProfit -
    mulDivFloor(lastStakeProfit, poolBefore.ownerShare, SHARE_BASE);

    expect(res).toHaveSuccessfulTx<PayoutBurnNotification>({ to: pool.address });
    expect(res).toHaveSuccessfulTx<PayoutBurnMessage>({ from: pool.address });

    val burnTx = res.findTransaction<PayoutBurnNotification>({ to: pool.address });
    expect(burnTx).toBeNotNull();
    val burnBody = burnTx!.loadBody<PayoutBurnNotification>();

    var lookup = nmLookup.findFirst();
    val poolAfter = pool.getPoolData();
    expect(poolAfter.poolSupply).toEqual(poolBefore.poolSupply - sharesBurned);
    val nmAfter = poolAfter.nominators.load();
    expect(poolAfter.pendingWithdrawals).toEqual(0);
    expect(nmAfter.pendingWithdrawals == null).toBeTrue();
    var totalWithdrwn = 0;
    while (lookup.isFound) {
        val curAddress = lookup.getKey();
        val curValue = lookup.loadValue();
        totalWithdrwn += mulDivFloor(
            curValue,
            burnBody.distribution.pendingCoins,
            burnBody.distribution.pendingShare,
        );
        expect(res).toHaveTx<WithdrawSuccess>({
            to: curAddress,
            value: fun(msgValue: coins) {
                return msgValue >= curValue;
            },
        });
        lookup = nmLookup.iterateNext(lookup);
        expect(nmAfter.poolNominators.exists(curAddress)).toBeFalse();
    }
    expect(poolAfter.nominatorsAmount).toEqual(
        poolBefore.nominatorsAmount + nominatorsProfit - totalWithdrwn,
    );
}

get fun `test nm dictionary depth limit`() {
    val (pool, _owner, _notOwner, _vaidator) = setupDeployedPool();
    var depoHash = 0;
    var iterCount = 0;
    val testDepo = ton("10000");

    while (iterCount < MAX_NM_DEPTH + 1) {
        var testKey = address.fromWorkchainAndHash(BASECHAIN, depoHash);
        assertPoolDepositInstant(pool, testKey, testDepo);
        iterCount += 1;
        depoHash |= 1 << iterCount;
    }
    val poolAfter = pool.getPoolData();
    val nmAfter = lazy poolAfter.nominators.load();
    expect(nmAfter.poolNominators.toLowLevelDict().depth()).toEqual(MAX_NM_DEPTH);

    val stateBefore = getAccountData(pool.address);
    val balanceBefore = testing.getAccountBalance(pool.address);
    depoHash |= 1 << (iterCount + 1);

    val tooDeepAddress = address.fromWorkchainAndHash(BASECHAIN, depoHash);
    var depoReject = pool.sendTextComment(tooDeepAddress, "d".beginParse(), { value: testDepo });

    expect(depoReject).toHaveRefund<TextComment>({
        from: pool.address,
        to: tooDeepAddress,
        error: ErrorsPool.NominatorsTooDeep,
        previousState: stateBefore,
        initialBalance: balanceBefore,
    });
}

get fun `test in closed round, deposit should become pending`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(100);

    var testNominators = nominators;

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

    var testNominator = testNominators.popHead();
    var (testItem, _) = assertDelayedOperation(pool, testNominator, false);
    var prevItemAddr = testItem.address;
    var prevItemData = testItem.getPayoutInfo();
    repeat (4) {
        testNominator = testNominators.popHead();
        (testItem, _) = assertDelayedOperation(pool, testNominator, false);
        val itemData = testItem.getPayoutInfo();
        expect(itemData.owner).toEqual(testNominator);
        expect(itemData.owner).toNotEqual(prevItemData.owner);
        expect(itemData.data.roundIndex).toEqual(prevItemData.data.roundIndex);
        expect(itemData.data.next).toEqual(prevItemAddr);
        expect(prevItemData.data.prev).toEqual(testItem.address);
        prevItemData = itemData;
        prevItemAddr = testItem.address;
    }
}

get fun `test if whitelist is set, only nms on the list are allowed to depo`() {
    var (_share, _validatorsSettings, nominatorsSettings) = defaultDeployParams();
    val (elector, stakes, limits) = setupElector();
    var whitelistNms: map<address, bool> = [];
    repeat (5) {
        val newAddr = address.fromWorkchainAndHash(BASECHAIN, random.uint256());
        whitelistNms.set(newAddr, true);
    }
    nominatorsSettings.whitelist = whitelistNms;

    nominatorsSettings.whitelist = whitelistNms;
    val (pool, _owner, _notOwner, validator) = setupDeployedPool({
        nominatorsSettings,
    });

    var testNm: address;
    do {
        testNm = address.fromWorkchainAndHash(BASECHAIN, random.uint256());
    } while (whitelistNms.exists(testNm));

    var stateBefore = getAccountData(pool.address);
    var balanceBefore = testing.getAccountBalance(pool.address);
    val testAmount = stakes.minStake * 5;
    var depoReject = pool.sendTextComment(testNm, "d".beginParse(), { value: testAmount });

    expect(depoReject).toHaveRefund<TextComment>({
        to: testNm,
        from: pool.address,
        previousState: stateBefore,
        initialBalance: balanceBefore,
        error: ErrorsPool.DepositNotAllowed,
    });

    var lookup = whitelistNms.findFirst();
    while (lookup.isFound) {
        val testAddr = lookup.getKey();
        assertPoolDepositInstant(pool, testAddr, testAmount);
        lookup = whitelistNms.iterateNext(lookup);
    }

    // Now in pending mode
    runRound(pool, elector, stakes, limits, validator);
    stateBefore = getAccountData(pool.address);
    balanceBefore = testing.getAccountBalance(pool.address);
    depoReject = pool.sendTextComment(testNm, "d".beginParse(), { value: testAmount });

    expect(depoReject).toHaveRefund<TextComment>({
        to: testNm,
        from: pool.address,
        previousState: stateBefore,
        initialBalance: balanceBefore,
        error: ErrorsPool.DepositNotAllowed,
    });

    lookup = whitelistNms.findFirst();
    while (lookup.isFound) {
        val testAddr = lookup.getKey();
        assertDelayedOperation(pool, testAddr, false, testAmount);
        lookup = whitelistNms.iterateNext(lookup);
    }
}

get fun `test run 5 rounds measure that nominators share grows at same rate as owner's`() {
    val (elector, stakes, limits) = setupElector();
    var (pool, _owner, _notOwner, validator) = setupDeployedPool();

    val testNm = testing.treasury("FatCat");
    val nmHash = testNm.address.getHash();
    val testStake = stakes.minStake * 2;

    // For simplicity pick 1 nm. So it is easier to track accrued profit
    assertPoolDepositInstant(pool, testNm.address, ton("1000000"));
    val nmBefore = pool.getNominatorData(nmHash);
    expect(nmBefore.reward).toEqual(0);

    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    val balanceBefore = testing.getAccountBalance(pool.address);

    val maxPunishment = pool.getMaxPunishment(0);
    val ownerEquityBefore = balanceBefore + validators.stakeUsed - poolBefore.pendingDeposits -
    POOL_MIN_STORAGE -
    poolBefore.nominatorsAmount -
    maxPunishment * validators.activeSlots;

    println("Owner equity before {}", ownerEquityBefore);

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
        testStake,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
        testStake,
    );

    repeat (3) {
        val res = waitAndRecoverStake(pool, validator, elector.address);
        expect(res).toHaveSuccessfulTx<RecoverStakeOk>({
            to: pool.address,
            value: fun(retValue) {
                return retValue > testStake;
            },
        });
        runRound(
            pool,
            elector,
            stakes,
            limits,
            validator,
            0,
            true,
            testStake,
        );
    }

    var res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({
        to: pool.address,
        value: fun(retValue) {
            return retValue > testStake;
        },
    });

    announceElections(elector);
    runElections(elector, stakes, limits);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    res = waitAndRecoverStake(pool, validator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({
        to: pool.address,
        value: fun(retValue) {
            return retValue > testStake;
        },
    });

    val vdAfter = pool.getValidatorInfo(validator);
    expect(vdAfter.validator.usageState).toEqual(0);

    val nmAfter = pool.getNominatorData(nmHash);
    expect(nmAfter.reward).toBeGreater(0);

    val balanceAfter = testing.getAccountBalance(pool.address);
    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();

    val ownerEquityAfter = balanceAfter + validatorsAfter.stakeUsed - poolAfter.pendingDeposits -
    POOL_MIN_STORAGE -
    poolAfter.nominatorsAmount -
    maxPunishment * validatorsAfter.activeSlots;
    println("Equity after: {}", ownerEquityAfter);
    println("Nm reward: {:grams}", nmAfter.reward);

    val reserveDelta = maxPunishment *
    (validatorsAfter.activeSlots - validators.activeSlots) as int;
    val ownerProfitGain = ownerEquityAfter - ownerEquityBefore + reserveDelta;
    println("ownerProfit={:gram}", ownerProfitGain);
    println("reserveDelta={:gram} ownerProfitGain={:gram}", reserveDelta, ownerProfitGain);
    println("profitDelta ={:gram}", ownerProfitGain - nmAfter.reward);

    // Profit is split 50/50, while the owner bears operational gas costs.
    expect(ownerProfitGain).toBeLessOrEqual(nmAfter.reward);
}

fun separateFeesCost(tx: TlbTransaction): int {
    val compute = getTxComputePh(tx);
    val action = getTxActionPh(tx);
    val totalFwd = action.totalFwdFees.unwrapOr(0 as coins) as int;
    calculateGasFee(BASECHAIN, tx.getUsedGas());
    return compute.gasFees + totalFwd;
}

get fun `test masterchain forwarding dominates owner operational cost`() {
    val (elector, stakes, limits) = setupElector();
    var (pool, _owner, _notOwner, validator) = setupDeployedPool();
    val testNm = testing.treasury("FatCat");
    assertPoolDepositInstant(pool, testNm.address, ton("1000000"));
    val testStake = stakes.minStake * 2;

    val elections = announceElections(elector);
    val stakeRes = pool.sendNewStake(
        validator,
        DEFAULT_QUERY_ID,
        testStake,
        getSignedBody(elections),
        { value: ton("1") },
    );
    val newStakeTx = stakeRes.findTransaction<NewStake>({ to: pool.address })!;
    val newStakeCost = separateFeesCost(newStakeTx);

    runElections(elector, stakes, limits);
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
        testStake,
    );

    val recoverRes = waitAndRecoverStake(pool, validator, elector.address);
    val recoverCompatTx = recoverRes.findTransaction({
        to: pool.address,
        opcode: opcode<RecoverStakeCompat>(),
    })!;
    val recoverCompatCost = separateFeesCost(recoverCompatTx);

    val combined = newStakeCost + recoverCompatCost;
    println("NewStake separate-fees cost={:gram}", newStakeCost);
    println("RecoverStakeCompat separate-fees cost={:gram}", recoverCompatCost);
    println("combined per cycle={:gram}; five cycles={:gram}", combined, combined * 5);

    expect(recoverCompatCost).toBeGreater(newStakeCost);
    expect(combined * 5 as int).toBeApproxEqAbs(ton("0.52") as int, ton("0.01") as int);
}
