import "@stdlib/gas-payments"
import "@stdlib/reflection"
import "@contracts/fees"
import "@contracts/nominators"
import "@contracts/opcode"
import "@contracts/owner"
import "@contracts/storage"
import "@contracts/validators"
import "config"
import "errors"
import "messages"
import "types"
import "utils"

contract NominatorPool {
    author: "TON Core"
    version: "1.0.0"
    description: "Nominator pool contract"
    storage: Storage
    storageAtDeployment: PoolStorageNotInitialized
    incomingMessages: AllowedMessage
}

type BounceableMessages = NewStakeElector

type PostInit =
    | TextComment
    | UpdateVset
    | NewStake
    | NewStakeOk
    | NewStakeError
    | RecoverStake
    | RecoverStakeOk
    | RecoverStakeError
    | PayoutBurnNotification
    | AddFunds
    | OwnerMessages

type AllowedMessage =
    | PostInit
    | InitPoolMessage

get fun get_max_punishment(stake: int): int {
    val storage = Storage.load();
    val validators = lazy storage.validators.load();

    // We don't want to guess the minimum, so if specified is below minimum, minimum is checked
    stake = max(max(stake, 0), validators.minTonPerValidator);

    // If it is above pool max, it makes sense to throw
    assert(stake <= validators.maxTonPerValidator, ErrorsPool.StakeAboveTheLimit);

    return getMaxPunishmentInt(stake);
}

fun handleNewStakeError(sender: address, value: int) {
    var storage = lazy Storage.load();
    var validators = lazy storage.validators.load();
    val (workchain, addrHash) = sender.getWorkchainAndHash();
    assert(workchain == MASTERCHAIN, ErrorsPool.NotFromProxy);

    val stakeReturned = validators.getUsageRecord(
        addrHash,
        RoundAllowance.InAllRounds as int,
        null,
    );

    // If return didn't have an effect on state, we can simply ignore
    if (stakeReturned != null) {
        var round = stakeReturned.round;
        val delta = abs(stakeReturned.data.tonUsed - value);
        round.users.delete(addrHash);
        if (delta <= ton("1")) {
            // If delta is withing newStake reserve
            // make it look like it never happen
            round.used = max(round.used - stakeReturned.data.tonUsed, 0);
        } else {
            // Otherwise book it as real loss.
            // practically looks impossible
            round.returned += value;
        }

        if (stakeReturned.isCurrentRound) {
            validators.curRound = round.toCell();
        } else {
            validators.prevRound = round.toCell();
        }

        var valState = validators.getValidatorByAddress(stakeReturned.data.validator, null);
        // Should alway be true, but we don't want to throw here or mess the state
        if (valState != null) {
            valState.usageState &= ~parityToMask(round.roundIndex % 2 > 0);
            validators.updateValidatorByAddress(stakeReturned.data.validator, valState);
            validators.stakeUsed -= stakeReturned.data.tonUsed;
            validators.activeSlots -= 1;
        }
        storage.validators = validators.toCell();
        storage.save();
    }
}

