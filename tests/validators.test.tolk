import "@stdlib/gas-payments"
import "@stdlib/lisp-lists"
import "@stdlib/tvm-lowlevel"
import "@acton/build"
import "@acton/io"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/tlb/maybe"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/config"
import "@contracts/errors"

import "@contracts/fees"
import "@contracts/messages"
import "@contracts/opcode"
import "@contracts/types"
import "@tests/deploy-utils"
import "@tests/elector-utils"
import "@tests/matchers"
import "@tests/pool-utils"
import "@tests/proxy-utils"
import "@tests/test-utils"
import "@wrappers/ElectorCode.gen"
import "@wrappers/Pool.gen"
import "@wrappers/Proxy.gen"

get fun `test validator allowed for only even/odd rounds, should only stake in allowed rounds`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(20);

    val maxPunishment = pool.getMaxPunishment(0);
    val minValue = maxPunishment + PROXY_MIN_STORAGE * 2 + ton("1");

    val queryId = random.range(128);
    val evenRoundValidator = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());
    val oddRoundValidator: address = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());

    pool.sendAddValidator(
        owner.address,
        queryId,
        evenRoundValidator,
        RoundAllowance.InEvenRounds,
        null,
        { value: minValue },
    );
    pool.sendAddValidator(
        owner.address,
        queryId,
        oddRoundValidator,
        RoundAllowance.InOddRounds,
        null,
        { value: minValue },
    );

    val elections = announceElections(elector);
    val minStake = stakes.minStake * 2;

    // Round 0 is even
    // Even validator should succeed
    expect(pool.getValidatorInfo(evenRoundValidator).stakeable).toBeGreaterOrEqual(minStake);
    assertPoolNewStake(evenRoundValidator, pool, elector, elections, minStake);
    val evenValidatorData = pool.getValidatorInfo(evenRoundValidator);
    expect(evenValidatorData.validator.usageState & 1).toEqual(0);
    expect(evenValidatorData.validator.usageState & 2).toEqual(2);
    // Validator that allowed only for odd rounds, should fail
    expect(pool.getValidatorInfo(oddRoundValidator).stakeable).toEqual(0);
    assertNewStakeFailed(
        ErrorsPool.RoundNotAllowed,
        oddRoundValidator,
        pool,
        elector.address,
        elections,
        minStake,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        elections,
    );

    val poolRoundOne = pool.getPoolData();
    val _validators = poolRoundOne.validators.load();
    expect(poolRoundOne.roundIndex).toEqual(1);
    // Now odd round
    // Even one fails
    val nextElections = announceElections(elector);
    expect(pool.getValidatorInfo(evenRoundValidator).stakeable).toEqual(0);
    assertNewStakeFailed(
        ErrorsPool.RoundNotAllowed,
        evenRoundValidator,
        pool,
        elector.address,
        nextElections,
        minStake,
    );
    // Odd one succeeds
    expect(pool.getValidatorInfo(oddRoundValidator).stakeable).toBeGreaterOrEqual(minStake);
    assertPoolNewStake(oddRoundValidator, pool, elector, nextElections, minStake);
    val oddValidatorData = pool.getValidatorInfo(oddRoundValidator);
    expect(oddValidatorData.validator.usageState & 1).toEqual(1);
    expect(oddValidatorData.validator.usageState & 2).toEqual(0);
}

get fun `test only added validator could stake`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(20);

    val minStake = stakes.minStake * 2;

    val poolBefore = pool.getPoolData();
    val validators = lazy poolBefore.validators.load();

    val testValidator = getDifferentAddress(validators.mainValidatorAddress);

    val elections = announceElections(elector);
    assertNewStakeFailed(
        ErrorsPool.ValidatorNotFound,
        testValidator,
        pool,
        elector.address,
        elections,
        minStake,
    );
}

get fun `test validator ton limit should affect amount of stake allowed to be taken`() {
    val (elector, _stakes, _limits) = setupElector();
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(100);

    val (_ownerShare, validatorsSettings, _nominatorsSettings) = defaultDeployParams();
    val maxStake = validatorsSettings.minTonPerValidator + ton("1000");

    val testValidator = setupRandomValidator(
        pool,
        owner.address,
        ValidatorLimitTon { maxTon: maxStake },
    );

    expect(pool.getValidatorInfo(testValidator).stakeable).toEqual(maxStake);
    val elections = announceElections(elector);
    assertNewStakeFailed(
        ErrorsPool.StakeAboveTheLimit,
        testValidator,
        pool,
        elector.address,
        elections,
        maxStake + 1,
    );
    assertNewStakeFailed(
        ErrorsPool.StakeBelowLimit,
        testValidator,
        pool,
        elector.address,
        elections,
        validatorsSettings.minTonPerValidator - 1,
    );
    assertPoolNewStake(testValidator, pool, elector, elections, maxStake);
}

get fun `test validator share limit should affect amount of stake allowed to be taken`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    val (_ownerShare, _validatorsSettings, _nominatorsSettings) = defaultDeployParams();
    val maxShare = SHARE_BASE / 5; // 20%

    val testValidator = setupRandomValidator(pool, owner.address, ValidatorLimitShare { maxShare });

    // Since no stake is yet used, and no pendings, total is practically equal to current - reserves
    val availableFunds = testing.getAccountBalance(pool.address) - POOL_MIN_STORAGE;
    val maxStake = mulDivFloor(availableFunds, maxShare, SHARE_BASE); //awailableFunds / 5;

    expect(pool.getValidatorInfo(testValidator).stakeable).toEqual(maxStake);
    val elections = announceElections(elector);
    assertNewStakeFailed(
        ErrorsPool.StakeAboveTheLimit,
        testValidator,
        pool,
        elector.address,
        elections,
        maxStake + 1,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        testValidator,
        elections,
        false,
        maxStake - 1,
    );
    // Stake is taken at this point, however, since share limit is calculateAddress
    // based on the total theoretical pool balance, limit should not change
    announceElections(elector);
    expect(pool.getValidatorInfo(testValidator).stakeable as int).toBeApproxEqAbs(
        maxStake,
        ton("1"),
    );
    // assertPoolNewStake(testValidator, pool, elector, elections, maxStake - 1);
}

get fun `test should not be able to stake if validators.minStake became below network minStake`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val testStake = stakes.minStake * 2;
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

    var config = testing.getConfig();
    var curStakes = StakesConfig.fromCell(config.getParamRaw(STAKES_IDX));
    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();

    curStakes.minStake = validators.minTonPerValidator + 1;

    config.setParamRaw(STAKES_IDX, curStakes.toCell());
    expect(pool.getValidatorInfo(validator).stakeable).toBeGreater(0);
    testing.setConfig(config);

    val elections = announceElections(elector);
    expect(pool.getValidatorInfo(validator).stakeable).toEqual(0);

    assertNewStakeFailed(
        ErrorsPool.MinStakeBelowNetworkLimit,
        validator,
        pool,
        elector.address,
        elections,
        testStake,
    );
}

