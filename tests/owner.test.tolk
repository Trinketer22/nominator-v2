import "@stdlib/lisp-lists"
import "@acton/fmt"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/testing/fuzz"
import "@acton/types/transaction"
import "@contracts/config"
import "@contracts/errors"

import "@contracts/fees"
import "@contracts/messages"
import "@contracts/types"
import "@contracts/utils"
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

get fun `test owner should be able to add only MAX_VALIDATORS`() {
    val (pool, owner, _notOwner, _validator, _nominators) = setupPoolWithNominators(10);

    val maxPunishment = pool.getMaxPunishment(0);
    val minValue = (maxPunishment + PROXY_MIN_STORAGE) * 2 + ton("1");

    val queryId = random.range(128);
    var i = 0;
    repeat (MAX_VALIDATORS - 1) {
        val testValidator = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());
        val allowance = RoundAllowance.InAllRounds;
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
        val expectedProxyCount = 2;
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

    val poolBefore = getAccountData(pool.address);
    val balanceBefore = testing.getAccountBalance(pool.address);
    val extraValidator = address.fromWorkchainAndHash(MASTERCHAIN, random.uint256());
    val res = pool.sendAddValidator(
        owner.address,
        queryId,
        extraValidator,
        RoundAllowance.InAllRounds,
        null,
        { value: minValue },
    );
    expect(res).toHaveRefund<AddValidator>({
        from: pool.address,
        to: owner.address,
        previousState: poolBefore,
        initialBalance: balanceBefore,
        error: ErrorsPool.TooManyValidators,
    });
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

    val validatorsBefore = pool.getPoolData().validators.load();
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
    expect(valdatorsUpd.activeValidators).toEqual(validatorsBefore.activeValidators - 1);
}