fun onInternalMessage(in: InMessage) {
    var storage = PoolStorage.load();
    if (storage is PoolStorageNotInitialized) {
        val msg = InitPoolMessage.fromSlice(
            in.body,
            { throwIfOpcodeDoesNotMatch: ErrorsPool.PoolStorageNotInitialized },
        );
        assert(contract.getAddress().getWorkchain() == BASECHAIN, ErrorsPool.InvalidWorkchain);
        val nmSettings = msg.nominatorsSettings.load();
        assert(in.senderAddress == storage.owner, ErrorsPool.NotOwner);
        assert(msg.roundAllowance as int > 0, ErrorsPool.AtLeastOneRoundShouldBeAlowed);
        assert(msg.ownerShare <= SHARE_BASE, ErrorsPool.InvalidOwnerShare);
        var reserveAmount = POOL_MIN_STORAGE;
        val nRounds = max(msg.roundAllowance as int - 1, 1);

        if (nmSettings.maxNominators > 0) {
            reserveAmount += getMaxPunishmentInt(msg.minTonPerValidator) * nRounds;
        }

        assert(in.valueCoins >=
        reserveAmount + PROXY_MIN_STORAGE * nRounds + ton("1"), ErrorsPool.NotEnoughGas);

        reserveGramsOnBalance(
            reserveAmount,
            RESERVE_MODE_EXACT_AMOUNT | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
        );

        var mainValidator = Validator {
            usageState: 0,
            roundParity: msg.roundAllowance,
            limit: msg.limit,
        };

        mainValidator.deployProxy(
            msg.mainValidator,
            storage.owner,
            in.valueCoins - reserveAmount,
            msg.queryId,
        );

        val initPoolSuccess = createMessage({
            bounce: false,
            dest: storage.owner,
            value: 0,
            body: InitPoolSuccess { queryId: msg.queryId },
        });
        // SAFETY: RESERVE_MODE_EXACT_AMOUNT reserves exactly reserveAmount for contract storage.
        // CARRY_ALL_BALANCE sends the entire balance above this reserve (the surplus from the incoming value).
        initPoolSuccess.send(SEND_MODE_CARRY_ALL_BALANCE);

        var validatorsData = ValidatorsData {
            maxTonPerValidator: msg.maxTonPerValidator,
            minTonPerValidator: msg.minTonPerValidator,
            curRound: RoundData { roundIndex: 0 }.toCell(),
            prevRound: RoundData { roundIndex: 0 }.toCell(),
            vsetHash: getCurVset().vsetHash >> 128,
            refundBonus: msg.refundBonus,
        };
        validatorsData.validators.set(msg.mainValidator, mainValidator);
        assertStakingLimit(msg.minTonPerValidator, msg.maxTonPerValidator);
        val newStorage = Storage {
            owner: storage.owner,
            poolId: storage.poolId,
            ownerShare: msg.ownerShare,
            validators: validatorsData.toCell(),
            maxNominators: nmSettings.maxNominators,
            nominators: NominatorsData {
                minStake: nmSettings.minStake,
                minWithdrawableReward: nmSettings.minWithdrawableRewards,
                nominatorsWhitelist: nmSettings.whitelist,
            }.toCell(),
        };

        newStorage.save();
        return;
    }

    if (in.senderAddress == storage.owner) {
        val handled = processOwnerAction(in.body, storage, in.senderAddress, in.valueCoins);
        if (handled) {
            return;
        }
    }
    val msg = AllowedMessage.fromSlice(in.body, { throwIfOpcodeDoesNotMatch: 0xffff });

    match (msg) {
        InitPoolMessage => {
            throw ErrorsPool.AlreadyInitialized;
        }
        TextComment => {
            try {
                storage.handleTextComment(msg.comment, in.senderAddress, in.valueCoins);
            } catch (e) {
                refundError(
                    in.senderAddress,
                    {
                        queryId: 0,
                        op: 0,
                        errorCode: e,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                );
            }
        }
        UpdateVset => {
            var status: RotationStatus;
            var msgValue: int;
            var validators = storage.validators.load();
            val externalUpdate = in.senderAddress != contract.getAddress();
            if (externalUpdate) {
                status = validators.rotateRound(in.senderAddress, storage.roundIndex);
                msgValue = in.valueCoins;
            } else {
                // For self update case use quick variant with constant gas
                status = validators.rotateRoundQuick(storage.roundIndex);
                // This value will be excluded from the available balance during withdrawal processing
                msgValue = calculateGasFee(BASECHAIN, SELF_UPDATE_VSET_GAS);
            }

            storage.finalizeRound(status, msgValue);

            if (externalUpdate) {
                // Reserve pre-msg balance. Can't fail
                reserveGramsOnBalance(
                    0,
                    RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_AT_MOST,
                );
                refundError(
                    in.senderAddress,
                    {
                        op: opcode<UpdateVset>(),
                        errorCode: 0,
                        queryId: msg.queryId,
                    },
                    SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
                );
            }
            storage.validators = validators.toCell();

            storage.save();
        }
        OwnerWithdrawal => {
            refundError(
                in.senderAddress,
                {
                    op: opcode<OwnerWithdrawal>(),
                    queryId: msg.queryId,
                    errorCode: ErrorsPool.NotOwner,
                },
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
            );
        }
        AddValidator => {
            refundError(
                in.senderAddress,
                {
                    op: reflect.serializationPrefixOf<AddValidator>().0,
                    queryId: msg.queryId,
                    errorCode: ErrorsPool.NotOwner,
                },
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
            );
        }
        // Just accept funds
        AddFunds => {}
        UpdateLimits => {
            refundError(
                in.senderAddress,
                {
                    op: opcode<UpdateLimits>(),
                    queryId: msg.queryId,
                    errorCode: ErrorsPool.NotOwner,
                },
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
            );
        }
        UpdateNominatorsWhitelist => {
            refundError(
                in.senderAddress,
                {
                    op: opcode<UpdateNominatorsWhitelist>(),
                    queryId: msg.queryId,
                    errorCode: ErrorsPool.NotOwner,
                },
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
            );
        }
        RemoveValidator => {
            refundError(
                in.senderAddress,
                {
                    op: opcode<RemoveValidator>(),
                    errorCode: ErrorsPool.NotOwner,
                    queryId: msg.queryId,
                },
                SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
            );
        }
        NewStake => {
            try {
                assert(msg.queryId > 0, ErrorsPool.QueryIdRequired);

                assert(in.valueCoins >= ton("1"), ErrorsPool.NotEnoughValueForNewStake);

                var validators = lazy storage.validators.load();
                var valData = validators.getValidatorByAddress(
                    in.senderAddress,
                    ErrorsPool.ValidatorNotFound,
                )!;
                storage.finalizeRound(
                    validators.rotateRound(in.senderAddress, storage.roundIndex),
                    in.valueCoins,
                );
                // practically halted check position here doesn't masterchain
                // Can only halt if there were stakes in prev round
                // And if there were stakes, it will only rotate in RecoverStakeOk
                // Still, clearer to carry storage checks after the state update
                assert(!storage.halted, ErrorsPool.PoolIsHalted);

                val (
                    availableBalance,
                    totalBalance,
                    estPendingWithdrawals,
                ) = storage.getStakableBalance(in.valueCoins, validators.stakeUsed);
                assert(msg.value <= availableBalance, ErrorsPool.NotEnoughPoolBalance);
                val stakeAmountSent = msg.value - ton("1");

                assert(msg.value >= validators.minTonPerValidator, ErrorsPool.StakeBelowLimit);
                if (valData.isBanned) {
                    assert(valData.usageState == 0, ErrorsPool.ValidatorNotFound);
                    refundError(
                        in.senderAddress,
                        {
                            op: reflect.serializationPrefixOf<NewStake>().0,
                            errorCode: ErrorsPool.ValidatorNotFound,
                        },
                        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                    );
                    validators.validators.delete(in.senderAddress);
                    validators.activeValidators -= 1;
                    storage.validators = validators.toCell();
                    storage.save();
                    return;
                }

                // Validates the NewStake body
                val newStake = NewStakeBody.fromSlice(msg.signedBody);
                // stakeAt is uint32, so this assert is always true.
                // Its real purpose is to use newStake, preventing the compiler
                // from optimizing out the fromSlice call above.
                assert(newStake.stakeAt >= 0, ErrorsPool.InvalidMessage);

                // Validate stored parameters against network state every time
                assertStakingLimit(validators.minTonPerValidator, validators.maxTonPerValidator);
                val valLimit = valData.limit;
                val stakeMax = getValidatorLimit(
                    valLimit,
                    totalBalance,
                    validators.maxTonPerValidator,
                );

                assert(msg.value <= stakeMax, ErrorsPool.StakeAboveTheLimit);

                val curVset = getCurVset();
                // For multi nominator mode
                val electionsConf = getElectionsTiming();
                val roundIsOdd = (storage.roundIndex % 2) > 0;
                val roundIndex = parityToMask(roundIsOdd);
                // if(storage.maxNominators > 0) {
                // True single nominator mode TODO
                assert(!storage.roundClosed, ErrorsPool.RoundIsClosed);
                assert((valData.usageState & roundIndex) == 0, ErrorsPool.AlreadyStakedInThatRound);
                assert((valData.roundParity as int & roundIndex) != 0, ErrorsPool.RoundNotAllowed);
                // + pendingWithdrawals because pending withdrawals are already part of nominatorsAmount
                val ownerShare = totalBalance - storage.nominatorsAmount + estPendingWithdrawals;
                validators.stakeUsed += stakeAmountSent;
                validators.activeSlots += 1;
                assert(ownerShare >=
                getMaxPunishmentInt(validators.minTonPerValidator) *
                validators.activeSlots, ErrorsPool.OwnerShareIsUndercapitalized);
                val curTime = blockchain.now();
                assert(curTime >
                curVset.utimeUntil - electionsConf.startBefore, ErrorsPool.ElectionsNotStarted);
                assert(curTime <
                curVset.utimeUntil - electionsConf.endBefore, ErrorsPool.ElectionsAlreadyEnded);
                //}

                valData = {
                    usageState: valData.usageState | roundIndex,
                    roundParity: valData.roundParity,
                    oddProxy: valData.oddProxy,
                    evenProxy: valData.evenProxy,
                    limit: valLimit,
                };

                validators.updateValidatorByAddress(in.senderAddress, valData);

                var curRound = validators.curRound.load();
                curRound.used += stakeAmountSent;
                val proxyAddress = valData.getProxyAddressByParity(roundIndex);
                curRound
                    .users
                    .set(
                        proxyAddress.getHash(),
                        {
                            validator: in.senderAddress,
                            heldFor: electionsConf.stakeHeldFor,
                            tonUsed: stakeAmountSent,
                            rotation: {
                                vsetHash: curVset.vsetHash,
                                rotationTime: blockchain.now(),
                                rotationCount: 0,
                            },
                        },
                    );
                validators.curRound = curRound.toCell();
                storage.validators = validators.toCell();
                storage.save();

                val newStakeElector = createMessage({
                    bounce: true,
                    dest: proxyAddress,
                    value: msg.value,
                    body: NewStakeElector {
                        queryId: msg.queryId,
                        body: msg.signedBody,
                    },
                });
                newStakeElector.send(
                    SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
                );
                reserveGramsOnBalance(
                    msg.value - REFUND_THRESHOLD,
                    RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_NEGATE_AMOUNT |
                    RESERVE_MODE_AT_MOST,
                );
                refundError(
                    in.senderAddress,
                    {
                        op: opcode<NewStake>(),
                        queryId: msg.queryId,
                        errorCode: 0,
                    },
                    SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
                );
            } catch (e) {
                refundError(
                    in.senderAddress,
                    {
                        op: reflect.serializationPrefixOf<NewStake>().0,
                        queryId: msg.queryId,
                        errorCode: e,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
                );
            }
        }
        NewStakeOk => {
            val proxyResp = ProxyResponseData.fromSlice(
                msg.remaining,
                { assertEndAfterReading: false },
            );
            val proxyAddress = getProxyAddress(proxyResp.validator, proxyResp.parity);

            assert(in.senderAddress == proxyAddress, ErrorsPool.NotFromProxy);
        }
        NewStakeError => {
            handleNewStakeError(in.senderAddress, in.valueCoins);
        }
        RecoverStakeCompat => {
            storage.sendStakeRecovery(
                in.valueCoins,
                in.senderAddress,
                in.senderAddress,
                opcode<RecoverStakeCompat>(),
                msg.queryId,
            );
        }
        RecoverStakeUnrestricted => {
            val maxAmount = min(msg.amount, MAX_RECOVERY_VALUE);
            storage.sendStakeRecovery(
                in.valueCoins,
                in.senderAddress,
                msg.validator,
                opcode<RecoverStakeUnrestricted>(),
                msg.queryId,
            );
            val minFee = calculateGasFee(BASECHAIN, getGasConsumedAtTheMoment() * 2) +
            in.originalForwardFee +
            maxAmount;
            // It is not wrapped in try/catch, but i think it's okay
            assert(in.valueCoins >= minFee, ErrorsPool.NotEnoughGas);
        }
        RecoverStakeOk => {
            var validators = lazy storage.validators.load();

            // Since round map has proxy address as a key, we don't need state->address calculation
            var returned = max(
                in.valueCoins -
                calculateGasFee(
                    BASECHAIN,
                    RECOVER_STAKE_OK_GAS,
                ),
                0,
            );
            val proxyData = ProxyResponseData.fromSlice(msg.remaining);

            var validator = validators.getValidatorByAddress(proxyData.validator, null);

            // Instead of refund amount we deduct 2/3 of the bonus
            // Since bonus should include NewStake fee + RecoverStakeFee + actual bonus(external ops)
            // Fees for first two operations are roughly equal, and bonus part is always split.
            // For basic MTC operations bonus should not exceed 1 TON. Actual spent for mc validator ~0.6 TON per round
            // So this expression means NewStake is roughly on the house(owner), where rest is split.
            // In this case owner share growth rate is below the nominators by a margin of 0.25 TON per stake round.
            // Could have done it in one mulDiv, however won't be able to limit the exposure to a single REFUND_THRESHOLD
            val ownerPart = min(validators.refundBonus / 3, REFUND_THRESHOLD);
            val splitBonus = validators.refundBonus - ownerPart;
            val (stakeReturned, bonusEarned, roundDone) = validators.coverUsageByAddress(
                in.senderAddress,
                returned,
                splitBonus,
                (storage.roundIndex % 2 > 0) == proxyData.parity,
            );

            if (stakeReturned == null) {
                val expectedAdddress = getProxyAddress(proxyData.validator, proxyData.parity);
                // If it came from something else - bounce
                assert(expectedAdddress == in.senderAddress, ErrorsPool.NotFromProxy);
                // Otherwise should never happen, but if it did, there is nothing to do
                return;
            }

            var refundBonus = 0;
            if (bonusEarned) {
                refundBonus = validators.refundBonus;
                // For this one to be reachable, the returned > used
                // By the margin of bonus.

                returned -= splitBonus;
            }

            val profit = returned - stakeReturned.tonUsed;

            validators.stakeUsed = max(validators.stakeUsed - stakeReturned.tonUsed, 0);
            validators.activeSlots = max(validators.activeSlots - 1, 0);

            // This should practically always be true.
            if (validator != null) {
                // Should we refund in case of negative returns?
                val stakeReturnedMsg = createMessage({
                    bounce: false,
                    value: refundBonus,
                    dest: stakeReturned.validator,
                    body: StakeReturned {
                        queryId: msg.queryId,
                        used: stakeReturned.tonUsed,
                        returned,
                        validator: stakeReturned.validator,
                    },
                });
                stakeReturnedMsg.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS);

                // Who we owe are all forgiven
                validator.usageState &= ~parityToMask(proxyData.parity);
                // Preserve the unused even if validator fully exits the pool
                validators.updateValidatorByAddress(stakeReturned.validator, validator);

                if (storage.nominatorsAmount > 0) {
                    val ownerShare = mulDivFloor(profit, storage.ownerShare, SHARE_BASE);
                    val nominatorsProfit = profit - ownerShare;
                    storage.nominatorsAmount = max(storage.nominatorsAmount + nominatorsProfit, 0);
                }

                if (roundDone) {
                    // Instead of rotating inplace, do it by chaining txs
                    val rotateMsg = createMessage<UpdateVset>({
                        bounce: false,
                        value: ton("1"),
                        dest: contract.getAddress(),
                        body: UpdateVset { queryId: storage.roundIndex },
                    });
                    rotateMsg.send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);
                }
                storage.validators = validators.toCell();
            }

            storage.save();
        }
        RecoverStakeError => {
            val proxyData = ProxyResponseData.fromSlice(msg.remaining);
            val proxyAddress = getProxyAddress(proxyData.validator, proxyData.parity);
            assert(in.senderAddress == proxyAddress, ErrorsPool.NotFromProxy);
        }
        PayoutBurnNotification => {
            var nominators = lazy storage.nominators.load();

            val itemAddress = calculateItemState(
                msg.index,
                msg.roundIndex,
                msg.isWithdrawal,
            ).calculateAddress();
            assert(in.senderAddress == itemAddress, ErrorsPayout.InvalidSender);

            val distribution = msg.distribution;
            if (msg.isWithdrawal) {
                val nmLookup = nominators.poolNominators.deleteAndGetDeleted(msg.owner);
                assert(nmLookup.isFound, ErrorsPool.DepositNotFound);
                var nmData = nmLookup.loadValue();
                val sharePrice = calcSharePrice(
                    nmData.pendingWithdrawal,
                    distribution.pendingCoins,
                    distribution.pendingShare,
                );
                assert(sharePrice > 0, ErrorsPool.NothingToWithdraw);
                if (contract.getOriginalBalance() - POOL_MIN_STORAGE > sharePrice) {
                    // I don't see this ever getting below zero, but we can't afford that to stay.
                    // And single instruction call we can afford.
                    storage.pendingWithdrawals = max(
                        storage.pendingWithdrawals - nmData.pendingWithdrawal,
                        0,
                    );

                    storage.poolSupply = max(storage.poolSupply - nmData.pendingWithdrawal, 0);
                    storage.nominatorsAmount = max(storage.nominatorsAmount - sharePrice, 0);

                    if (nmData.share > 0 || nmData.pendingDeposit > 0) {
                        // May happen in reward withdrawal
                        nominators
                            .poolNominators
                            .set(
                                msg.owner,
                                {
                                    share: nmData.share,
                                    tonAmount: nmData.tonAmount,
                                    pendingDeposit: nmData.pendingDeposit,
                                    pendingWithdrawal: 0,
                                    depositIndex: nmData.depositIndex,
                                },
                            );
                    } else {
                        nominators.nmCount -= 1;
                    }
                    reserveGramsOnBalance(
                        sharePrice,
                        RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_NEGATE_AMOUNT,
                    );
                    val withdrawSuccess = createMessage({
                        bounce: false,
                        dest: msg.owner,
                        value: 0,
                        body: WithdrawSuccess {
                            queryId: msg.queryId,
                            totalStaked: nmData.tonAmount,
                            returned: sharePrice,
                            left: mulDivQuiet(
                                nmData.share,
                                distribution.pendingCoins,
                                distribution.pendingShare,
                            ),
                        },
                    });
                    // SAFETY: RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_NEGATE_AMOUNT reserves balanceOrig - sharePrice,
                    // leaving sharePrice plus any unused gas from the incoming message available. CARRY_ALL_BALANCE sends those available funds.
                    // IGNORE_ERRORS is used because if a nominator's withdrawal amount is so small that it cannot cover the forwarding fees,
                    // we intentionally let the send fail silently (absorbing the rounding dust) rather than fail the action phase or introduce
                    // a minimum withdrawal gate.
                    withdrawSuccess.send(
                        SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
                    );
                } else {
                    // Should never happen in reality, because pending amounts
                    // are excluded from the staking mass, but even if it does,
                    // nominator stake is safe.
                    // And no risk of double spending since everything
                    // is around single source of truth -> nominator map.
                    //
                    // Couldn't afford this kind a luxury in a liquid staking, huh?
                    // Resetting the withrawal index will allow subsequent withdrawal
                    nmData.withdrawalIndex = 0;
                    nominators.poolNominators.set(msg.owner, nmData);
                    val notificationMsg = createMessage({
                        dest: msg.owner,
                        bounce: false,
                        value: 0,
                        body: (0 as uint32, "Withdrawal has failed, retry later"),
                    });

                    notificationMsg.send(
                        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                    );
                }
            } else {
                var nmData = nominators
                    .poolNominators
                    .mustGet(
                        msg.owner,
                        ErrorsPool.OwnerNotFound,
                    ); //Nominator {share: 0, tonAmount: 0};

                val nmShare = calcShareCount(
                    nmData.pendingDeposit,
                    distribution.pendingShare,
                    distribution.pendingCoins,
                );
                assert(nmShare > 0 && nmData.pendingDeposit > 0, ErrorsPool.NothingToDeposit);
                storage.nominatorsAmount += nmData.pendingDeposit;

                var updatedNm = nmData.add({
                    tonAmount: nmData.pendingDeposit,
                    share: nmShare,
                });

                updatedNm.pendingDeposit = 0;
                updatedNm.depositIndex = 0;
                nominators.poolNominators.set(msg.owner, updatedNm);
                storage.poolSupply += nmShare;
                storage.pendingDeposits = max(storage.pendingDeposits - nmData.pendingDeposit, 0);
            }

            storage.nominators = nominators.toCell();
            storage.save();
        }
    }
}