get fun `test should not be able to stake if validators.maxTonPerValidator became above network maxStake`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val testStake = stakes.minStake * 2;
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

    var config = testing.getConfig();
    var curStakes = StakesConfig.fromCell(config.getParamRaw(STAKES_IDX));
    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();

    curStakes.maxStake = validators.maxTonPerValidator - 1;

    config.setParamRaw(STAKES_IDX, curStakes.toCell());
    expect(pool.getValidatorInfo(validator).stakeable).toBeGreater(0);
    testing.setConfig(config);

    val elections = announceElections(elector);
    expect(pool.getValidatorInfo(validator).stakeable).toEqual(0);

    assertNewStakeFailed(
        ErrorsPool.MaxStakeAboveNetworkLimit,
        validator,
        pool,
        elector.address,
        elections,
        testStake,
    );
}

get fun `test shoulld reject new stake when balance is below the requested value`() {
    val (elector, _stakes, _limits) = setupElector();
    var (pool, _owner, _notOwner, validator, nominators) = setupPoolWithNominators(10);

    val (_ownerShare, validatorsSettings, _nominatorsSettings) = defaultDeployParams();

    val availableFunds = testing.getAccountBalance(pool.address) - POOL_MIN_STORAGE;
    expect(validatorsSettings.maxTonPerValidator).toBeGreater(availableFunds);
    expect(pool.getValidatorInfo(validator).stakeable).toBeLess(
        validatorsSettings.maxTonPerValidator,
    );

    val elections = announceElections(elector);
    assertNewStakeFailed(
        ErrorsPool.NotEnoughPoolBalance,
        validator,
        pool,
        elector.address,
        elections,
        validatorsSettings.maxTonPerValidator,
    );

    assertPoolDepositInstant(
        pool,
        nominators.popHead(),
        validatorsSettings.maxTonPerValidator - availableFunds + DEPOSIT_GAS,
    );

    expect(pool.getValidatorInfo(validator).stakeable).toEqual(
        validatorsSettings.maxTonPerValidator,
    );
    assertPoolNewStake(validator, pool, elector, elections, validatorsSettings.maxTonPerValidator);
}

