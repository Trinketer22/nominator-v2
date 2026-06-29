import "@stdlib/lisp-lists"
import "@acton/fmt"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/testing/fuzz"
import "@acton/types/transaction"
import "@contracts/errors"

import "@contracts/fees"
import "@contracts/messages"
import "@contracts/types"
import "@contracts/validators"
import "@tests/deploy-utils"
import "@tests/elector-utils"
import "@tests/matchers"
import "@tests/pool-utils"
import "@tests/test-utils"
import "@wrappers/ElectorCode.gen"
import "@wrappers/Pool.gen"

get fun `test owner should be able to add more validators`() {
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    val maxPunishment = pool.getMaxPunishment(0);
    val minValue = (maxPunishment + PROXY_MIN_STORAGE) * 2 + ton("1");
    val allowanceTypes = [
        RoundAllowance.InAllRounds,
        RoundAllowance.InEvenRounds,
        RoundAllowance.InOddRounds,
    ];

    val queryId = random.range(128);
    var i = 0;
    repeat (3) {
        val testValidator = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());
        val allowance = allowanceTypes.get(i);
        val balanceBefore = testing.getAccountBalance(pool.address);
        val res = pool.sendAddValidator(
            owner.address,
            queryId,
            testValidator,
            allowance,
            null,
            { value: minValue },
        );
        val addTx = res.findTransaction<AddValidator>(
            {
                to: pool.address,
                from: owner.address,
            },
        );
        expect(addTx != null).toBeTrue();
        val expectedProxyCount = allowance == RoundAllowance.InAllRounds ? 2 : 1;
        val balanceAfter = testing.getAccountBalance(pool.address);
        // For each proxy count there should be a slashing reserve
        // Delta for storage fee
        expect(balanceAfter as int).toBeApproxEqAbs(
            balanceBefore + maxPunishment * expectedProxyCount,
            3,
        );
        // Up to two proxy deploys and refund
        expect(getTxActionPh(addTx!).msgsCreated).toEqual(expectedProxyCount + 1);
        val resInfo = pool.getValidatorInfo(testValidator);
        val validatorInfo = resInfo.validator;

        expect(validatorInfo.usageState).toEqual(0);
        i += 1;

        val allowanceMask = allowance as int;
        if ((allowanceMask & 1) > 0) {
            expect(validatorInfo.oddProxy != null).toBeTrue();
        } else {
            expect(validatorInfo.oddProxy == null).toBeTrue();
        }
        if ((allowanceMask & 2) > 0) {
            expect(validatorInfo.evenProxy != null).toBeTrue();
        } else {
            expect(validatorInfo.evenProxy == null).toBeTrue();
        }

        expect(validatorInfo.roundParity == allowance);
    }
}

get fun `test only owner should be able to add validator`() {
    val (pool, _owner, notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    val maxPunishment = pool.getMaxPunishment(0);
    val minValue = maxPunishment + PROXY_MIN_STORAGE * 2 + ton("1");
    val allowanceTypes = [
        RoundAllowance.InAllRounds,
        RoundAllowance.InEvenRounds,
        RoundAllowance.InOddRounds,
    ];

    val i = 0;
    repeat (3) {
        val queryId = random.range(128);
        val testValidator = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());
        val allowance = allowanceTypes.get(i);
        val balanceBefore = testing.getAccountBalance(pool.address);
        val res = pool.sendAddValidator(
            notOwner.address,
            queryId,
            testValidator,
            allowance,
            null,
            { value: minValue },
        );

        expect(res).toHaveRefund<AddValidator>({
            from: pool.address,
            to: notOwner.address,
            initialBalance: balanceBefore,
            error: ErrorsPool.NotOwner,
        });
    }
}

get fun `test owner should be able to remove validator`() {
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    val testValidator = setupRandomValidator(pool, owner.address);

    val balanceBefore = testing.getAccountBalance(pool.address);
    val res = pool.sendRemoveValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        testValidator,
        { value: ton("10000") },
    );

    expect(
        res,
    ).toHaveRefund<RemoveValidator>({ from: pool.address, to: owner.address, initialBalance: balanceBefore });

    val poolAfter = pool.getPoolData();
    val valdatorsUpd = lazy poolAfter.validators.load();

    expect(valdatorsUpd.validators.exists(testValidator)).toBeFalse();
}