fun onBouncedMessage(in: InMessageBounced) {
    var bouncedBody = in.bouncedBody;
    bouncedBody.skipBouncedPrefix();
    val msg = BounceableMessages.fromSlice(bouncedBody);
    match (msg) {
        NewStakeElector => {
            // Equivalent of ProxyNewStakeError
            handleNewStakeError(in.senderAddress, in.valueCoins);
        }
    }
}

get fun owner(): address {
    val storage = lazy PoolStorage.load();
    match (storage) {
        PoolStorageNotInitialized => {
            return storage.owner;
        }
        Storage => {
            return storage.owner;
        }
    }
}

get fun get_pool_id(): uint32 {
    val storage = lazy PoolStorage.load();
    match (storage) {
        PoolStorageNotInitialized => {
            return storage.poolId;
        }
        Storage => {
            return storage.poolId;
        }
    }
}

get fun get_pool_data(): Storage {
    return Storage.load();
}

get fun get_proxy_address(validator: address): GetProxyAddressResult {
    val storage = lazy Storage.load();
    val validators = lazy storage.validators.load();

    val valData = validators.getValidatorByAddress(validator, ErrorsPool.ValidatorNotFound)!;

    val allowedRounds = valData.roundParity as int;

    return {
        evenRounds: (allowedRounds & 2) > 0 ? getProxyAddress(validator, false) : null,
        oddRounds: (allowedRounds & 1) > 0 ? getProxyAddress(validator, true) : null,
    };
}