get fun `test should not be able to stake when round is closed`() {
    val (elector, stakes, limits) = setupElector();
    var (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    // Just for illustative purposes granting all rounds allowance explicitly
    val additionalValidator = setupRandomValidator(
        pool,
        owner.address,
        null,
        RoundAllowance.InAllRounds,
    );

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

    expect(pool.getValidatorInfo(additionalValidator).stakeable).toEqual(0);
    val elections = announceElections(elector);
    assertNewStakeFailed(
        ErrorsPool.RoundIsClosed,
        additionalValidator,
        pool,
        elector.address,
        elections,
        stakes.minStake * 2,
    );
}

get fun `test should not be able to stake twice in a same round`() {
    val (elector, stakes, _limits) = setupElector();
    var (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val elections = announceElections(elector);
    assertPoolNewStake(validator, pool, elector, elections, stakes.minStake * 2);
    expect(pool.getValidatorInfo(validator).stakeable).toEqual(0);
    assertNewStakeFailed(
        ErrorsPool.AlreadyStakedInThatRound,
        validator,
        pool,
        elector.address,
        elections,
        stakes.minStake * 2,
    );
}

get fun `test should not allow to stake before the elections started`() {
    val (elector, stakes, _limits) = setupElector();
    var (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val electionsTiming = getElectionsTiming();

    // It is tedious to update the current time, because of account last tx time
    // So we update the vset itself
    var config = testing.getConfig();
    var currentVset = ValidaorSet.fromCell(config.getParamRaw(CUR_VSET_IDX));
    currentVset.utimeUntil = testing.getNow() + electionsTiming.startBefore;

    config.setParamRaw(CUR_VSET_IDX, currentVset.toCell());
    testing.setConfig(config);

    assertNewStakeFailed(
        ErrorsPool.ElectionsNotStarted,
        validator,
        pool,
        elector.address,
        0,
        stakes.minStake * 2,
    );
}

get fun `test should not allow to stake after the elections ended`() {
    val (elector, stakes, _limits) = setupElector();
    var (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val electionsTiming = getElectionsTiming();

    // It is tedious to update the current time, because of account last tx time
    // So we update the vset itself
    var config = testing.getConfig();
    var currentVset = ValidaorSet.fromCell(config.getParamRaw(CUR_VSET_IDX));
    currentVset.utimeUntil = testing.getNow() + electionsTiming.endBefore;

    config.setParamRaw(CUR_VSET_IDX, currentVset.toCell());
    testing.setConfig(config);

    assertNewStakeFailed(
        ErrorsPool.ElectionsAlreadyEnded,
        validator,
        pool,
        elector.address,
        0,
        stakes.minStake * 2,
    );
}

get fun `test new stake should treat pending amounts as not available when allowing stakes`() {
    val (elector, _stakes, _limits) = setupElector();
    val (pool, owner, _notOwner, vaidator) = setupDeployedPool();

    val (_ownerShare, validatorsSettings, _nominatorsSettings) = defaultDeployParams();

    val additionalValidator = setupRandomValidator(pool, owner.address);

    val poorFella1 = testing.treasury("Fella 1");
    val poorFella2 = testing.treasury("Fella 2");
    val poorFella3 = testing.treasury("Fella 3");
    val fatCat = testing.treasury("FatCat");

    assertPoolDepositInstant(
        pool,
        poorFella1.address,
        validatorsSettings.minTonPerValidator + DEPOSIT_GAS,
    );
    assertPoolDepositInstant(
        pool,
        poorFella2.address,
        validatorsSettings.minTonPerValidator + DEPOSIT_GAS,
    );
    assertPoolDepositInstant(
        pool,
        poorFella3.address,
        validatorsSettings.minTonPerValidator + DEPOSIT_GAS,
    );
    assertPoolDepositInstant(
        pool,
        fatCat.address,
        validatorsSettings.maxTonPerValidator + DEPOSIT_GAS,
    );

    val elections = announceElections(elector);

    assertPoolNewStake(
        vaidator,
        pool,
        elector,
        elections,
        validatorsSettings.minTonPerValidator * 4,
    );

    // Now if fatCat wants out, he has to wait till the round closure.
    assertDelayedOperation(pool, fatCat.address, true);

    // Which means there is technically still a lottamoney in da pool
    val poolBalance = testing.getAccountBalance(pool.address);
    expect(poolBalance - POOL_MIN_STORAGE).toBeGreater(validatorsSettings.minTonPerValidator * 2);

    // Even though request is just half the balance
    expect(pool.getValidatorInfo(vaidator).stakeable).toEqual(0);
    assertNewStakeFailed(
        ErrorsPool.NotEnoughPoolBalance,
        additionalValidator,
        pool,
        elector.address,
        elections,
        validatorsSettings.minTonPerValidator,
    );
}

get fun `test pool should account for slashing reserves from owner share`() {
    val (elector, stakes, limits) = setupElector();
    var (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(40);

    val stake = stakes.minStake * 2;
    var elections = announceElections(elector);

    val otherValidator = setupRandomValidator(pool, owner.address);

    // But the reserve for 3 slots are still in a pool, so so far so good
    assertPoolNewStake(validator, pool, elector, elections, stake);

    // Since there was no explicit AddFunds, owner only has maxPunishment * 4 slots

    runRound(
        pool,
        elector,
        stakes,
        limits,
        otherValidator,
        elections,
        false,
    );
    elections = announceElections(elector);

    // Any kidn owner withdrawal won't allow for the 4-th slot to be used
    pool.sendOwnerWithdrawal(owner.address, DEFAULT_QUERY_ID, ton("5"), { value: ton("1") });

    assertPoolNewStake(validator, pool, elector, elections, stake);

    val poolData = pool.getPoolData();
    val validators = lazy poolData.validators.load();
    expect(validators.activeSlots).toEqual(3);
    expect(pool.getValidatorInfo(otherValidator).stakeable).toEqual(0);
    // But a fourth will fail
    assertNewStakeFailed(
        ErrorsPool.OwnerShareIsUndercapitalized,
        otherValidator,
        pool,
        elector.address,
        elections,
        stake,
    );
}

get fun `test should not allow new stake messages without queryId`() {
    val (elector, _stakes, _limits) = setupElector();
    var (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    // In that case pool won't get notification back from the elector.

    val elections = announceElections(elector);
    val stateBefore = getAccountData(pool.address);
    val res = pool.sendNewStake(validator, 0, ton("1"), getSignedBody(elections));

    expect(res).toHaveRefund<NewStake>({
        from: pool.address,
        to: validator,
        error: ErrorsPool.QueryIdRequired,
        previousState: stateBefore,
    });
}

get fun `test pool should not accept malformed NewStake messages`() {
    val (elector, stakes, _limits) = setupElector();
    var (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val elections = announceElections(elector);

    val signedBody = getSignedBody(elections);
    var noSignature = signedBody;
    var validBody = signedBody;
    val excessiveBody = beginCell().storeSlice(noSignature).storeString("moardata").endCell();
    // copy

    noSignature.loadRef();

    val truncatedBody = beginCell()
        .storeSlice(validBody.loadBits(validBody.remainingBitsCount() - 1))
        .endCell();

    val noSigMsg = createMessage({
        bounce: true,
        dest: pool.address,
        value: ton("1"),
        body: NewStake {
            value: stakes.minStake * 2,
            queryId: DEFAULT_QUERY_ID,
            signedBody: noSignature,
        },
    });

    val truncatedMsg = createMessage({
        bounce: true,
        dest: pool.address,
        value: ton("1"),
        body: NewStake {
            value: stakes.minStake * 2,
            queryId: DEFAULT_QUERY_ID,
            signedBody: truncatedBody.beginParse(),
        },
    });

    val excessiveMsg = createMessage({
        bounce: true,
        dest: pool.address,
        value: ton("1"),
        body: NewStake {
            value: stakes.minStake * 2,
            queryId: DEFAULT_QUERY_ID,
            signedBody: excessiveBody.beginParse(),
        },
    });

    val stateBefore = getAccountData(pool.address);
    var res = net.send(validator, noSigMsg);
    expect(
        res,
    ).toHaveRefund<NewStake>({ from: pool.address, to: validator, error: VmExitCode.CellUnderflow });

    res = net.send(validator, truncatedMsg);
    expect(
        res,
    ).toHaveRefund<NewStake>({ from: pool.address, to: validator, error: VmExitCode.CellUnderflow });

    res = net.send(validator, excessiveMsg);
    expect(
        res,
    ).toHaveRefund<NewStake>({ from: pool.address, to: validator, error: VmExitCode.CellUnderflow, previousState: stateBefore });
}

get fun `test validator with 2 round allowance should be able to stake in two rounds in a row`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(100);

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
}

get fun `test validator should be able to recover stake and rotate round`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(100);

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

    val valStateBefore = pool.getValidatorInfo(validator);
    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    var prevRound = valStateBefore.usage.prevRoundUsage!;
    val expectedProxy = prevRound.proxy;

    expect(prevRound != null).toBeTrue();
    expect(prevRound.usage.rotation.rotationCount).toEqual(2);

    val res = waitAndRecoverStake(pool, validator, elector.address);
    // pool.sendRecoverStakeCompat(validator, DEFAULT_QUERY_ID, {value: ton("1")});
    val poolAfter = pool.getPoolData();
    // println(res);
    var recoverTx = res.findTransaction({
        from: address.fromWorkchainAndHash(MASTERCHAIN, expectedProxy),
        to: pool.address,
        opcode: opcode<RecoverStakeOk>(),
    });

    expect(recoverTx != null).toBeTrue();
    expect(recoverTx!.outmsgCnt).toEqual(2);
    val inMsg = recoverTx!.loadInMsg<RecoverStakeOk>();
    var profit = getInternalMessageValue(inMsg.info).grams - prevRound.usage.tonUsed;
    expect(profit).toBeGreater(0);
    val refundBonus = validators.refundBonus;
    val profitDelta = refundBonus - min(refundBonus / 3, REFUND_THRESHOLD);
    profit -= calculateGasFee(BASECHAIN, RECOVER_STAKE_OK_GAS) + profitDelta;

    val ownerProfit = mulDivFloor(profit, poolBefore.ownerShare, SHARE_BASE);
    val nominatorsProfit = profit - ownerProfit;
    //println("Owner profit {}", ownerProfit);
    //println("Nominators profit {}", nominatorsProfit);
    expect(poolAfter.nominatorsAmount).toEqual(poolBefore.nominatorsAmount + nominatorsProfit);

    val infoTx = res.findTransaction<RoundInfoMessage>({ from: pool.address, to: owner.address });
    expect(infoTx).toNotEqual(null);

    val infoMsg = infoTx!.loadBody<RoundInfoMessage>();
    expect(infoMsg.info.returned - infoMsg.info.used).toEqual(profit);

    expect(poolAfter.poolSupply).toEqual(poolBefore.poolSupply);

    val validatorsData = poolAfter.validators.load();
    expect(validatorsData.activeSlots).toEqual(validators.activeSlots - 1);
    var validatorAfter = pool.getValidatorInfo(validator);
    // Usage in even round cleared
    expect(validatorAfter.validator.usageState & 2).toEqual(0);
    // Usage in odd round intact
    expect(validatorAfter.validator.usageState & 1).toEqual(1);
    // And sets are rotated!
    expect(validatorAfter.usage.curRoundUsage == null).toBeTrue();
    expect(validatorAfter.usage.prevRoundUsage).toEqual(valStateBefore.usage.curRoundUsage);
    expect(poolAfter.roundIndex).toEqual(poolBefore.roundIndex + 1);
    expect(poolAfter.roundClosed).toBeFalse();

    // Now use the recovered validator to stake again
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        elector.activeElectionId(),
        true,
    );
    // And now we should be able to recover from the second round

    validatorAfter = pool.getValidatorInfo(validator);

    prevRound = validatorAfter.usage.prevRoundUsage!;
    expect(prevRound.usage.rotation.rotationCount).toEqual(2);

    // This round should use different proxy than previous one
    expect(prevRound.proxy).toNotEqual(expectedProxy);

    val secondRecovery = waitAndRecoverStake(pool, validator, elector.address);
    // val secondRecovery = pool.sendRecoverStakeCompat(validator, DEFAULT_QUERY_ID, {value: ton("1")});
    recoverTx = secondRecovery.findTransaction({
        from: address.fromWorkchainAndHash(MASTERCHAIN, prevRound.proxy),
        to: pool.address,
        opcode: opcode<RecoverStakeOk>(),
    });
    expect(recoverTx != null).toBeTrue();
    val recoverMsg = recoverTx!.loadInMsg<RecoverStakeOk>();
    val nextRoundProfit = getInternalMessageValue(recoverMsg.info).grams - prevRound.usage.tonUsed;
    expect(nextRoundProfit).toBeGreater(0);
    // And loop goes on
}

get fun `test get_validator_info should project next round index, if vset updated and round is not closed`() {
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val prevHash = testing.getConfig().getParamRaw(CUR_VSET_IDX).hash();
    val infoBefore = pool.getValidatorInfo(validator);
    expect(infoBefore.rotated).toBeFalse();

    var newSetHash = updateVsetHash();
    expect(newSetHash).toNotEqual(prevHash);
    val infoAfter = pool.getValidatorInfo(validator);
    expect(infoAfter.roundIndex).toEqual(infoBefore.roundIndex + 1);
    expect(infoAfter.rotated).toBeTrue();
    // Since the round is rotated, we should get future stakeable value
    expect(infoAfter.stakeable).toBeGreater(0);
}

get fun `test get_validator_info should not project next round index, if round will close`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
    );
    val infoBefore = pool.getValidatorInfo(validator);

    updateVsetHash();
    // Next round will close
    val infoAfter = pool.getValidatorInfo(validator);
    // So round index should not change
    expect(infoAfter.roundIndex).toEqual(infoBefore.roundIndex);
    // And stakeable amount should be 0
    expect(infoAfter.stakeable).toEqual(0);
}

get fun `test new stake should be able to rotate round if not closed`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    var elections = announceElections(elector);
    val testStake = stakes.minStake * 2;

    val poolBefore = pool.getPoolData();
    assertPoolNewStake(validator, pool, elector, elections, testStake);
    runElections(elector, stakes, limits);
    elections = announceElections(elector);
    expect(pool.getValidatorInfo(validator).stakeable).toBeGreater(0);
    assertPoolNewStake(validator, pool, elector, elections, testStake);
    val poolAfter = pool.getPoolData();

    expect(poolAfter.roundIndex).toEqual(poolBefore.roundIndex + 1);
}

get fun `test new stake should reject if round closed during rotation`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    var elections = announceElections(elector);
    val testStake = stakes.minStake * 2;
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        elections,
        false,
        testStake,
    );

    elections = announceElections(elector);
    updateVsetHash();

    assertNewStakeFailed(
        ErrorsPool.RoundIsClosed,
        validator,
        pool,
        elector.address,
        elections,
        testStake,
    );
}