get fun `test owner should not be able to remove main validator`() {
    val (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val balanceBefore = testing.getAccountBalance(pool.address);
    val stateBefore = getAccountData(pool.address);
    val res = pool.sendRemoveValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        validator,
        { value: ton("10000") },
    );

    expect(res).toHaveRefund<RemoveValidator>({
        from: pool.address,
        to: owner.address,
        initialBalance: balanceBefore,
        previousState: stateBefore,
        error: ErrorsPool.MainValidatorCantBeRemoved,
    });
}

get fun `test only owner should be able to remove validator`() {
    val (pool, owner, notOwner, validator, _nominators) = setupPoolWithNominators(10);

    val testValidator = setupRandomValidator(pool, owner.address);
    val balanceBefore = testing.getAccountBalance(pool.address);
    val stateBefore = getAccountData(pool.address);
    val res = pool.sendRemoveValidator(
        notOwner.address,
        DEFAULT_QUERY_ID,
        testValidator,
        { value: ton("10000") },
    );

    expect(res).toHaveRefund<RemoveValidator>({
        from: pool.address,
        to: notOwner.address,
        initialBalance: balanceBefore,
        previousState: stateBefore,
        error: ErrorsPool.NotOwner,
    });
}

get fun `test if validator has stake, it will get banned, instead of being removed immediately`() {
    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    var elections = announceElections(elector);
    val testValidator = setupRandomValidator(pool, owner.address);

    runRound(pool, elector, stakes, limits, testValidator);
    var res = pool.sendRemoveValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        testValidator,
        { value: ton("10000") },
    );

    val balanceBefore = testing.getAccountBalance(pool.address);
    expect(res).toHaveRefund<RemoveValidator>({
        from: pool.address,
        to: owner.address,
        initialBalance: balanceBefore,
        error: 0,
    });
    val testStake = stakes.minStake * 2;

    val validatorAfter = pool.getValidatorInfo(testValidator);
    expect(validatorAfter.validator.isBanned).toBeTrue();

    // And when banned validator comes for the next stake(if allowed), it won't get it.

    elections = announceElections(elector);
    assertNewStakeFailed(
        ErrorsPool.ValidatorNotFound,
        testValidator,
        pool,
        elector.address,
        elections,
        testStake,
    );

    runElections(elector, stakes, limits);
    pool.sendUpdateVset(testValidator, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    res = waitAndRecoverStake(pool, testValidator, elector.address);
    expect(res).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    elections = announceElections(elector);
    res = pool.sendNewStake(
        testValidator,
        DEFAULT_QUERY_ID,
        testStake,
        getSignedBody(elections),
        { value: ton("1") },
    );
    expect(
        res,
    ).toHaveRefund<NewStake>({ from: pool.address, to: testValidator, error: ErrorsPool.ValidatorNotFound });

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();

    expect(validatorsAfter.validators.exists(testValidator)).toBeFalse();
}

get fun `test should not allow to add validator with validator pool share above SHARE_BASE`() {
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(20);

    val testValidator = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());

    val prevState = getAccountData(pool.address);
    var res = pool.sendAddValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        testValidator,
        RoundAllowance.InAllRounds,
        ValidatorLimitShare { maxShare: SHARE_BASE + 1 },
        { value: ton("10000") },
    );

    expect(res).toHaveRefund<AddValidator>({
        to: owner.address,
        from: pool.address,
        error: ErrorsPool.InvalidValidatorShare,
        previousState: prevState,
    });

    res = pool.sendAddValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        testValidator,
        RoundAllowance.InAllRounds,
        ValidatorLimitShare { maxShare: SHARE_BASE },
        { value: ton("10000") },
    );

    pool.getValidatorInfo(testValidator);
}