get fun get_nominator_data(nominatorAddress: int): GetNominatorData {
    var wc = 0;

    val storage = lazy Storage.load();
    val nominators = lazy storage.nominators.load();

    repeat (2) {
        val lookupAddress: address = address.fromWorkchainAndHash(wc, nominatorAddress);

        val lookupRes = nominators.poolNominators.get(lookupAddress);

        if (lookupRes.isFound) {
            val nmData = lookupRes.loadValue();
            var pendingAmount = 0;
            val sharePrice = calcSharePrice(
                nmData.share,
                storage.nominatorsAmount,
                storage.poolSupply,
            );
            pendingAmount = nmData.pendingDeposit;

            return {
                amount: sharePrice,
                pendingDepositAmount: pendingAmount,
                withdrawFound: nmData.pendingWithdrawal > 0,
                reward: sharePrice - nmData.tonAmount,
            };
        }

        wc -= 1;
    }

    // Retained for compatability with older pool contract
    throw 86;
}

get fun get_validator_info(address: address): GetValidatorInfo {
    val storage = lazy Storage.load();
    var validators = storage.validators.load();
    val validator = validators.getValidatorByAddress(address, ErrorsPool.ValidatorNotFound)!;
    val rotationStatus = validators.rotateRound(address, storage.roundIndex);
    var roundIndex = storage.roundIndex;
    if (rotationStatus.roundRotated) {
        roundIndex += 1;
    }
    val roundMask = parityToMask(roundIndex % 2 > 0);
    var stakeNotAvailable = validator.isBanned || rotationStatus.roundIsClosed || storage.halted;
    stakeNotAvailable = stakeNotAvailable || ((roundMask & validator.usageState) > 0);
    stakeNotAvailable = stakeNotAvailable || ((roundMask & validator.roundParity as int) == 0);
    val stakeLimits = lazy StakingLimits.load();
    stakeNotAvailable = stakeNotAvailable || validators.minTonPerValidator < stakeLimits.minStake;
    stakeNotAvailable = stakeNotAvailable || validators.maxTonPerValidator > stakeLimits.maxStake;

    var stakeable: coins;
    if (stakeNotAvailable) {
        stakeable = 0;
    } else {
        val (available, total, pendingWithdrawalAmount) = storage.getStakableBalance(
            0,
            validators.stakeUsed,
        );
        val stakeLimit = getValidatorLimit(
            validator.limit,
            total,
            validators.maxTonPerValidator,
        );

        stakeable = min(stakeLimit, available);
        if (stakeable < validators.minTonPerValidator) {
            stakeable = 0;
        }
        val ownerShare = total - storage.nominatorsAmount + pendingWithdrawalAmount;
        if (
            ownerShare <
            getMaxPunishmentInt(validators.minTonPerValidator) * (validators.activeSlots + 1)
        ) {
            stakeable = 0;
        }
    }

    return GetValidatorInfo {
        validator,
        usage: validator.allUsageRecords(
            toBitIndex(roundIndex),
            validators.curRound.load(),
            validators.prevRound.load(),
        ),
        stakeable,
        roundIndex,
        rotated: rotationStatus.roundRotated,
    };
}