get fun `test validator should be able to fully close usage record for both rounds`() {
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

    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    val validatorBefore = pool.getValidatorInfo(validator);
    expect(validatorBefore.validator.usageState).toEqual(RoundAllowance.InAllRounds as int);
    val recovery = waitAndRecoverStake(pool, validator, elector.address);
    expect(recovery).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    expect(recovery).toHaveTx<StakeReturned>({ from: pool.address, to: validator });

    val _elections = announceElections(elector);

    runElections(elector, stakes, limits);

    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    val beforeRecovery = pool.getValidatorInfo(validator);
    val secondRecovery = waitAndRecoverStake(pool, validator, elector.address);
    val refundBonus = validators.refundBonus;
    expect(secondRecovery).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    val refundTx = secondRecovery.findTransaction<StakeReturned>({
        from: pool.address,
        to: validator,
    });
    expect(refundTx).toBeNotNull();

    val refundMsg = refundTx!.loadInMsg<StakeReturned>();

    expect(getInternalMessageValue(refundMsg.info).grams).toEqual(
        refundBonus,
    );

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    expect(validatorsAfter.activeSlots).toEqual(0);
    expect(validatorsAfter.stakeUsed).toEqual(0);
    val validatorAfter = pool.getValidatorInfo(validator);
    expect(validatorAfter.validator.usageState).toEqual(0);

    expect(validatorAfter.usage.curRoundUsage).toBeNull();
    expect(validatorAfter.usage.prevRoundUsage).toBeNull();
}

get fun `test anybody could rotate vset for all the validators`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, owner, notOwner, validator, _nominators) = setupPoolWithNominators(40);

    val testStake = stakes.minStake * 2;
    val testValidator = setupRandomValidator(pool, owner.address);
    val testValidatorTwo = setupRandomValidator(pool, owner.address);
    var elections = announceElections(elector);

    assertPoolNewStake(validator, pool, elector, elections, testStake);
    assertPoolNewStake(testValidator, pool, elector, elections, testStake);
    var newSetHash = updateVsetHash();

    pool.sendUpdateVset(
        notOwner.address,
        DEFAULT_QUERY_ID,
        { value: DEFAULT_MSG_VALUE },
    );
    var curTime = testing.getNow();

    val poolBefore = pool.getPoolData();
    val validators = poolBefore.validators.load();
    var _mainBefore = validators.mainValidatorData.load();
    var res = pool.sendUpdateVset(notOwner.address, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    expect(res).toHaveSuccessfulTx<UpdateVset>({ from: notOwner.address, to: pool.address });

    var poolAfter = pool.getPoolData();
    var validatorsAfter = poolAfter.validators.load();
    var mainAfter = validatorsAfter.mainValidatorData.load();
    expect(validatorsAfter.vsetHash).toEqual(newSetHash >> 128);

    var prevRound = validatorsAfter.prevRound.load();
    expect(prevRound.roundIndex).toEqual(0);
    expect(prevRound).toRotate({
        pool: pool.address,
        address: validators.mainValidatorAddress,
        vsetHash: newSetHash,
        prevCount: 0,
        time: curTime,
    });
    expect(prevRound).toRotate({
        pool: pool.address,
        address: testValidator,
        vsetHash: newSetHash,
        prevCount: 0,
        time: curTime,
    });

    elections = announceElections(elector);

    assertPoolNewStake(testValidatorTwo, pool, elector, elections, testStake);

    val prevSetHash = newSetHash;
    newSetHash = updateVsetHash();

    curTime += 60 * 15;
    testing.setNow(curTime);

    // Main validator updated individually
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    curTime += 60 * 15;
    testing.setNow(curTime);

    res = pool.sendUpdateVset(notOwner.address, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    expect(res).toHaveSuccessfulTx<UpdateVset>({ from: notOwner.address, to: pool.address });
    poolAfter = pool.getPoolData();
    validatorsAfter = poolAfter.validators.load();
    mainAfter = validators.mainValidatorData.load();
    val curRound = validatorsAfter.curRound.load();
    prevRound = validatorsAfter.prevRound.load();

    expect(curRound).toRotate({
        address: testValidatorTwo,
        pool: pool.address,
        vsetHash: newSetHash,
        prevCount: 0,
        time: curTime,
    });

    expect(prevRound).toRotate({
        pool: pool.address,
        vsetHash: newSetHash,
        address: validator,
        prevCount: 1,
        time: curTime - 15 * 60, // Should have outstanding rotation time
    });
    expect(prevRound).toRotate({
        pool: pool.address,
        vsetHash: newSetHash,
        address: testValidator,
        prevCount: 1,
        time: curTime, // Rotated with testValidatorTwo
    });

    // Should not change, because round is closed
    expect(validatorsAfter.vsetHash).toEqual(prevSetHash >> 128);
}

get fun `test anybody could rotate vset with main validator only`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, _owner, notOwner, validator, _nominators) = setupPoolWithNominators(40);

    val testStake = stakes.minStake * 2;
    var elections = announceElections(elector);

    assertPoolNewStake(validator, pool, elector, elections, testStake);
    var newSetHash = updateVsetHash();

    val res = pool.sendUpdateVset(notOwner.address, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    val curTime = testing.getNow();
    expect(res).toHaveSuccessfulTx<UpdateVset>({ from: notOwner.address, to: pool.address });
    val poolAfter = pool.getPoolData();
    var validatorsAfter = lazy poolAfter.validators.load();
    val prevRound = validatorsAfter.prevRound.load();
    expect(validatorsAfter.vsetHash).toEqual(newSetHash >> 128);
    expect(prevRound.roundIndex).toEqual(0);
    expect(prevRound).toRotate({
        pool: pool.address,
        address: validatorsAfter.mainValidatorAddress,
        vsetHash: newSetHash,
        prevCount: 0,
        time: curTime,
    });
}