get fun `test should not allow to add validator with ton limit above maxTonPerValidator or below minTonPerValidator`() {
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(20);

    val (_ownerShare, validatorsSettings, _nominatorsSettings) = defaultDeployParams();

    val testValidator = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());

    val prevState = getAccountData(pool.address);
    var res = pool.sendAddValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        testValidator,
        RoundAllowance.InAllRounds,
        ValidatorLimitTon { maxTon: validatorsSettings.maxTonPerValidator + 1 },
        { value: ton("10000") },
    );

    expect(res).toHaveRefund<AddValidator>({
        to: owner.address,
        from: pool.address,
        error: ErrorsPool.IndividualLimitIsAboveGlobal,
        previousState: prevState,
    });

    res = pool.sendAddValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        testValidator,
        RoundAllowance.InAllRounds,
        ValidatorLimitTon { maxTon: validatorsSettings.minTonPerValidator - 1 },
        { value: ton("10000") },
    );

    expect(res).toHaveRefund<AddValidator>({
        to: owner.address,
        from: pool.address,
        error: ErrorsPool.IndividualLimitIsBelowGlobal,
        previousState: prevState,
    });
}

get fun `test should not be able to add same validator twice`() {
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(20);

    val newValidator = setupRandomValidator(pool, owner.address);

    val prevState = getAccountData(pool.address);
    val res = pool.sendAddValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        newValidator,
        RoundAllowance.InAllRounds,
        null,
        { value: ton("1000") },
    );

    expect(res).toHaveRefund<AddValidator>({
        from: pool.address,
        to: owner.address,
        error: ErrorsPool.ValidatorAlreadyExits,
        previousState: prevState,
    });
}

get fun `test should not be able to influence usage stats, by adding validator twice`() {
    // Amplified previous test

    val (elector, stakes, limits) = setupElector();
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(20);

    val newValidator = setupRandomValidator(pool, owner.address);

    runRound(pool, elector, stakes, limits, newValidator);

    val validatorRec = pool.getValidatorInfo(newValidator);
    expect(validatorRec.usage.prevRoundUsage != null).toBeTrue();
    val prevState = getAccountData(pool.address);
    val res = pool.sendAddValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        newValidator,
        RoundAllowance.InAllRounds,
        null,
        { value: ton("1000") },
    );

    expect(res).toHaveRefund<AddValidator>({
        from: pool.address,
        to: owner.address,
        error: ErrorsPool.ValidatorAlreadyExits,
        previousState: prevState,
    });
}

get fun `test owner should be able to update global per validator parameters`() {
    val (pool, owner, _notOwner, _validator) = setupDeployedPool();

    val _poolData = pool.getPoolData();
    val (minTonPerValidator, maxTonPerValidator, _maxRefundAmount) = pool.getLimitsPerValidator();

    val newMax = maxTonPerValidator + (random.range(100) + 1) * ton("1000");
    val newMin = minTonPerValidator - (random.range(100) + 1) * ton("100");
    val newRefund = ton("100");

    pool.sendUpdateLimits(
        owner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: newMin,
            maxTonPerValidator: newMax,
            maxRefund: newRefund,
        },
    );

    val (updMin, updMax, updRefund) = pool.getLimitsPerValidator();
    expect(updMin).toEqual(newMin);
    expect(updMax).toEqual(newMax);
    expect(updRefund).toEqual(newRefund);

    val poolAfter = pool.getPoolData();
    val valAfter = poolAfter.validators.load();
    expect(valAfter.maxTonPerValidator).toEqual(newMax);
    expect(valAfter.minTonPerValidator).toEqual(newMin);
    expect(valAfter.maxRefundAmount).toEqual(newRefund);
}

get fun `test owner global validator limits should be checked against max > min`() {
    val (pool, owner, _notOwner, _validator) = setupDeployedPool();

    val _poolData = pool.getPoolData();
    val (minTonPerValidator, maxTonPerValidator, _maxRefundAmount) = pool.getLimitsPerValidator();

    val newMax = maxTonPerValidator + (random.range(100) + 1) * ton("1000");
    val newMin = minTonPerValidator - (random.range(100) + 1) * ton("100");
    val newRefund = ton("100");

    val balanceBefore = testing.getAccountBalance(pool.address);
    val stateBefore = getAccountData(pool.address);
    val res = pool.sendUpdateLimits(
        owner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: newMax,
            maxTonPerValidator: newMin,
            maxRefund: newRefund,
        },
    );
    expect(res).toHaveRefund<UpdateLimits>({
        to: owner.address,
        from: pool.address,
        initialBalance: balanceBefore,
        previousState: stateBefore,
        error: ErrorsPool.InvalidMaxMin,
    });
}