get fun `test only owner should be able to remove validator`() {
    val (pool, owner, notOwner, _validator, _nominators) = setupPoolWithNominators(10);

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
    expect(pool.getPoolData().validators.load().activeValidators).toEqual(2);

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
    expect(validatorsAfter.activeValidators).toEqual(1);
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

get fun `test should not be able to add validator address twice`() {
    val (pool, owner, _notOwner, validator, _nominators) = setupPoolWithNominators(1);

    val previousState = getAccountData(pool.address);
    val res = pool.sendAddValidator(
        owner.address,
        DEFAULT_QUERY_ID,
        validator,
        RoundAllowance.InAllRounds,
        null,
        { value: ton("1000") },
    );

    expect(res).toHaveRefund<AddValidator>({
        from: pool.address,
        to: owner.address,
        error: ErrorsPool.ValidatorAlreadyExits,
        previousState,
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
    val (minTonPerValidator, maxTonPerValidator, _refundBonus) = pool.getLimitsPerValidator();

    val networkLimits = StakingLimits.fromCell(testing.getConfig().getParamRaw(STAKES_IDX));
    val newMax = min(
        maxTonPerValidator + (random.range(100) + 1) * ton("1000"),
        networkLimits.maxStake,
    );
    val newMin = max(
        minTonPerValidator - (random.range(100) + 1) * ton("100"),
        networkLimits.minStake,
    );
    val newRefundBonus = (random.range(7) + 1) * ton("1");

    val _res = pool.sendUpdateLimits(
        owner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: newMin,
            maxTonPerValidator: newMax,
            refundBonus: newRefundBonus,
        },
    );

    val (updMin, updMax, updRefundBonus) = pool.getLimitsPerValidator();
    expect(updMin).toEqual(newMin);
    expect(updMax).toEqual(newMax);
    expect(updRefundBonus).toEqual(newRefundBonus);

    val poolAfter = pool.getPoolData();
    val valAfter = poolAfter.validators.load();
    expect(valAfter.maxTonPerValidator).toEqual(newMax);
    expect(valAfter.minTonPerValidator).toEqual(newMin);
    expect(valAfter.refundBonus).toEqual(newRefundBonus);
}

get fun `test owner global validator limits should be checked against max > min`() {
    val (pool, owner, _notOwner, _validator) = setupDeployedPool();

    val _poolData = pool.getPoolData();
    val (minTonPerValidator, maxTonPerValidator, _) = pool.getLimitsPerValidator();

    val networkLimits = StakingLimits.fromCell(testing.getConfig().getParamRaw(STAKES_IDX));
    val newMax = max(
        maxTonPerValidator + (random.range(100) + 1) * ton("1000"),
        networkLimits.maxStake,
    );
    val newMin = min(
        minTonPerValidator - (random.range(100) + 1) * ton("100"),
        networkLimits.minStake,
    );
    val newBonus = (random.range(7) + 1) * ton("1");

    val balanceBefore = testing.getAccountBalance(pool.address);
    val stateBefore = getAccountData(pool.address);
    val res = pool.sendUpdateLimits(
        owner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: newMax,
            maxTonPerValidator: newMin,
            refundBonus: newBonus,
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

get fun `test owner global validator limits should be checked against network min/max`() {
    val (pool, owner, _notOwner, _validator) = setupDeployedPool();
    val balanceBefore = testing.getAccountBalance(pool.address);
    val stateBefore = getAccountData(pool.address);
    val (initialMin, initialMax, refundBonus) = pool.getLimitsPerValidator();

    val networkLimits = StakingLimits.fromCell(testing.getConfig().getParamRaw(STAKES_IDX));

    var res = pool.sendUpdateLimits(
        owner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: networkLimits.minStake - 1,
            maxTonPerValidator: initialMax,
            refundBonus: refundBonus,
        },
    );
    expect(res).toHaveRefund<UpdateLimits>({
        to: owner.address,
        from: pool.address,
        initialBalance: balanceBefore,
        previousState: stateBefore,
        error: ErrorsPool.MinStakeBelowNetworkLimit,
    });
    res = pool.sendUpdateLimits(
        owner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: initialMin,
            maxTonPerValidator: networkLimits.maxStake + 1,
            refundBonus: refundBonus,
        },
    );
    expect(res).toHaveRefund<UpdateLimits>({
        to: owner.address,
        from: pool.address,
        initialBalance: balanceBefore,
        previousState: stateBefore,
        error: ErrorsPool.MaxStakeAboveNetworkLimit,
    });
    res = pool.sendUpdateLimits(
        owner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: networkLimits.minStake,
            maxTonPerValidator: networkLimits.maxStake,
            refundBonus: refundBonus,
        },
    );

    val (minAfter, maxAfter, _) = pool.getLimitsPerValidator();
    expect(minAfter).toEqual(networkLimits.minStake);
    expect(maxAfter).toEqual(networkLimits.maxStake);
}

get fun `test only owner should be able to update global per validator parameters`() {
    val (pool, _owner, notOwner, _validator) = setupDeployedPool();

    val _poolData = pool.getPoolData();
    val (minTonPerValidator, maxTonPerValidator, _) = pool.getLimitsPerValidator();

    val newMax = maxTonPerValidator + (random.range(100) + 1) * ton("1000");
    val newMin = minTonPerValidator - (random.range(100) + 1) * ton("100");

    val stateBefore = getAccountData(pool.address);
    val res = pool.sendUpdateLimits(
        notOwner.address,
        DEFAULT_QUERY_ID,
        GlobalValidatorsLimit {
            minTonPerValidator: newMin,
            maxTonPerValidator: newMax,
            refundBonus: ton("1") as uint33,
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
        expect(validatorUpd.limit).toNotEqual(null);
        if (validatorUpd.limit is ValidatorLimitTon) {
            expect(validatorUpd.limit).toEqual(tonLimit);
        } else {
            Assert.fail(format("Expected ton limit got {}", validatorUpd.limit));
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

        if (validatorUpd.limit is ValidatorLimitShare) {
            expect(validatorUpd.limit).toEqual(shareLimit);
        } else {
            Assert.fail(format("Expected share limit got {}", validatorUpd.limit));
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

@test.fuzz(1)
get fun `test owner should be able to update nominators whitelist`(testNm: address) {
    var (_share, _validatorsSettings, nominatorsSettings) = defaultDeployParams();
    val (_elector, stakes, _limits) = setupElector();
    var whitelistNms: map<address, bool> = [];
    repeat (5) {
        val newAddr = address.fromWorkchainAndHash(BASECHAIN, random.uint256());
        whitelistNms.set(newAddr, true);
    }

    nominatorsSettings.whitelist = whitelistNms;
    val (pool, owner, _notOwner, _validator) = setupDeployedPool({
        nominatorsSettings,
    });

    val stateBefore = getAccountData(pool.address);
    val balanceBefore = testing.getAccountBalance(pool.address);
    val testAmount = stakes.minStake * 5;
    val depoReject = pool.sendTextComment(testNm, "d".beginParse(), { value: testAmount });

    expect(depoReject).toHaveRefund<TextComment>({
        to: testNm,
        from: pool.address,
        previousState: stateBefore,
        initialBalance: balanceBefore,
        error: ErrorsPool.DepositNotAllowed,
    });
    // Now owner updates the whitelist
    whitelistNms.set(testNm, true);
    val updateWl = pool.sendUpdateNominatorsWhitelist(
        owner.address,
        DEFAULT_QUERY_ID,
        whitelistNms,
    );
    expect(updateWl).toHaveRefund<UpdateNominatorsWhitelist>({
        from: pool.address,
        to: owner.address,
        initialBalance: balanceBefore,
    });
    assertPoolDepositInstant(pool, testNm, testAmount);
}

get fun `test owner should be able to evict nominator`() {
    // Let's say the pool was initially deployed without a whitelist
    val (pool, owner, _notOwner, _validator) = setupDeployedPool();
    val evilNm = testing.treasury("3v111");

    val evilDepo = (random.range(20) + 2) * ton("1000");

    assertPoolDepositInstant(pool, evilNm.address, evilDepo);

    val inValue = ton("1000");
    val res = pool.sendEvictNominator(
        owner.address,
        DEFAULT_QUERY_ID,
        evilNm.address,
        { value: inValue },
    );
    expect(res).toNotHaveTx<WithdrawSuccess>({ to: evilNm.address });
    val evictTx = res.findTransaction<EvictNominator>({ to: pool.address, aborted: false });
    expect(evictTx).toBeNotNull();

    val refundTx = res.findTransaction<RefundMessage>({ from: pool.address, to: owner.address });
    expect(refundTx).toBeNotNull();

    // Should refund most of the value to the owner
    val refundValue = getInternalMessageInfo(refundTx!.loadInMsg<RefundMessage>().info).value.grams;
    expect(refundValue as int).toBeApproxEqAbs(
        inValue - PAYOUT_ITEM_BALANCE - getTxComputePh(evictTx!).gasFees,
        ton("0.01"),
    );

    var nominatorsAfter = pool.getPoolData().nominators.load().poolNominators;
    val nmAfter = nominatorsAfter.mustGet(evilNm.address);

    expect(nmAfter.share).toEqual(0);
    // Since no profit accrued shares/ton is 1/1
    expect(nmAfter.pendingWithdrawal).toEqual(evilDepo - DEPOSIT_GAS);

    updateVsetHash();

    val updRes = pool.sendUpdateVset(owner.address, DEFAULT_QUERY_ID, { value: DEFAULT_MSG_VALUE });

    val withdrawTx = updRes.findTransaction<WithdrawSuccess>({ from: pool.address, to: evilNm.address });
    expect(withdrawTx).toBeNotNull();
    val withdrawMsg = withdrawTx!.loadInMsg<WithdrawSuccess>();
    expect(getInternalMessageValue(withdrawMsg.info).grams as int).toBeApproxEqAbs(
        evilDepo - DEPOSIT_GAS,
        ton("0.05"), // Item balance(0.04) + 0.01 - fees
    );

    nominatorsAfter = pool.getPoolData().nominators.load().poolNominators;

    expect(nominatorsAfter.exists(evilNm.address)).toBeFalse();
}

get fun `test owner should not be able to evict a non-existent nominator`() {
    val (pool, owner, _notOwner, _validator) = setupDeployedPool();
    val randomNm = testing.treasury("Never deposited");

    val balanceBefore = testing.getAccountBalance(pool.address);
    val stateBefore = getAccountData(pool.address);

    val res = pool.sendEvictNominator(
        owner.address,
        DEFAULT_QUERY_ID,
        randomNm.address,
        { value: DEFAULT_MSG_VALUE },
    );

    expect(res).toNotHaveTx({ to: randomNm.address });
    expect(
        res,
    ).toHaveRefund<EvictNominator>({
        to: owner.address,
        from: pool.address,
        error: ErrorsPool.DepositNotFound,
        initialBalance: balanceBefore,
        previousState: stateBefore,
    });
}

get fun `test owner should not be able to evict nominator which already has pending payout`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, owner, _notOwner, validator) = setupDeployedPool();

    val legitNm = testing.treasury("Legit");
    val legitDepo = ton("200000");

    assertPoolDepositInstant(pool, legitNm.address, legitDepo);

    val expValue = legitDepo - DEPOSIT_GAS;
    val elections = announceElections(elector);

    assertPoolNewStake(validator, pool, elector, elections, expValue);
    assertDelayedOperation(pool, legitNm.address, true);

    val balanceBefore = testing.getAccountBalance(pool.address);
    val stateBefore = getAccountData(pool.address);

    val res = pool.sendEvictNominator(
        owner.address,
        DEFAULT_QUERY_ID,
        legitNm.address,
        { value: DEFAULT_MSG_VALUE },
    );

    expect(
        res,
    ).toHaveRefund<EvictNominator>({ to: owner.address, from: pool.address, error: ErrorsPool.WithdrawalAlreadyRequested, initialBalance: balanceBefore, previousState: stateBefore });
}

get fun `test eviction operation may rotate the round`() {
    val (pool, owner, _notOwner, validator) = setupDeployedPool();

    val legitNm = testing.treasury("Legit");
    val legitDepo = ton("200000");

    assertPoolDepositInstant(pool, legitNm.address, legitDepo);
    val newVset = updateVsetHash() >> 128;
    val poolBefore = pool.getPoolData();
    expect(poolBefore.roundIndex).toEqual(0);
    expect(poolBefore.validators.load().vsetHash).toNotEqual(newVset);

    val res = pool.sendEvictNominator(
        owner.address,
        DEFAULT_QUERY_ID,
        legitNm.address,
        { value: DEFAULT_MSG_VALUE },
    );

    val poolAfter = pool.getPoolData();
    expect(poolAfter.roundIndex).toEqual(1);
    expect(poolAfter.validators.load().vsetHash).toEqual(newVset);

    val payoutInit = res.findTransaction<PayoutInitMessage>({ from: pool.address });
    expect(payoutInit).toBeNotNull();

    val payoutMsg = payoutInit!.loadBody<PayoutInitMessage>();

    expect(payoutMsg.roundIndex).toEqual(1);
    expect(payoutMsg.owner).toEqual(legitNm.address);
}

get fun `test eviction operation bare round rotation effects such as halted`() {
    val (elector, stakes, _limits) = setupElector();
    val (pool, owner, _notOwner, validator) = setupDeployedPool();

    val legitNm = testing.treasury("Legit");
    val smallNm = testing.treasury("Little one");
    val legitDepo = ton("200000");
    val littleDepo = ton("20000");

    assertPoolDepositInstant(pool, legitNm.address, legitDepo);
    assertPoolDepositInstant(pool, smallNm.address, littleDepo);

    val largeDepo = legitDepo - DEPOSIT_GAS;
    val smallDepo = littleDepo - DEPOSIT_GAS;
    val elections = announceElections(elector);

    assertPoolNewStake(validator, pool, elector, elections, largeDepo);
    // Since the stake is taken after rotation pool should get halted
    assertDelayedOperation(pool, legitNm.address, true);

    val newVset = updateVsetHash() >> 128;
    val poolBefore = pool.getPoolData();
    val validatorsBefore = poolBefore.validators.load();

    val res = pool.sendEvictNominator(
        owner.address,
        DEFAULT_QUERY_ID,
        smallNm.address,
        { value: DEFAULT_MSG_VALUE },
    );

    val payoutInit = res.findTransaction<PayoutInitMessage>({ from: pool.address });
    expect(payoutInit).toBeNotNull();

    val payoutMsg = payoutInit!.loadBody<PayoutInitMessage>();

    // Should end up in older queue, since it is not destroyed yet
    expect(payoutMsg.roundIndex).toEqual(0);
    expect(payoutMsg.owner).toEqual(smallNm.address);

    val poolAfter = pool.getPoolData();
    val validatorsAfter = poolAfter.validators.load();
    expect(poolAfter.roundIndex).toEqual(1);
    expect(poolAfter.halted).toBeTrue();
    expect(validatorsAfter.vsetHash).toEqual(newVset);
    expect(validatorsAfter.curRound.load().users.isEmpty()).toBeTrue();
    expect(validatorsAfter.prevRound).toEqual(validatorsBefore.curRound);
    expect(poolAfter.pendingWithdrawals).toEqual(poolBefore.pendingWithdrawals + smallDepo);
}

get fun `test only owner should be able to evict nominators`() {
    val (pool, _owner, notOwner, _validator) = setupDeployedPool();
    val legitNm = testing.treasury("Legit cat");

    val legitDepo = (random.range(20) + 2) * ton("1000");

    assertPoolDepositInstant(pool, legitNm.address, legitDepo);

    val balanceBefore = testing.getAccountBalance(pool.address);
    val stateBefore = getAccountData(pool.address);

    val res = pool.sendEvictNominator(
        notOwner.address,
        DEFAULT_QUERY_ID,
        legitNm.address,
        { value: ton("1000") },
    );
    expect(res).toNotHaveTx({ to: legitNm.address });
    expect(
        res,
    ).toHaveRefund<EvictNominator>({ to: notOwner.address, from: pool.address, error: ErrorsPool.NotOwner, initialBalance: balanceBefore, previousState: stateBefore });
}

get fun `test only owner should be able to update nominators whitelist`() {
    val (pool, _owner, _notOwner, _validator) = setupDeployedPool();
    val stateBefore = getAccountData(pool.address);
    val balanceBefore = testing.getAccountBalance(pool.address);

    val attacker = testing.treasury("attacker");
    var newWl: map<address, bool> = [];
    newWl.set(attacker.address, true);

    val updateWl = pool.sendUpdateNominatorsWhitelist(
        attacker.address,
        DEFAULT_QUERY_ID,
        newWl,
    );

    expect(updateWl).toHaveRefund<UpdateNominatorsWhitelist>({
        from: pool.address,
        to: attacker.address,
        previousState: stateBefore,
        initialBalance: balanceBefore,
        error: ErrorsPool.NotOwner,
    });
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
    val (_elector, _stakes, _limits) = setupElector();
    val (pool, _owner, notOwner, _validator, _nominators) = setupPoolWithNominators(20);

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

get fun `test owner should not be able to withdraw liquidity reserved for pending payouts`() {
    val (elector, stakes, limits) = setupElector();

    val (pool, owner, _notOwner, validator) = setupDeployedPool();
    val fatNm = testing.treasury("FatCat");

    val ownerFunds = stakes.minStake * 2;
    // Owner's cushion. It lets the second stake exceed the nominator funds,
    // so the owner equity ends up locked in the elector, while the recovered
    // nominator stake arrives as a liquid balance
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
    assertDelayedOperation(pool, fatNm.address, true);

    waitTillRecovery(pool, validator, elector.address);

    val validatorStatus = pool.getValidatorInfo(validator);
    val expectedProxyHash = validatorStatus.usage.prevRoundUsage!.proxy;
    val expectedProxy = address.fromWorkchainAndHash(MASTERCHAIN, expectedProxyHash);

    val proxyParity = false;

    // Recovering the stake kickstarts the payout chain
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

    // Owner tries to withdraw right in between the chain start and the burn notification.
    // Pending payouts are carved out of the liquid balance, so this attempt has to fail
    val stateBefore = getAccountData(pool.address);
    val balanceBefore = testing.getAccountBalance(pool.address);

    val ownerLiquid = pool.getSharesInfo().liquidOwnerShare;
    expect(ownerLiquid).toBeLess(ownerFunds);
    expect(getMaxOwnerShare(pool)).toEqual(ownerLiquid);

    val ownerIter = testing.createTraceIterationCursor(
        owner.address,
        createMessage<OwnerWithdrawal>({
            bounce: true,
            dest: pool.address,
            body: OwnerWithdrawal {
                queryId: DEFAULT_QUERY_ID,
                amount: ownerFunds,
            },
            value: ton("1"),
        }),
    );

    val ownerRes = ownerIter.executeAllRemaining();
    expect(ownerRes).toHaveRefund<OwnerWithdrawal>({
        from: pool.address,
        to: owner.address,
        initialBalance: balanceBefore,
        previousState: stateBefore,
        error: ErrorsPool.NotEnoughPoolBalance,
    });
    expect(ownerRes).toNotHaveTx<OwnerWithdrawalSuccess>({
        from: pool.address,
        to: owner.address,
    });

    // Burn notification arrives, and the payout settles, since the liquid balance is intact
    val recoverRes = recoverIter.executeAllRemaining();

    expect(recoverRes).toHaveSuccessfulTx<WithdrawSuccess>({
        from: pool.address,
        to: fatNm.address,
    });

    val poolAfterPayout = pool.getPoolData();
    expect(poolAfterPayout.pendingWithdrawals).toEqual(0);
    expect(poolAfterPayout.halted).toBeFalse();
    expect(poolAfterPayout.nominators.load().nmCount).toEqual(0);

    assertPoolInvariants(pool);

    // Owner's cushion is still locked in the elector, recover it next
    val statusAfterPayout = pool.getValidatorInfo(validator);
    val cushionProxyHash = statusAfterPayout.usage.prevRoundUsage!.proxy;
    // Two consecutive stakes always rotate between the even and the odd proxy
    val cushionParity = cushionProxyHash != expectedProxyHash;

    val cushionRes = net.send(
        address.fromWorkchainAndHash(MASTERCHAIN, cushionProxyHash),
        createMessage<RecoverStakeOk>({
            bounce: false,
            dest: pool.address,
            body: RecoverStakeOk {
                queryId: DEFAULT_QUERY_ID,
                remaining: ProxyResponseData {
                    validator,
                    parity: cushionParity,
                }.toCell()
                    .beginParse(),
            },
            value: ownerFunds,
        }),
    );
    expect(cushionRes).toHaveSuccessfulTx<RecoverStakeOk>({ to: pool.address });

    // With no pending payouts left, the owner can withdraw the same amount again
    val res = pool.sendOwnerWithdrawal(
        owner.address,
        DEFAULT_QUERY_ID,
        ownerFunds,
        { value: ton("1") },
    );

    expect(res).toHaveTx<OwnerWithdrawalSuccess>({
        from: pool.address,
        to: owner.address,
    });

    assertPoolInvariants(pool);
}