get fun `test vset can't rotate twice`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, owner, notOwner, validator, _nominators) = setupPoolWithNominators(40);

    val testStake = stakes.minStake * 2;
    val testValidator = setupRandomValidator(pool, owner.address);
    val elections = announceElections(elector);

    assertPoolNewStake(validator, pool, elector, elections, testStake);
    assertPoolNewStake(testValidator, pool, elector, elections, testStake);

    val newSetHash = updateVsetHash();

    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    var poolAfter = pool.getPoolData();
    var validatorsAfter = poolAfter.validators.load();
    var prevRound = validatorsAfter.prevRound.load();
    val _mainAfter = pool.getValidatorInfo(validator);
    expect(validatorsAfter.vsetHash).toEqual(newSetHash >> 128);

    expect(prevRound).toRotate({
        pool: pool.address,
        address: validator,
        prevCount: 0,
        vsetHash: newSetHash,
    });

    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    var validatorsBefore = validatorsAfter;

    poolAfter = pool.getPoolData();
    validatorsAfter = poolAfter.validators.load();
    expect(validatorsAfter.vsetHash).toEqual(validatorsBefore.vsetHash);
    expect(validatorsAfter.curRound).toEqual(validatorsBefore.curRound);
    expect(validatorsAfter.prevRound).toEqual(validatorsBefore.prevRound);

    pool.sendUpdateVset(notOwner.address, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    poolAfter = pool.getPoolData();
    validatorsAfter = poolAfter.validators.load();
    prevRound = validatorsAfter.prevRound.load();
    expect(validatorsAfter.curRound).toEqual(validatorsBefore.curRound);
    expect(prevRound).toRotate({
        pool: pool.address,
        address: testValidator,
        vsetHash: newSetHash,
        prevCount: 0,
    });

    validatorsBefore = validatorsAfter;
    pool.sendUpdateVset(notOwner.address, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    poolAfter = pool.getPoolData();
    validatorsAfter = poolAfter.validators.load();
    expect(validatorsAfter.vsetHash).toEqual(validatorsBefore.vsetHash);
    expect(validatorsAfter.curRound).toEqual(validatorsBefore.curRound);
    expect(validatorsAfter.prevRound).toEqual(validatorsBefore.prevRound);
}

get fun `test new stake error should not bleed pool balance`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val elections = announceElections(elector);
    val balanceBefore = testing.getAccountBalance(pool.address);
    repeat (10) {
        val res = pool.sendNewStake(
            validator,
            DEFAULT_QUERY_ID,
            stakes.minStake * 2,
            getSignedBody(elections - 1),
            { value: ton("1") },
        );
        expect(res).toHaveSuccessfulTx<NewStakeError>();
    }
    val balanceAfter = testing.getAccountBalance(pool.address);
    expect(balanceAfter).toBeGreaterOrEqual(balanceBefore);
    // println(balanceAfter - balanceBefore);
}

get fun `test new stake should refund on values above 1 ton`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val elections = announceElections(elector);

    val balanceBefore = testing.getAccountBalance(pool.address);
    val stake = stakes.minStake * 2;
    val res = pool.sendNewStake(
        validator,
        DEFAULT_QUERY_ID,
        stake,
        getSignedBody(elections),
        { value: ton("1000") },
    );

    expect(res).toHaveSuccessfulTx<NewStakeOk>({ to: pool.address });
    expect(res).toHaveRefund<NewStake>({ from: pool.address, to: validator });
    val balanceAfter = testing.getAccountBalance(pool.address);
    // 2 ton because 1 ton is frozen on a balance, and 1 ton returned with NewStakeOk
    expect((balanceBefore - balanceAfter) as int).toBeApproxEqAbs(stake, ton("2"));
}

get fun `test recover stake should only be triggerable for validators with usage records`() {
    val (_elector, _stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val stateBefore = getAccountData(pool.address);
    val res = pool.sendRecoverStakeCompat(validator, DEFAULT_QUERY_ID, { value: ton("1") });
    expect(
        res,
    ).toHaveRefund<RecoverStakeCompat>({ from: pool.address, to: validator, error: ErrorsPool.UsageRecordNotFound, previousState: stateBefore });
}

get fun `test should not be able to recover till unfreeze time`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    val testValidator = setupRandomValidator(pool, owner.address);
    var elections = announceElections(elector);

    assertPoolNewStake(testValidator, pool, elector, elections, stakes.minStake * 2);
    var res = pool.sendRecoverStakeCompat(testValidator, DEFAULT_QUERY_ID, { value: ton("100") });

    // To early just hopped on elections
    var curUsage = pool.getValidatorInfo(testValidator);
    // println(curUsage);
    // println(res);
    expect(curUsage.usage.curRoundUsage!.usage.rotation.rotationCount).toEqual(0);
    expect(
        res,
    ).toHaveRefund<RecoverStakeCompat>({ from: pool.address, to: testValidator, error: ErrorsPool.RoundTooEarly });
    // println("After first recovery");
    runElections(elector, stakes, limits);
    // println("Got past first elections");
    // To early, only next vset
    pool.sendUpdateVset(testValidator, DEFAULT_QUERY_ID, { value: ton("1") });
    curUsage = pool.getValidatorInfo(testValidator);
    expect(curUsage.usage.prevRoundUsage!.usage.rotation.rotationCount).toEqual(1);

    // println("Second recovery");
    res = pool.sendRecoverStakeCompat(testValidator, DEFAULT_QUERY_ID, { value: ton("100") });
    expect(
        res,
    ).toHaveRefund<RecoverStakeCompat>({ from: pool.address, to: testValidator, error: ErrorsPool.RoundTooEarly });

    elections = announceElections(elector);
    runElections(elector, stakes, limits);
    pool.sendUpdateVset(testValidator, DEFAULT_QUERY_ID, { value: ton("1") });
    // println("Passed second elections");
    curUsage = pool.getValidatorInfo(testValidator);
    expect(curUsage.usage.prevRoundUsage!.usage.rotation.rotationCount).toEqual(2);

    // println("Third recovery");
    res = pool.sendRecoverStakeCompat(testValidator, DEFAULT_QUERY_ID, { value: ton("100") });
    // Right round, but no unfreeze yet
    expect(
        res,
    ).toHaveRefund<RecoverStakeCompat>({ from: pool.address, to: testValidator, error: ErrorsPool.RecoveryTimeTooEarly });

    curUsage = pool.getValidatorInfo(testValidator);
    testing.setNow(
        curUsage.usage.prevRoundUsage!.usage.rotation.rotationTime +
        curUsage.usage.prevRoundUsage!.usage.heldFor +
        61,
    );
    testing.runTickTock(elector.address, true);
    testing.runTickTock(elector.address, false);

    res = pool.sendRecoverStakeCompat(testValidator, DEFAULT_QUERY_ID, { value: ton("100") });
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });
    val proxyTx = res.findTransaction<RecoverStakeCompat>({ from: pool.address });

    val recoveryBody = proxyTx!.loadBody<RecoverStakeCompat>();
    // -1 because requred threshold is sent, not the real time
    expect(recoveryBody.queryId).toEqual(testing.getNow() - 1);
}