get fun `test only owner should be able to update global per validator parameters`() {
    val (pool, _owner, notOwner, _validator) = setupDeployedPool();

    val _poolData = pool.getPoolData();
    val (minTonPerValidator, maxTonPerValidator, _maxRefundAmount) = pool.getLimitsPerValidator();

    val newMax = maxTonPerValidator + (random.range(100) + 1) * ton("1000");
    val newMin = minTonPerValidator - (random.range(100) + 1) * ton("100");
    val newRefund = ton("100");

    val stateBefore = getAccountData(pool.address);
    val res = pool.sendUpdateLimits(
        notOwner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: newMin,
            maxTonPerValidator: newMax,
            maxRefund: newRefund,
        },
    );

    expect(
        res,
    ).toHaveRefund<UpdateLimits>({ to: notOwner.address, from: pool.address, previousState: stateBefore, error: ErrorsPool.NotOwner });
}

@test.fuzz(3)
get fun `test owner should be able to update nominator parameters`(
    newMaxNm: uint10,
    newMinStake: coins,
) {
    val (pool, owner, _notOwner, _validator) = setupDeployedPool();

    val _res = pool.sendUpdateLimits(
        owner.address,
        DEFAULT_QUERY_ID,
        GlobalNominatorsLimit {
            maxNm: newMaxNm,
            minStake: newMinStake,
        },
    );

    val poolAfter = pool.getPoolData();
    val nmAfter = poolAfter.nominators.load();
    expect(poolAfter.maxNominators).toEqual(newMaxNm);
    expect(nmAfter.minStake).toEqual(newMinStake);
}

@test.fuzz(3)
get fun `test only owner should be able to update nominator parameters`(
    newMaxNm: uint10,
    newMinStake: coins,
) {
    val (pool, _owner, notOwner, _validator) = setupDeployedPool();

    val stateBefore = getAccountData(pool.address);
    val res = pool.sendUpdateLimits(
        notOwner.address,
        DEFAULT_QUERY_ID,
        GlobalNominatorsLimit {
            maxNm: newMaxNm,
            minStake: newMinStake,
        },
    );
    expect(
        res,
    ).toHaveRefund<UpdateLimits>({ from: pool.address, to: notOwner.address, error: ErrorsPool.NotOwner, previousState: stateBefore });
}

@test.fuzz(3)
get fun `test owner should be able to update per-validator limit`(maxTon: coins, maxShare: uint25) {
    val (pool, owner, _notOwner, validator) = setupDeployedPool();
    val poolBefore = pool.getPoolData();
    val validatorsBefore = poolBefore.validators.load();
    val boundShare = fuzz.bound(maxShare, 0, SHARE_BASE);
    val boundTon = fuzz.bound(
        maxTon,
        validatorsBefore.minTonPerValidator + 1,
        validatorsBefore.maxTonPerValidator / 2,
    );
    val additionalValidator = setupRandomValidator(pool, owner.address);

    val testValidators = [validator, additionalValidator];

    val tonLimit = ValidatorLimitTon { maxTon: boundTon };
    val shareLimit = ValidatorLimitShare { maxShare: boundShare };

    var i = 1;
    while (i >= 0) {
        val curValidator = testValidators.get(i);
        val curState = pool.getValidatorInfo(curValidator);
        expect(curState.validator.limit).toNotEqual(tonLimit);
        var _res = pool.sendUpdateLimits(
            owner.address,
            DEFAULT_QUERY_ID,
            ValidatorSpecific {
                validator: curValidator,
                limit: tonLimit,
            },
        );
        // println(res);
        /*
        val refundTx = res.findTransaction<RefundMessage>({from: pool.address});
        if(refundTx != null) {
            // println(refundTx.loadBody<RefundMessage>());
        }
        */
        var stateAfter = pool.getPoolData();
        var validatorsAfter = stateAfter.validators.load();
        var validatorUpd = validatorsAfter.getValidatorByAddress(curValidator, 42)!;
        expect(validatorUpd.data.limit).toNotEqual(null);
        if (validatorUpd.data.limit is ValidatorLimitTon) {
            expect(validatorUpd.data.limit).toEqual(tonLimit);
        } else {
            Assert.fail(format("Expected ton limit got {}", validatorUpd.data.limit));
        }
        /*
        match(stateAfter.validator.limit) {
            ValidatorLimitTon => {
                expect(stateAfter.validator.limit.maxTon).toEqual(tonLimit.maxTon);
            },
            ValidatorLimitShare => {Assert.fail(format("Excected ton limit got {}", stateAfter.validator.limit));},
            null => {
                Assert.fail(format("Excected ton limit got {}", stateAfter.validator.limit));
            }
        }
        */
        pool.sendUpdateLimits(
            owner.address,
            DEFAULT_QUERY_ID,
            ValidatorSpecific {
                validator: curValidator,
                limit: shareLimit,
            },
        );
        stateAfter = pool.getPoolData();
        validatorsAfter = stateAfter.validators.load();
        validatorUpd = validatorsAfter.getValidatorByAddress(curValidator, 42)!;

        if (validatorUpd.data.limit is ValidatorLimitShare) {
            expect(validatorUpd.data.limit).toEqual(shareLimit);
        } else {
            Assert.fail(format("Expected share limit got {}", validatorUpd.data.limit));
        }

        //stateAfter = pool.getValidatorInfo(curValidator);
        /*
        match(stateAfter.validator.limit) {
            ValidatorLimitTon => {Assert.fail(format("Excected ton limit got {}", stateAfter.validator.limit));},
            ValidatorLimitShare => {
                expect(stateAfter.validator.limit.maxShare).toEqual(shareLimit.maxShare);
            },
            null => {
                Assert.fail(format("Excected ton limit got {}", stateAfter.validator.limit));
            },
        }
        */
        i -= 1;
    }
}

