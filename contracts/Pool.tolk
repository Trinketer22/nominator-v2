import "@stdlib/gas-payments"
import "@stdlib/reflection"
import "@contracts/fees"
import "@contracts/nominators"
import "@contracts/opcode"
import "@contracts/owner"
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

type BounceableMessages = NewStake

type AllowedComments =
    | DepositMessage
    | WithdrawalMessage
    | WithdrawalReward

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

fun handleTextComment(comment: slice, sender: address, value: coins) {
    val msg = AllowedComments.fromSlice(
        comment,
        { throwIfOpcodeDoesNotMatch: ErrorsPool.InvalidMessage },
    );

    match (msg) {
        DepositMessage => {
            var storage = lazy Storage.load();
            assert(!storage.halted, ErrorsPool.PoolIsHalted);
            var nominators = lazy storage.nominators.load();
            assert(nominators.nmCount < storage.maxNominators, ErrorsPool.TooManyNominators);
            val incommingValue = value - DEPOSIT_GAS; // calculateGasFee(BASECHAIN, DEPOSIT_GAS);
            assert(incommingValue >= nominators.minStake, ErrorsPool.NotEnoughGas);
            if (!nominators.nominatorsWhitelist.isEmpty()) {
                assert(nominators.nominatorsWhitelist.exists(sender), ErrorsPool.DepositNotAllowed);
            }
            val validators = lazy storage.validators.load();
            val prevRound = lazy validators.prevRound.load();

            val hasPrevUsage = !prevRound.users.isEmpty();

            if (storage.roundClosed || hasPrevUsage) {
                var pendingDeposits = nominators.pendingDeposits == null
                    ? PendingOps { isWithdraw: false }
                    : nominators.pendingDeposits.load();
                val nmLookup = nominators.poolNominators.get(sender);
                if (nmLookup.isFound) {
                    var oldPending = nmLookup.loadValue();
                    oldPending.pendingDeposit += incommingValue;
                    nominators.poolNominators.set(sender, oldPending);
                } else {
                    nominators
                        .poolNominators
                        .set(
                            sender,
                            {
                                share: 0,
                                tonAmount: 0,
                                pendingDeposit: incommingValue,
                            },
                        );
                    nominators.nmCount += 1;
                }
                pendingDeposits.addPending(sender, incommingValue, storage.roundIndex);
                nominators.pendingDeposits = pendingDeposits.toCell();
                storage.pendingDeposits += incommingValue;
            } else {
                val nmShare = calcSharePrice(
                    incommingValue,
                    storage.poolSupply,
                    storage.nominatorsAmount,
                );
                val newNominator: Nominator = {
                    tonAmount: incommingValue,
                    share: nmShare,
                    pendingDeposit: 0,
                };
                val nmLookup = nominators.poolNominators.addOrGetExisting(sender, newNominator);

                if (nmLookup.isFound) {
                    var oldNm = nmLookup.loadValue();
                    // Should we allow covering pendingDeposits here too?
                    // Like if user still has something pending.
                    // Smells like races
                    nominators.poolNominators.set(sender, oldNm.add(newNominator));
                } else {
                    nominators.nmCount += 1;
                }

                storage.poolSupply += nmShare;
                storage.nominatorsAmount += incommingValue;
            }

            storage.nominators = nominators.toCell();
            storage.save();

            reserveGramsOnBalance(
                incommingValue,
                RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
            );

            val depoNotification = createMessage({
                bounce: false,
                dest: sender,
                value: 0,
                body: DepositSuccess { queryId: 0 },
            });
            // SAFETY Reserving original balance + incommingValue, refund the fee leftowers
            // Failure should not revert state.
            depoNotification.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        WithdrawalMessage => {
            var storage = lazy Storage.load();
            assert(!storage.halted, ErrorsPool.PoolIsHalted);
            var nominators = lazy storage.nominators.load();
            val nmLookup = nominators.poolNominators.deleteAndGetDeleted(sender);
            assert(nmLookup.isFound, ErrorsPool.DepositNotFound);
            var nominatorData = nmLookup.loadValue();

            // Full withdrawal
            val withdrawnShares = nominatorData.share;
            val shareValue = calcSharePrice(
                withdrawnShares,
                storage.nominatorsAmount,
                storage.poolSupply,
            );
            val pending = nominatorData.withdrawShare(
                sender,
                nominatorData.share,
                shareValue,
                storage.roundClosed,
                storage.roundIndex,
                value,
                nominators.pendingWithdrawals,
            );

            if (pending == null) {
                nominators.nmCount -= 1;
                storage.poolSupply -= withdrawnShares;
                storage.nominatorsAmount -= shareValue;
            } else {
                storage.pendingWithdrawals += withdrawnShares;
                nominators.pendingWithdrawals = pending;
                nominators.poolNominators.set(sender, nominatorData);
            }

            storage.nominators = nominators.toCell();
            storage.save();
        }
        WithdrawalReward => {
            var storage = lazy Storage.load();

            var nominators = lazy storage.nominators.load();
            var nmData = nominators.poolNominators.mustGet(sender, ErrorsPool.DepositNotFound);
            val sharePrice = calcSharePrice(
                nmData.share,
                storage.nominatorsAmount,
                storage.poolSupply,
            );

            val rewardAmount = sharePrice - nmData.tonAmount;
            assert(rewardAmount >=
            nominators.minWithdrawableReward, ErrorsPool.RewardIsBelowMinimal);
            // Share delta has rounding favouring the nominator in range of 1 share point.
            // Since 1 share point is initially 1 nanogram at start, pools don't make as much return,
            // to make this rounding economically significant.
            // Which is ok, is it?
            val shareDelta = calcShareCount(
                rewardAmount,
                storage.poolSupply,
                storage.nominatorsAmount,
            );

            // Very important, that nominator has to burn at least 1 share, otherwise rounding effects
            // would might sting someday.
            assert(sharePrice > 0 && shareDelta > 0, ErrorsPool.NothingToWithdraw);

            val pending = nmData.withdrawShare(
                sender,
                shareDelta,
                rewardAmount,
                storage.roundClosed,
                storage.roundIndex,
                value,
                nominators.pendingWithdrawals,
            );

            if (pending == null) {
                storage.poolSupply -= shareDelta;
                storage.nominatorsAmount -= rewardAmount;
            } else {
                storage.pendingWithdrawals += shareDelta;
                nominators.pendingWithdrawals = pending;
            }

            nominators.poolNominators.set(sender, nmData);
            storage.nominators = nominators.toCell();
            storage.save();
        }
    }
}

fun Storage.finalizeRound(mutate self, rotationStatus: RotationStatus): int {
    self.roundClosed = rotationStatus.roundIsClosed;
    var sentTotal = 0;
    if (rotationStatus.roundRotated) {
        val roundInfoMsg = createMessage({
            bounce: false,
            value: 0,
            dest: self.owner,
            body: RoundInfoMessage {
                queryId: blockchain.logicalTime(),
                info: rotationStatus.prevRoundInfo!,
            },
        });
        // Should not allow any roll-backs due to action phase failure
        sentTotal += roundInfoMsg.sendAndEstimateFee(
            SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
        );
        if ((self.pendingDeposits | self.pendingWithdrawals) > 0) {
            var nominators = lazy self.nominators.load();
            val pendingStatus = nominators.processPending(
                contract.getOriginalBalance() - POOL_MIN_STORAGE,
                self.poolSupply,
                self.nominatorsAmount,
            );
            if (pendingStatus.withdrawn > 0) {
                sentTotal += PAYOUT_ITEM_BALANCE;
            }
            if (pendingStatus.deposited > 0) {
                sentTotal += PAYOUT_ITEM_BALANCE;
            }
            self.halted = pendingStatus.halted;
            if (!pendingStatus.halted) {
                self.nominators = nominators.toCell();
            }
        }
        // Last but not least
        self.roundIndex += 1;
    }

    return sentTotal;
}

fun Storage.getStakableBalance(self, inValue: coins, stakeUsed: int): (coins, coins, int) {
    // pendingDeposits nominated in coins.
    // pendingWithdrawals howevever are nominated in shares
    // thus require conversion
    // It's a mulDiv, so not a big deal.
    // It is safe to use spot price, because
    // if price changes, pool obligations change accordingly, since it is nominated in shares
    val estPendingWithdrawals = calcSharePrice(
        self.pendingWithdrawals,
        self.nominatorsAmount,
        self.poolSupply,
    );
    // This is available balance for staking
    // Excluding
    // 1) Incoming value, because it funds gas
    // 2) All the pending aggregate
    // 3) Storage reserves
    val availableBalance = contract.getOriginalBalance() - inValue - self.pendingDeposits -
    estPendingWithdrawals -
    POOL_MIN_STORAGE;

    val totalBalance = availableBalance + stakeUsed;

    return (availableBalance, totalBalance, estPendingWithdrawals);
}

get fun get_max_punishment(stake: int): int {
    val storage = Storage.load();
    val validators = lazy storage.validators.load();

    // We don't want to guess the minimum, so if specified is below minimum, minimum is checked
    stake = min(max(stake, 0), validators.minTonPerValidator);

    // If it is above pool max, it makes sense to throw
    assert(stake <= validators.maxTonPerValidator, ErrorsPool.StakeAboveTheLimit);

    return getMaxPunishmentInt(stake);
}

fun handleNewStakeError(sender: address, value: int) {
    var storage = lazy Storage.load();
    var validators = lazy storage.validators.load();
    val (workchain, addrHash) = sender.getWorkchainAndHash();
    assert(workchain == MASTERCHAIN, ErrorsPool.NotFromProxy);

    // var curRound = validators.curRound.load();
    val _returnedVal = value - ton("1");

    // 1 ton we're guaranteed to have for each NewStake
    // var (stakeReturned, roundIdx,_roundDone) = validators.coverUsageByAddress(sender, returnedVal, true, ton("1"));
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
            valState.data.usageState &= ~parityToMask(round.roundIndex % 2 > 0);
            valState.data.refundAmount = max(valState.data.refundAmount - delta, 0);
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
            refundAmount: 0,
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

        val validatorsData = ValidatorsData {
            mainValidatorAddress: msg.mainValidator,
            maxTonPerValidator: msg.maxTonPerValidator,
            minTonPerValidator: msg.minTonPerValidator,
            curRound: RoundData { roundIndex: 0 }.toCell(),
            prevRound: RoundData { roundIndex: 0 }.toCell(),
            vsetHash: getCurVset().vsetHash >> 128,
            mainValidatorData: mainValidator.toCell(),
            maxRefundAmount: msg.maxRefund,
        };
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
                handleTextComment(msg.comment, in.senderAddress, in.valueCoins);
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
            var validators = storage.validators.load();
            val inValue = min(in.valueCoins, REFUND_THRESHOLD);
            val status = validators.rotateRound(in.senderAddress, storage.roundIndex, inValue);
            storage.finalizeRound(status);
            /*
            if(status.rotated && !status.closed) {
                storage.roundIndex += 1;
                if((storage.pendingDeposits | storage.pendingWithdrawals) > 0) {
                    val availableBalance = contract.getOriginalBalance() - in.valueCoins - POOL_MIN_STORAGE;
                    var nominators = storage.nominators.load();
                    val processingRes = nominators.processPending(availableBalance, storage.poolSupply, storage.nominatorsAmount);
                    storage.halted = processingRes.halted;
                    if(!processingRes.halted) {
                        storage.nominators = nominators.toCell();
                    }
                }
            }
            */
            reserveGramsOnBalance(
                REFUND_THRESHOLD,
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
                assert(!storage.halted, ErrorsPool.PoolIsHalted);
                var valData = validators.getValidatorByAddress(
                    in.senderAddress,
                    ErrorsPool.ValidatorNotFound,
                )!;

                val (
                    availableBalance,
                    totalBalance,
                    estPendingWithdrawals,
                ) = storage.getStakableBalance(in.valueCoins, validators.stakeUsed);
                assert(msg.value <= availableBalance, ErrorsPool.NotEnoughPoolBalance);
                val stakeAmountSent = msg.value - ton("1");

                assert(msg.value >= validators.minTonPerValidator, ErrorsPool.StakeBelowLimit);
                if (valData.data.isBanned) {
                    assert(valData.data.usageState == 0, ErrorsPool.ValidatorNotFound);
                    refundError(
                        in.senderAddress,
                        {
                            op: reflect.serializationPrefixOf<NewStake>().0,
                            errorCode: ErrorsPool.ValidatorNotFound,
                        },
                        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                    );
                    validators.validators.delete(in.senderAddress);
                    storage.validators = validators.toCell();
                    storage.save();
                    return;
                }

                val newStake = NewStakeBody.fromSlice(msg.signedBody);
                assert(newStake.stakeAt >= 0, ErrorsPool.InvalidMessage);

                val valLimit = valData.data.limit;
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
                assert((valData.data.usageState & roundIndex) ==
                0, ErrorsPool.AlreadyStakedInThatRound);
                assert((valData.data.roundParity as int & roundIndex) !=
                0, ErrorsPool.RoundNotAllowed);
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

                valData.data = {
                    usageState: valData.data.usageState | roundIndex,
                    roundParity: valData.data.roundParity,
                    oddProxy: valData.data.oddProxy,
                    evenProxy: valData.data.evenProxy,
                    limit: valLimit,
                    refundAmount: valData.data.refundAmount + min(in.valueCoins, REFUND_THRESHOLD),
                };

                validators.updateValidatorByAddress(in.senderAddress, valData);

                var curRound = validators.curRound.load();
                curRound.used += stakeAmountSent;
                val proxyAddress = valData.data.getProxyAddressByParity(roundIndex);
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

            // If sender is not valida proxy, bounce?
            // Otherwise there is nothing to do
            assert(in.senderAddress == proxyAddress, ErrorsPool.NotFromProxy);
        }
        NewStakeError => {
            handleNewStakeError(in.senderAddress, in.valueCoins);
        }
        RecoverStakeCompat => {
            try {
                val validators = lazy storage.validators.load();

                // It's ok for roundIndex to go negative, since -1 has LSB set to true.
                var roundBitIdx = toBitIndex(storage.roundIndex - 1);
                var validatorData = validators.getValidatorByAddress(
                    in.senderAddress,
                    ErrorsPool.ValidatorNotFound,
                )!;
                val usageState = validatorData.data.usageState;
                assert(usageState > 0, ErrorsPool.UsageRecordNotFound);
                val actionableValue = min(in.valueCoins, MAX_RECOVERY_VALUE);
                validatorData.data.refundAmount += actionableValue;
                var proxyAddressHash: uint256;

                // Idea to use proxy address from state
                // is to attach state init and potentially
                // unfreeze frozen proxy, if such thing ever happens
                var proxyState: AutoDeployAddress;
                var affectedRound: Cell<RoundData>;
                if ((roundBitIdx & usageState) > 0) {
                    affectedRound = validators.prevRound;
                } else {
                    affectedRound = validators.curRound;
                    roundBitIdx += 1;
                }

                proxyState = getProxyState(
                    in.senderAddress,
                    roundBitIdx % 2 > 0,
                );

                //if(storage.maxNominators > 0) {
                // Single nominator mode TODO
                proxyAddressHash = proxyState.calculateAddress().getHash();
                val round = affectedRound.load();
                val usageRec = round
                    .users
                    .mustGet(proxyAddressHash, ErrorsPool.UsageRecordNotFound);
                usageRec.rotation.checkRecoverRequirements(usageRec.heldFor);
                //}

                storage.validators = validators.toCell();
                storage.save();

                val recoveryStake = createMessage({
                    dest: proxyState,
                    bounce: false,
                    value: actionableValue -
                    calculateGasFee(BASECHAIN, getGasConsumedAtTheMoment() * 2),
                    body: in.body,
                });
                recoveryStake.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
                reserveGramsOnBalance(
                    MAX_RECOVERY_VALUE,
                    RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_AT_MOST,
                );

                refundError(
                    in.senderAddress,
                    {
                        op: opcode<RecoverStakeCompat>(),
                        queryId: msg.queryId,
                        errorCode: 0,
                    },
                    SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
                );
            } catch (e) {
                refundError(
                    in.senderAddress,
                    {
                        op: opcode<RecoverStakeCompat>(),
                        queryId: msg.queryId,
                        errorCode: e,
                    },
                    SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
                );
            }
        }
        RecoverStakeUnrestricted => {
            val validators = lazy storage.validators.load();
            val valData = validators.getValidatorByAddress(
                msg.validator,
                ErrorsPool.ValidatorNotFound,
            )!;

            // If there is no usage record, there is no point of sending recovery
            assert(valData.data.usageState > 0, ErrorsPool.UsageRecordNotFound);
            var roundBitIdx = toBitIndex(storage.roundIndex - 1);
            if ((valData.data.usageState & roundBitIdx) == 0) {
                roundBitIdx += 1;
            }

            val proxyState = getProxyState(msg.validator, roundBitIdx % 2 > 0);
            val usageRec = validators.getUsageRecord(
                proxyState.calculateAddress().getHash(),
                valData.data.usageState,
                ErrorsPool.UsageRecordNotFound,
            )!;

            // For unrestricted recovery always check the timing
            usageRec.data.rotation.checkRecoverRequirements(usageRec.data.heldFor);
            val minFee = calculateGasFee(BASECHAIN, getGasConsumedAtTheMoment() * 2) +
            in.originalForwardFee +
            msg.amount;

            assert(in.valueCoins >= minFee, ErrorsPool.NotEnoughGas);

            reserveGramsOnBalance(0, RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE);
            val recoverStakeCompat = createMessage({
                dest: proxyState,
                // It will cary stateinit in case of unfreeze
                // So should not bounce of frozen acct
                // Also it is going to pay any occured storage for the proxy
                bounce: false,
                value: msg.amount,
                body: RecoverStakeCompat { queryId: msg.queryId },
            });
            recoverStakeCompat.send(SEND_MODE_PAY_FEES_SEPARATELY);
            refundError(
                in.senderAddress,
                {
                    op: opcode<RecoverStakeUnrestricted>(),
                    queryId: msg.queryId,
                    errorCode: 0,
                },
                SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
            );
        }
        RecoverStakeOk => {
            var validators = lazy storage.validators.load();

            // Since round map has proxy address as a key, we don't need state->address calculation
            val refundBonus = calculateGasFee(BASECHAIN, REFUND_BONUS_GAS);
            var returned = in.valueCoins -
            calculateGasFee(
                BASECHAIN,
                RECOVER_STAKE_OK_GAS,
            );
            val proxyData = ProxyResponseData.fromSlice(msg.remaining);

            var validator = validators.getValidatorByAddress(proxyData.validator, null);

            // Ugly but works
            var refundAmount = 0;
            if (validator != null) {
                refundAmount = min(validator.data.refundAmount, validators.maxRefundAmount);
                returned -= refundAmount + refundBonus;
            }

            val (stakeReturned, _roundIdx, roundDone) = validators.coverUsageByAddress(
                in.senderAddress,
                returned,
                (storage.roundIndex % 2 > 0) == proxyData.parity,
            );

            if (stakeReturned == null) {
                val expectedAdddress = getProxyAddress(proxyData.validator, proxyData.parity);
                // If it came from something else - bounce
                assert(expectedAdddress == in.senderAddress, ErrorsPool.NotFromProxy);
                // Otherwise should never happen, but if it did, there is nothing to do
                return;
            }

            val profit = returned - stakeReturned.tonUsed;

            validators.stakeUsed -= stakeReturned.tonUsed;
            validators.activeSlots -= 1;

            // This should practically always be true.
            if (validator != null) {
                // Should we refund in case of negative returns?
                val stakeReturnedMsg = createMessage({
                    bounce: false,
                    value: refundAmount + refundBonus,
                    dest: stakeReturned.validator,
                    body: StakeReturned {
                        queryId: msg.queryId,
                        used: stakeReturned.tonUsed,
                        returned,
                        validator: stakeReturned.validator,
                    },
                });
                stakeReturnedMsg.send(SEND_MODE_REGULAR | SEND_MODE_IGNORE_ERRORS);

                // Who we owe are all forgiven
                validator.data.usageState &= ~parityToMask(proxyData.parity);
                if (validator.data.usageState == 0) {
                    validator.data.refundAmount = 0;
                } else {
                    validator.data.refundAmount -= refundAmount;
                }
                validators.updateValidatorByAddress(stakeReturned.validator, validator);

                if (storage.nominatorsAmount > 0) {
                    val ownerShare = mulDivFloor(profit, storage.ownerShare, SHARE_BASE);
                    val nominatorsProfit = profit - ownerShare;
                    storage.nominatorsAmount = max(storage.nominatorsAmount + nominatorsProfit, 0);
                }

                if (roundDone) {
                    val rotationRes = validators.rotateRound(
                        stakeReturned.validator,
                        storage.roundIndex,
                    );
                    storage.finalizeRound(rotationRes);
                    /*
                    if(rotationRes.rotated && !rotationRes.closed) {
                        if((storage.pendingDeposits | storage.pendingWithdrawals) > 0){
                            var nominators = lazy storage.nominators.load();
                            val status = nominators.processPending(contract.getOriginalBalance() -
                            POOL_MIN_STORAGE, storage.poolSupply, storage.nominatorsAmount);
                            storage.halted = status.halted;
                            if(!status.halted) {
                                storage.nominators = nominators.toCell();
                            }
                        }
                        storage.roundIndex += 1;
                    }
                    storage.roundClosed = rotationRes.closed;
                    */
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
                if (contract.getOriginalBalance() - POOL_MIN_STORAGE - in.valueCoins > sharePrice) {
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
        NewStake => {
            // Equivalent of ProxyNewStakeError
            handleNewStakeError(in.senderAddress, in.valueCoins);
        }
    }
}

get fun owner(): address {
    val storage = lazy Storage.load();
    return storage.owner;
}

get fun get_pool_data(): Storage {
    return Storage.load();
}

get fun get_proxy_address(validator: address): GetProxyAddressResult {
    val storage = lazy Storage.load();
    val validators = lazy storage.validators.load();

    val valData = validators.getValidatorByAddress(validator, ErrorsPool.ValidatorNotFound)!;

    val allowedRounds = valData.data.roundParity as int;

    return {
        evenRounds: (allowedRounds & 2) > 0 ? getProxyAddress(validator, false) : null,
        oddRounds: (allowedRounds & 1) > 0 ? getProxyAddress(validator, true) : null,
    };
}

// Should we retain compatability even though nominators can now be in both workchains?
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
                reward: sharePrice -
                nmData.tonAmount,                      // Does it practically break the compatability?
            };
        }

        wc -= 1;
    }

    throw 86;
}