get fun `test recovery timing should be irrelevant if rotation count is above 2`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val testStake = stakes.minStake * 2;
    // One rotation here
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
    expect(
        pool.getValidatorInfo(validator).usage.prevRoundUsage!.usage.rotation.rotationCount,
    ).toEqual(1);

    updateVsetHash();
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    testing.runTickTock(elector.address, false);
    testing.runTickTock(elector.address, true);

    waitTillRecovery(pool, validator, elector.address);

    // Now the third vset rotates, time is irrelevant
    testing.setNow(testing.getNow() + 600);
    updateVsetHash();
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    val dataAfter = pool.getValidatorInfo(validator);
    val usage = dataAfter.usage.prevRoundUsage!;
    // Make condition stays unsattisfied.
    expect(testing.getNow()).toBeLess(usage.usage.rotation.rotationTime + usage.usage.heldFor + 60);
    expect(dataAfter.usage.prevRoundUsage!.usage.rotation.rotationCount).toEqual(3);

    val res = pool.sendRecoverStakeCompat(
        validator,
        DEFAULT_QUERY_ID,
        { value: DEFAULT_MSG_VALUE },
    );
    val recoveOkTx = res.findTransaction<RecoverStakeOk>({ to: pool.address });
    expect(recoveOkTx).toBeNotNull();

    // Make sure it is not excess return
    expect(getInternalMessageValue(recoveOkTx!.loadInMsg<RecoverStakeOk>().info).grams).toBeGreater(
        testStake,
    );
    val proxyTx = res.findTransaction<RecoverStakeCompat>({ from: pool.address });
    expect(proxyTx).toBeNotNull();

    val recoveryBody = proxyTx!.loadBody<RecoverStakeCompat>();
    // In case above 2 rounds, 0 is sent
    expect(recoveryBody.queryId).toEqual(0);
}

get fun `test recovery timing should be irrelevant if rotation count is above 2 for unrestricted path`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val testStake = stakes.minStake * 2;
    // One rotation here
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
    expect(
        pool.getValidatorInfo(validator).usage.prevRoundUsage!.usage.rotation.rotationCount,
    ).toEqual(1);

    updateVsetHash();
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });
    testing.runTickTock(elector.address, false);
    testing.runTickTock(elector.address, true);

    waitTillRecovery(pool, validator, elector.address);

    // Now the third vset rotates, time is irrelevant
    testing.setNow(testing.getNow() + 600);
    updateVsetHash();
    pool.sendUpdateVset(validator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    val dataAfter = pool.getValidatorInfo(validator);
    val usage = dataAfter.usage.prevRoundUsage!;
    // Make condition stays unsattisfied.
    expect(testing.getNow()).toBeLess(usage.usage.rotation.rotationTime + usage.usage.heldFor + 60);
    expect(dataAfter.usage.prevRoundUsage!.usage.rotation.rotationCount).toEqual(3);

    val res = pool.sendRecoverStakeUnrestricted(
        notOwner.address,
        DEFAULT_QUERY_ID,
        validator,
        ton("1"),
        { value: ton("1") * 2 },
    );
    val recoveOkTx = res.findTransaction<RecoverStakeOk>({ to: pool.address });
    expect(recoveOkTx).toBeNotNull();

    // Make sure it is not excess return
    expect(getInternalMessageValue(recoveOkTx!.loadInMsg<RecoverStakeOk>().info).grams).toBeGreater(
        testStake,
    );

    val proxyTx = res.findTransaction<RecoverStakeCompat>({ from: pool.address });
    expect(proxyTx).toBeNotNull();

    val recoveryBody = proxyTx!.loadBody<RecoverStakeCompat>();
    // In case above 2 rounds, 0 is sent
    expect(recoveryBody.queryId).toEqual(0);
}

get fun `test anybody should be able to recover on behalf of the validator at unfreeze time and later`() {
    // Idea here is that if validator itself can't send recovery, for example as a result of hardware issues
    // Anyone should be able to do it on behalf of validator in order for the pool to keep functioning
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, notOwner, validator, _nominators) = setupPoolWithNominators(20);

    val testValue = ton("0.5") + random.range(5) * ton("0.1");

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
    );

    var res = pool.sendRecoverStakeUnrestricted(
        notOwner.address,
        DEFAULT_QUERY_ID,
        validator,
        testValue,
        { value: testValue * 2 },
    );
    expect(
        res,
    ).toHaveRefund<RecoverStakeUnrestricted>({ from: pool.address, to: notOwner.address, error: ErrorsPool.RoundTooEarly });

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        true,
    );
    res = pool.sendRecoverStakeUnrestricted(
        notOwner.address,
        DEFAULT_QUERY_ID,
        validator,
        testValue,
        { value: testValue * 2 },
    );
    expect(
        res,
    ).toHaveRefund<RecoverStakeUnrestricted>({ from: pool.address, to: notOwner.address, error: ErrorsPool.RecoveryTimeTooEarly });

    waitTillRecovery(pool, validator, elector.address);
    testing.runTickTock(elector.address, true);
    testing.runTickTock(elector.address, false);

    res = pool.sendRecoverStakeUnrestricted(
        notOwner.address,
        DEFAULT_QUERY_ID,
        validator,
        testValue,
        { value: testValue * 2 },
    );

    val validatorInfo = pool.getValidatorInfo(validator);
    val expectedProxy = validatorInfo.validator.evenProxy!;

    val refundTx = res.findTransaction({
        from: pool.address,
        to: address.fromWorkchainAndHash(
            MASTERCHAIN,
            expectedProxy,
        ),
        aborted: false,
    });

    expect(refundTx).toBeNotNull();
    expect(
        getInternalMessageValue(refundTx!.loadInMsg<RecoverStakeCompat>().info).grams as int,
    ).toBeApproxEqAbs(testValue, ton("0.1"));
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({
        from: address.fromWorkchainAndHash(
            MASTERCHAIN,
            expectedProxy,
        ),
        to: pool.address,
    });
}

get fun `test recoverStake should refund above 1 TON`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, notOwner, validator, _nominators) = setupPoolWithNominators(20);

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

    waitTillRecovery(pool, validator, elector.address);

    val res = pool.sendRecoverStakeCompat(validator, DEFAULT_QUERY_ID, { value: ton("1.2") });
    expect(res).toHaveRefund<RecoverStakeCompat>({ from: pool.address, to: validator, error: 0 });
    val refundTx = res.findTransaction<RefundMessage>({ to: validator, from: pool.address });
    expect(refundTx).toBeNotNull()!;

    expect(
        getInternalMessageValue(refundTx!.loadInMsg<RefundMessage>().info).grams,
    ).toBeLessOrEqual(ton("0.2"));
}