@test.fuzz(256)
get fun `test owner should be able to withdraw it's share`(requestValue: coins, _inValue: coins) {
    val (elector, stakes, _limits) = setupElector();
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(20);

    val testValidator = setupRandomValidator(pool, owner.address);
    val elections = announceElections(elector);
    assertPoolNewStake(testValidator, pool, elector, elections, stakes.minStake * 2);
    val maxOwnerShare = getMaxOwnerShare(pool);

    val boundRequest = fuzz.bound(requestValue, DEFAULT_MSG_VALUE, maxOwnerShare * 100);
    val boundValue = fuzz.bound(requestValue, DEFAULT_MSG_VALUE, maxOwnerShare * 100);

    val balanceBefore = testing.getAccountBalance(pool.address);
    val res = pool.sendOwnerWithdrawal(
        owner.address,
        DEFAULT_QUERY_ID,
        boundRequest,
        { value: boundValue },
    );

    if (boundRequest > maxOwnerShare) {
        expect(
            res,
        ).toHaveRefund<OwnerWithdrawal>({ to: owner.address, from: pool.address, initialBalance: balanceBefore, error: ErrorsPool.NotEnoughPoolBalance });
    } else {
        expect(res).toHaveTx<OwnerWithdrawalSuccess>({ from: pool.address, to: owner.address });
        val withdrawTx = res.findTransaction<OwnerWithdrawal>({
            to: pool.address,
            from: owner.address,
        });
        expect(withdrawTx).toNotEqual(null);
        val txStorageFee = getTxStorage(withdrawTx!);
        val balanceAfter = testing.getAccountBalance(pool.address);
        expect(balanceAfter).toEqual(
            balanceBefore - txStorageFee.storageFeesCollected - boundRequest,
        );
    }
}

get fun `test only owner should be able to withdraw it's share`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, owner, notOwner, _validator, _nominators) = setupPoolWithNominators(20);

    val maxOwnerShare = getMaxOwnerShare(pool);

    val stateBefore = getAccountData(pool.address);
    val res = pool.sendOwnerWithdrawal(notOwner.address, DEFAULT_QUERY_ID, maxOwnerShare);

    expect(res).toHaveRefund<OwnerWithdrawal>({
        error: ErrorsPool.NotOwner,
        from: pool.address,
        previousState: stateBefore,
        to: notOwner.address,
    });
}