get fun get_validator_info_mtc(workchain: int, hash: int): GetValidatorInfo {
    val address = address.fromWorkchainAndHash(workchain, hash);
    return get_validator_info(address);
}

get fun get_limits_per_validator(): (coins, coins, int) {
    val storage = lazy Storage.load();
    val validators = lazy storage.validators.load();

    return (validators.minTonPerValidator, validators.maxTonPerValidator, validators.refundBonus);
}

get fun get_nominator_minimal_stake(): GetMinStake {
    val storage = lazy Storage.load();
    val nominators = lazy storage.nominators.load();

    return { minStake: nominators.minStake, minExpectedValue: nominators.minStake + DEPOSIT_GAS };
}

get fun get_shares_info(): GetSharesInfoResult {
    val storage = lazy Storage.load();
    val validators = lazy storage.validators.load();
    val withdrawalsEst = calcSharePrice(
        storage.pendingWithdrawals,
        storage.nominatorsAmount,
        storage.poolSupply,
    );

    val availableBalance = contract.getOriginalBalance() - storage.pendingDeposits -
    POOL_MIN_STORAGE;

    val totalBalance = availableBalance + validators.stakeUsed;
    val ownerShare = max(
        totalBalance - storage.nominatorsAmount -
        getMaxPunishmentInt(validators.minTonPerValidator) * validators.activeSlots,
        0,
    );
    var liquid = max(min(ownerShare, availableBalance - withdrawalsEst), 0);
    // assert mirror logic
    if (storage.halted || totalBalance <= storage.nominatorsAmount) {
        liquid = 0;
    }

    return {
        nominatorsAmount: storage.nominatorsAmount,
        poolSupply: storage.poolSupply,
        ownerShareValue: ownerShare,
        liquidOwnerShare: liquid,
    };
}