get fun `test RecoverStakeUnrestricted shoud not be able to inflate RecoverStakeOk value`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, notOwner, validator, _nominators) = setupPoolWithNominators(20);

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

    waitTillRecovery(pool, validator, elector.address);

    val valData = pool.getValidatorInfo(validator);
    val expProxyHash = valData.validator.evenProxy!;
    val proxyAddr = address.fromWorkchainAndHash(MASTERCHAIN, expProxyHash);
    val expectedStake = elector.computeReturnedStake(expProxyHash);
    val res = pool.sendRecoverStakeUnrestricted(
        notOwner.address,
        DEFAULT_QUERY_ID,
        validator,
        ton("100"),
        { value: ton("200") },
    );
    val recoverOut = res.findTransaction<RecoverStakeCompat>({ from: pool.address, to: proxyAddr });
    expect(recoverOut).toBeNotNull();
    expect(
        getInternalMessageValue(recoverOut!.loadInMsg<RecoverStakeCompat>().info).grams,
    ).toBeLessOrEqual(ton("1"));
    val recoverTx = res.findTransaction<RecoverStakeOk>({ to: pool.address, from: proxyAddr });
    expect(recoverTx).toBeNotNull();
    expect(
        getInternalMessageValue(recoverTx!.loadInMsg<RecoverStakeOk>().info).grams,
    ).toBeLessOrEqual(expectedStake + ton("1"));
}