get fun `test owner share should decrease accordingly to withdrawn amount`() {
    val (elector, stakes, limits) = setupElector();
    var (pool, owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

    val testValidator = setupRandomValidator(pool, owner.address);

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
    );
    val elections = announceElections(elector);
    assertPoolNewStake(testValidator, pool, elector, elections, stakes.minStake * 2);
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        elections,
        true,
    );

    repeat (3) {
        val testNm = nominators.popHead();
        assertDelayedOperation(pool, testNm, false);
    }

    val maxOwnerShare = getMaxOwnerShare(pool);

    var shareLeft = maxOwnerShare;
    var maxShareChunk = shareLeft / 4;
    var iterCount = 0;

    while (maxShareChunk > ton("0.05")) {
        val curChunk = random.range(shareLeft / 4) + ton("0.05");
        val balanceBefore = testing.getAccountBalance(pool.address);
        // Testing edge value each time first
        var res = pool.sendOwnerWithdrawal(
            owner.address,
            DEFAULT_QUERY_ID,
            shareLeft + 1,
            { value: DEFAULT_MSG_VALUE },
        );

        expect(
            res,
        ).toHaveRefund<OwnerWithdrawal>({ to: owner.address, from: pool.address, initialBalance: balanceBefore, error: ErrorsPool.NotEnoughPoolBalance });

        res = pool.sendOwnerWithdrawal(
            owner.address,
            DEFAULT_QUERY_ID,
            curChunk,
            { value: DEFAULT_MSG_VALUE },
        );

        expect(res).toHaveTx<OwnerWithdrawalSuccess>({ from: pool.address, to: owner.address });
        val withdrawTx = res.findTransaction<OwnerWithdrawal>({
            to: pool.address,
            from: owner.address,
        });
        expect(withdrawTx).toNotEqual(null);
        val txStorageFee = getTxStorage(withdrawTx!);
        val balanceAfter = testing.getAccountBalance(pool.address);

        expect(balanceAfter).toEqual(balanceBefore - txStorageFee.storageFeesCollected - curChunk);

        shareLeft -= curChunk;

        maxShareChunk = shareLeft >> 2;
        iterCount += 1;
    }
    // println(format("Total {} iterations", iterCount));
}

@test.fuzz(64)
get fun `test owner should be able to withdraw it's share, and pending deposits should not be part of it`(
    requestValue: coins,
    _inValue: coins,
) {
    val (elector, stakes, limits) = setupElector();
    var (pool, owner, _notOwner, validator, nominators) = setupPoolWithNominators(40);

    val testValidator = setupRandomValidator(pool, owner.address);

    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        0,
        false,
    );
    val elections = announceElections(elector);
    assertPoolNewStake(testValidator, pool, elector, elections, stakes.minStake * 2);
    runRound(
        pool,
        elector,
        stakes,
        limits,
        validator,
        elections,
        true,
    );

    repeat (3) {
        val testNm = nominators.popHead();
        assertDelayedOperation(pool, testNm, false);
    }

    val maxOwnerShare = getMaxOwnerShare(pool);

    val boundRequest = fuzz.bound(requestValue, DEFAULT_MSG_VALUE, maxOwnerShare * 100);
    val boundValue = fuzz.bound(requestValue, DEFAULT_MSG_VALUE, maxOwnerShare * 100);

    val balanceBefore = testing.getAccountBalance(pool.address);
    val res = pool.sendOwnerWithdrawal(
        owner.address,
        DEFAULT_QUERY_ID,
        boundRequest,
        { value: boundValue },
    );

    if (boundRequest > maxOwnerShare) {
        expect(
            res,
        ).toHaveRefund<OwnerWithdrawal>({ to: owner.address, from: pool.address, initialBalance: balanceBefore, error: ErrorsPool.NotEnoughPoolBalance });
    } else {
        expect(res).toHaveTx<OwnerWithdrawalSuccess>({ from: pool.address, to: owner.address });
        val withdrawTx = res.findTransaction<OwnerWithdrawal>({
            to: pool.address,
            from: owner.address,
        });
        expect(withdrawTx).toNotEqual(null);
        val txStorageFee = getTxStorage(withdrawTx!);
        val balanceAfter = testing.getAccountBalance(pool.address);
        expect(balanceAfter).toEqual(
            balanceBefore - txStorageFee.storageFeesCollected - boundRequest,
        );
    }
}