get fun get_validator_info(address: address): GetValidatorInfo {
    val storage = lazy Storage.load();
    val validators = storage.validators.load();
    val validator = validators.getValidatorByAddress(address, ErrorsPool.ValidatorNotFound)!;
    val roundMask = parityToMask(storage.roundIndex % 2 > 0);
    var stakeNotAvailable = validator.data.isBanned || storage.roundClosed;
    stakeNotAvailable = stakeNotAvailable || ((roundMask & validator.data.usageState) > 0);
    stakeNotAvailable = stakeNotAvailable || ((roundMask & validator.data.roundParity as int) == 0);

    var stakeable: coins;
    if (stakeNotAvailable) {
        stakeable = 0;
    } else {
        val (available, total, _) = storage.getStakableBalance(0, validators.stakeUsed);
        val stakeLimit = getValidatorLimit(
            validator.data.limit,
            total,
            validators.maxTonPerValidator,
        );

        stakeable = min(stakeLimit, available);
        if (stakeable < validators.minTonPerValidator) {
            stakeable = 0;
        }
    }

    return GetValidatorInfo {
        validator: validator.data,
        usage: validator
            .data
            .allUsageRecords(
                toBitIndex(storage.roundIndex),
                validators.curRound.load(),
                validators.prevRound.load(),
            ),
        stakeable,
    };
}

get fun get_validator_info_mtc(workchain: int, hash: int): GetValidatorInfo {
    val address = address.fromWorkchainAndHash(workchain, hash);
    return get_validator_info(address);
}

get fun get_limits_per_validator(): (coins, coins, coins) {
    val storage = lazy Storage.load();
    val validators = lazy storage.validators.load();

    return (
        validators.minTonPerValidator,
        validators.maxTonPerValidator,
        validators.maxRefundAmount,
    );
}

get fun get_nominator_minimal_stake(): GetMinStake {
    val storage = lazy Storage.load();
    val nominators = lazy storage.nominators.load();

    return { minStake: nominators.minStake, minExpectedValue: nominators.minStake + DEPOSIT_GAS };
}