get fun `test should unfreeze frozen proxy by recoverStake`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, notOwner, validator, _nominators) = setupPoolWithNominators(20);

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

    val validatorInfo = pool.getValidatorInfo(validator);
    val expectedProxy = validatorInfo.validator.evenProxy!;

    val proxyAcctHash = StateInit {
        fixedPrefixLength: null,
        special: null,
        library: null,
        code: build("Proxy"),
        data: ProxyStorage {
            pool: pool.address,
            validator,
            roundParity: false,
        }.toCell(),
    }.toCell()
        .hash();

    val frozenProxy = TlbAccountStateFrozen { stateHash: proxyAcctHash };
    val expectedProxyAddress = address.fromWorkchainAndHash(MASTERCHAIN, expectedProxy);

    testing.setShardAccount(
        expectedProxyAddress,
        TlbShardAccount {
            account: (TlbAccountInfo {
                addr: expectedProxyAddress,
                storage: TlbAccountStorage {
                    lastTransLt: 0,
                    balance: TlbCurrencyCollection {
                        grams: ton("1"),
                        other: [],
                    },
                    state: frozenProxy,
                },
                storageStat: TlbStorageInfo {
                    used: TlbStorageUsed {
                        cells: 10,
                        bits: 1024,
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

    waitTillRecovery(pool, validator, elector.address);
    testing.runTickTock(elector.address, true);
    testing.runTickTock(elector.address, false);

    val res = pool.sendRecoverStakeUnrestricted(
        notOwner.address,
        DEFAULT_QUERY_ID,
        validator,
        ton("9"),
        { value: ton("10") },
    );

    val recoverTx = res.findTransaction({ from: pool.address, to: expectedProxyAddress });
    expect(recoverTx).toNotEqual(null);
    expect(res).toHaveSuccessfulTx<RecoverStakeCompat>({ from: pool.address });
    expect(res).toHaveSuccessfulTx({ from: elector.address, to: expectedProxyAddress });
}

get fun `test new stake should bounce from the frozen proxy`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(20);

    val proxyAcctHash = StateInit {
        fixedPrefixLength: null,
        special: null,
        library: null,
        code: build("Proxy"),
        data: ProxyStorage {
            pool: pool.address,
            validator,
            roundParity: false,
        }.toCell(),
    }.toCell()
        .hash();

    val frozenProxy = TlbAccountStateFrozen { stateHash: proxyAcctHash };

    val expectedProxy = getProxy(pool.address, validator, false).address;

    testing.setShardAccount(
        expectedProxy,
        TlbShardAccount {
            account: (TlbAccountInfo {
                addr: expectedProxy,
                storage: TlbAccountStorage {
                    lastTransLt: 0,
                    balance: TlbCurrencyCollection {
                        grams: ton("1"),
                        other: [],
                    },
                    state: frozenProxy,
                },
                storageStat: TlbStorageInfo {
                    used: TlbStorageUsed {
                        cells: 10,
                        bits: 1024,
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

    val stateBefore = pool.getValidatorInfo(validator);
    val elections = announceElections(elector);
    val poolBefore = pool.getPoolData();
    val validatorsBefore = poolBefore.validators.load();
    val curRoundBefore = validatorsBefore.curRound.load();

    val testStake = stakes.minStake * 2;
    val res = pool.sendNewStake(
        validator,
        DEFAULT_QUERY_ID,
        testStake,
        getSignedBody(elections),
        { value: DEFAULT_MSG_VALUE },
    );

    expect(res).toHaveSuccessfulTx({ from: expectedProxy, to: pool.address, bounced: true });

    val stateAfter = pool.getValidatorInfo(validator);

    expect(stateAfter.validator.usageState).toEqual(stateBefore.validator.usageState);
    expect(stateAfter.usage.curRoundUsage).toEqual(null);

    val poolAfter = pool.getPoolData();
    val validators = poolAfter.validators.load();

    val curRound = validators.curRound.load();

    expect(curRound.used).toEqual(curRoundBefore.used);
    expect(curRound.used).toEqual(curRoundBefore.returned);
}

get fun `test RecoverStakeOk should not be accepted from arbitrary address`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val attacker = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());

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

    var res = pool.sendRecoverStakeOk(
        attacker,
        DEFAULT_QUERY_ID,
        ProxyResponseData {
            validator,
            parity: false, // Round 0 is even
        }.toCell()
            .beginParse(),
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        from: attacker,
        exitCode: ErrorsPool.NotFromProxy,
    });

    res = pool.sendRecoverStakeOk(
        attacker,
        DEFAULT_QUERY_ID,
        ProxyResponseData {
            validator,
            parity: true, // Round 1 is odd
        }.toCell()
            .beginParse(),
    );

    expect(res).toHaveFailedTx({
        to: pool.address,
        from: attacker,
        exitCode: ErrorsPool.NotFromProxy,
    });

    val valInfo = pool.getValidatorInfo(validator);

    var proxyHashes = [valInfo.validator.evenProxy!, valInfo.validator.oddProxy!];
    var tryCount = 2;
    repeat (tryCount) {
        val curHash = proxyHashes.pop();
        val proxyBc = address.fromWorkchainAndHash(BASECHAIN, curHash);
        res = pool.sendRecoverStakeOk(
            proxyBc,
            DEFAULT_QUERY_ID,
            ProxyResponseData {
                validator,
                parity: tryCount % 2 > 0,
            }.toCell()
                .beginParse(),
        );
        tryCount -= 1;

        expect(res).toHaveFailedTx({
            to: pool.address,
            from: proxyBc,
            exitCode: ErrorsPool.NotFromProxy,
        });
    }
}

@test.skip
get fun `test that validator wallet is not burning balance while operating due to refund`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    val testValidator = testing.treasury("testValidator");
    val balanceBefore = testing.getAccountBalance(testValidator.address);
    expect(balanceBefore).toBeGreater(0);

    pool.sendAddValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        testValidator.address,
        RoundAllowance.InAllRounds,
        null,
        { value: ton("10000") },
    );

    runRound(
        pool,
        elector,
        stakes,
        limits,
        testValidator.address,
        0,
        false,
    );
    runRound(
        pool,
        elector,
        stakes,
        limits,
        testValidator.address,
        0,
        true,
    );

    val res = waitAndRecoverStake(pool, testValidator.address, elector.address);

    val balanceBeforeRecovery = testing.getAccountBalance(testValidator.address);
    println(balanceBeforeRecovery, balanceBefore);
    expect(
        res,
    ).toHaveSuccessfulTx<StakeReturned>({ from: pool.address, to: testValidator.address });

    val balanceAfter = testing.getAccountBalance(testValidator.address);
    expect(balanceAfter).toBeGreaterOrEqual(balanceBefore);

    println(balanceBefore - balanceAfter);
}

get fun `test new stake error should not be accepted from arbitrary address`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, _owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val attacker = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());

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

    var tryCount = 2;
    val stateBefore = getAccountData(pool.address);
    val balanceBefore = testing.getAccountBalance(pool.address);
    repeat (tryCount) {
        pool.sendNewStakeError(
            attacker,
            DEFAULT_QUERY_ID,
            0,
            ProxyResponseData {
                validator,
                parity: tryCount % 2 > 0,
            }.toCell()
                .beginParse(),
        );
        expect(getAccountData(pool.address).hash()).toEqual(stateBefore.hash());
        tryCount -= 1;
    }
    tryCount = 2;

    val valInfo = pool.getValidatorInfo(validator);

    repeat (tryCount) {
        var testAddress: address;
        if (tryCount % 2 > 0) {
            testAddress = address.fromWorkchainAndHash(BASECHAIN, valInfo.validator.oddProxy!);
        } else {
            testAddress = address.fromWorkchainAndHash(BASECHAIN, valInfo.validator.evenProxy!);
        }
        pool.sendNewStakeError(
            testAddress,
            DEFAULT_QUERY_ID,
            0,
            ProxyResponseData {
                validator,
                parity: tryCount % 2 > 0,
            }.toCell()
                .beginParse(),
        );
        expect(getAccountData(pool.address).hash()).toEqual(stateBefore.hash());
        tryCount -= 1;
    }
    expect(testing.getAccountBalance(pool.address)).toBeGreaterOrEqual(balanceBefore);
}

get fun `test new stake error from elector should be handled appropriately`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators();

    val elections = announceElections(elector);
    expect(elections).toBeGreater(0);
    val testValidator = setupRandomValidator(pool, owner.address);

    // Now the main validator
    assertPoolNewStake(validator, pool, elector, elections, stakes.minStake * 2);

    val poolBefore = pool.getPoolData();
    val usageBefore = pool.getValidatorInfo(testValidator);
    val validatorsBefore = poolBefore.validators.load();
    // Now the currentRound is as full as it will ever be
    // And the random validator sending stake to the wrong elections,
    // triggering NewStakeError
    val res = pool.sendNewStake(
        testValidator,
        DEFAULT_QUERY_ID,
        stakes.minStake * 2,
        getSignedBody(elections - 1),
        { value: ton("1") },
    );
    res.giveName("NewStakeError");

    val refundTx = res.findTransaction<RefundMessage>({ from: pool.address });
    if (refundTx != null) {
        // println(refundTx.loadBody<RefundMessage>());
    }

    expect(res).toHaveSuccessfulTx<NewStakeError>({ to: pool.address });

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    val roundBefore = validatorsBefore.curRound.load();
    val roundAfter = validatorsAfter.curRound.load();
    expect(roundBefore.returned).toBeLess(roundBefore.used);
    expect(roundBefore.used).toEqual(roundAfter.used);
    expect(roundAfter.users.exists(testValidator.getWorkchainAndHash().1)).toBeFalse();
    // No losses on the books, it is absorbed by the validator refund amount
    expect(roundAfter.returned).toEqual(roundBefore.returned);
    // When stake is taken activeSlots increment
    // On NewStakeError it should decrement
    expect(validatorsAfter.activeSlots).toEqual(validatorsBefore.activeSlots);
    expect(validatorsAfter.stakeUsed).toEqual(validatorsBefore.stakeUsed);

    val usageAfter = pool.getValidatorInfo(testValidator);
    expect(usageBefore.validator.usageState).toEqual(usageAfter.validator.usageState);
}

get fun `test new stake error from elector should be handled appropriately (FULL POOL)`() {
    val (elector, stakes, _limits) = setupElector();
    val (
        pool,
        _owner,
        _notOwner,
        validator,
        randomValidator,
        _nominators,
    ) = setupFullyBookedPool();

    val elections = announceElections(elector);
    expect(elections).toBeGreater(0);
    val poolInitial = pool.getPoolData();

    val validatorsInitial = poolInitial.validators.load();
    var lookup = validatorsInitial.validators.findFirst();
    // Let's make a fully staked 32 slots
    while (lookup.isFound) {
        val valAddress = lookup.getKey();
        if (valAddress != randomValidator) {
            val _valData = lookup.loadValue();
            assertPoolNewStake(valAddress, pool, elector, elections, stakes.minStake * 2);
        }
        lookup = validatorsInitial.validators.iterateNext(lookup);
    }

    // Now the main validator
    assertPoolNewStake(validator, pool, elector, elections, stakes.minStake * 2);

    val poolBefore = pool.getPoolData();
    val usageBefore = pool.getValidatorInfo(randomValidator);
    val validatorsBefore = poolBefore.validators.load();
    // Now the currentRound is as full as it will ever be
    // And the random validator sending stake to the wrong elections,
    // triggering NewStakeError
    val res = pool.sendNewStake(
        randomValidator,
        DEFAULT_QUERY_ID,
        stakes.minStake * 2,
        getSignedBody(elections - 1),
        { value: ton("1") },
    );
    res.giveName("NewStakeError");

    val refundTx = res.findTransaction<RefundMessage>({ from: pool.address });
    if (refundTx != null) {
        // println(refundTx.loadBody<RefundMessage>());
    }

    expect(res).toHaveSuccessfulTx<NewStakeError>({ to: pool.address });

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    expect(validatorsBefore).toEqual(validatorsAfter);
    val roundBefore = validatorsBefore.curRound.load();
    val roundAfter = validatorsAfter.curRound.load();
    expect(roundAfter).toEqual(roundBefore);
    expect(roundBefore.returned).toEqual(roundAfter.returned);
    expect(roundBefore.used).toEqual(roundAfter.used);
    expect(roundAfter.users.exists(randomValidator.getWorkchainAndHash().1)).toBeFalse();
    // No losses on the books, it is absorbed by the validator refund amount
    // When stake is taken activeSlots increment
    // On NewStakeError it should decrement
    expect(validatorsAfter.activeSlots).toEqual(validatorsBefore.activeSlots);
    expect(validatorsAfter.stakeUsed).toEqual(validatorsBefore.stakeUsed);

    val usageAfter = pool.getValidatorInfo(randomValidator);
    expect(usageBefore.validator.usageState).toEqual(usageAfter.validator.usageState);
}