// Recomputes cached aggregates from the primary nominator map and reports
// whether they match the stored values. Read-only diagnostic — no assertion.
// See PoolInvariants for the semantics of each field.
get fun get_pool_invariants(): PoolInvariants {
    val storage = lazy Storage.load();
    val nominators = lazy storage.nominators.load();
    val validators = lazy storage.validators.load();

    var recomputedSupply: coins = 0;
    var recomputedPendingWithdrawals: coins = 0;
    var recomputedPendingDeposits: coins = 0;
    var recomputedTonAmount: coins = 0;
    var recomputedNmCount: int = 0;

    var iter = nominators.poolNominators.findFirst();
    while (iter.isFound) {
        val nm = iter.loadValue();
        recomputedSupply += nm.share;
        recomputedPendingWithdrawals += nm.pendingWithdrawal;
        recomputedPendingDeposits += nm.pendingDeposit;
        recomputedTonAmount += nm.tonAmount;
        recomputedNmCount += 1;
        iter = nominators.poolNominators.iterateNext(iter);
    }

    val supplyMatch = recomputedSupply + recomputedPendingWithdrawals == storage.poolSupply;
    val pendingWithdrawalsMatch = recomputedPendingWithdrawals == storage.pendingWithdrawals;
    val pendingDepositsMatch = recomputedPendingDeposits == storage.pendingDeposits;
    val nmCountMatch = recomputedNmCount == nominators.nmCount;
    val allMatch = supplyMatch && pendingWithdrawalsMatch && pendingDepositsMatch && nmCountMatch;

    val projectedBalance = contract.getOriginalBalance() + validators.stakeUsed -
    storage.pendingDeposits -
    POOL_MIN_STORAGE;

    return PoolInvariants {
        supplyMatch,
        pendingWithdrawalsMatch,
        pendingDepositsMatch,
        nmCountMatch,
        allMatch,
        nominatorsAmount: storage.nominatorsAmount,
        projectedBalance,
        recomputedSupply,
        recomputedPendingWithdrawals,
        recomputedPendingDeposits,
        recomputedNmCount,
        recomputedTonAmount,
    };
}
