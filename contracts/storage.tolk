import "@stdlib/gas-payments"
import "@contracts/nominators"
import "@contracts/validators"
import "errors"
import "fees"
import "messages"
import "types"
import "utils"

type AllowedComments =
    | DepositMessage
    | WithdrawalMessage
    | WithdrawalReward

fun Storage.handleTextComment(mutate self, comment: slice, sender: address, value: coins) {
    val msg = AllowedComments.fromSlice(
        comment,
        { throwIfOpcodeDoesNotMatch: ErrorsPool.InvalidMessage },
    );

    var validators = self.validators.load();
    val totalBalance = contract.getOriginalBalance() - value - self.pendingDeposits -
    POOL_MIN_STORAGE +
    validators.stakeUsed;
    assert(totalBalance > self.nominatorsAmount, ErrorsPool.Insolvent);
    self.finalizeRound(validators.rotateRoundQuick(self.roundIndex), value);
    self.validators = validators.toCell();

    match (msg) {
        DepositMessage => {
            var nominators = lazy self.nominators.load();
            val incommingValue = value - DEPOSIT_GAS; // calculateGasFee(BASECHAIN, DEPOSIT_GAS);
            assert(incommingValue >= nominators.minStake, ErrorsPool.NotEnoughGas);
            if (!nominators.nominatorsWhitelist.isEmpty()) {
                assert(nominators.nominatorsWhitelist.exists(sender), ErrorsPool.DepositNotAllowed);
            }
            val prevRound = lazy validators.prevRound.load();

            val hasPrevUsage = !prevRound.users.isEmpty();

            val retryIdx = self.roundIndex + ROUNDS_DELAY;

            val nmLookup = nominators.poolNominators.get(sender);

            assert(nmLookup.isFound || nominators.nmCount <
            self.maxNominators, ErrorsPool.TooManyNominators);
            if (self.roundClosed || hasPrevUsage) {
                var pendingDeposits = nominators.pendingDeposits == null
                    ? PendingOps {
                        isWithdraw: false,
                        roundIndex: self.roundIndex,
                    }
                    : nominators.pendingDeposits.load();
                if (nmLookup.isFound) {
                    var oldPending = nmLookup.loadValue();
                    assert(oldPending.depositIndex <=
                    self.roundIndex, ErrorsPool.DepositAlreadyRequested);
                    oldPending.depositIndex = retryIdx;
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
                                depositIndex: retryIdx,
                            },
                        );
                    nominators.nmCount += 1;
                }
                pendingDeposits.addPending(sender);
                nominators.pendingDeposits = pendingDeposits.toCell();
                self.pendingDeposits += incommingValue;
            } else {
                val nmShare = calcSharePrice(
                    incommingValue,
                    self.poolSupply,
                    self.nominatorsAmount,
                );
                var newNominator: Nominator = {
                    tonAmount: incommingValue,
                    share: nmShare,
                    pendingDeposit: 0,
                };

                if (nmLookup.isFound) {
                    var oldNm = nmLookup.loadValue();
                    newNominator = oldNm.add(newNominator);
                } else {
                    nominators.nmCount += 1;
                }
                nominators.poolNominators.set(sender, newNominator);

                self.poolSupply += nmShare;
                self.nominatorsAmount += incommingValue;
            }
            assert(nominators.poolNominators.toLowLevelDict().depth() <=
            MAX_NM_DEPTH, ErrorsPool.NominatorsTooDeep);

            self.nominators = nominators.toCell();
            self.save();

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
            var nominators = lazy self.nominators.load();
            val nmLookup = nominators.poolNominators.deleteAndGetDeleted(sender);
            assert(nmLookup.isFound, ErrorsPool.DepositNotFound);
            var nominatorData = nmLookup.loadValue();

            // Full withdrawal
            val withdrawnShares = nominatorData.share;
            val shareValue = calcSharePrice(
                withdrawnShares,
                self.nominatorsAmount,
                self.poolSupply,
            );
            val pending = nominatorData.withdrawShare(
                sender,
                nominatorData.share,
                shareValue,
                self.roundClosed || self.pendingWithdrawals > 0,
                self.roundIndex,
                value,
                nominators.pendingWithdrawals,
            );

            if (pending == null) {
                nominators.nmCount -= 1;
                self.poolSupply -= withdrawnShares;
                self.nominatorsAmount -= shareValue;
            } else {
                self.pendingWithdrawals += withdrawnShares;
                nominators.pendingWithdrawals = pending;
                nominators.poolNominators.set(sender, nominatorData);
            }

            self.nominators = nominators.toCell();
            self.save();
        }
        WithdrawalReward => {
            var nominators = lazy self.nominators.load();
            var nmData = nominators.poolNominators.mustGet(sender, ErrorsPool.DepositNotFound);
            val sharePrice = calcSharePrice(
                nmData.share,
                self.nominatorsAmount,
                self.poolSupply,
            );

            val rewardAmount = sharePrice - nmData.tonAmount;
            assert(rewardAmount >=
            nominators.minWithdrawableReward, ErrorsPool.RewardIsBelowMinimal);
            // Share delta has rounding favouring the nominator in range of 1 share point.
            // Since 1 share point is initially 1 nanogram at start, pools don't make as much return,
            // to make this rounding economically significant.
            val shareDelta = calcShareCount(
                rewardAmount,
                self.poolSupply,
                self.nominatorsAmount,
            );

            // Very important, that nominator has to burn at least 1 share, otherwise rounding effects
            // would might sting someday.
            assert(sharePrice > 0 && shareDelta > 0, ErrorsPool.NothingToWithdraw);

            val pending = nmData.withdrawShare(
                sender,
                shareDelta,
                rewardAmount,
                self.roundClosed || self.pendingWithdrawals > 0,
                self.roundIndex,
                value,
                nominators.pendingWithdrawals,
            );

            if (pending == null) {
                self.poolSupply -= shareDelta;
                self.nominatorsAmount -= rewardAmount;
            } else {
                self.pendingWithdrawals += shareDelta;
                nominators.pendingWithdrawals = pending;
            }

            nominators.poolNominators.set(sender, nmData);
            self.nominators = nominators.toCell();
            self.save();
        }
    }
}

fun Storage.finalizeRound(mutate self, rotationStatus: RotationStatus, msgValue: int): int {
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
                contract.getOriginalBalance() - msgValue - POOL_MIN_STORAGE,
                self.poolSupply,
                self.nominatorsAmount,
                self.pendingDeposits,
                self.pendingWithdrawals,
            );
            if (pendingStatus.withdrawn > 0) {
                sentTotal += PAYOUT_CHAIN_START;
            }
            if (pendingStatus.deposited > 0) {
                sentTotal += PAYOUT_CHAIN_START;
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

fun Storage.sendStakeRecovery(
    mutate self,
    inValue: coins,
    sender: address,
    validator: address,
    op: uint32,
    queryId: uint64,
) {
    try {
        var validators = lazy self.validators.load();

        self.finalizeRound(validators.rotateRound(validator, self.roundIndex), inValue);
        // It's ok for roundIndex to go negative, since -1 has LSB set to true.
        var roundBitIdx = toBitIndex(self.roundIndex - 1);
        val validatorData = validators.getValidatorByAddress(
            validator,
            ErrorsPool.ValidatorNotFound,
        )!;
        val usageState = validatorData.usageState;
        assert(usageState > 0, ErrorsPool.UsageRecordNotFound);
        val actionableValue = min(inValue, MAX_RECOVERY_VALUE);
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
            validator,
            roundBitIdx % 2 > 0,
        );

        proxyAddressHash = proxyState.calculateAddress().getHash();
        val round = affectedRound.load();
        val usageRec = round.users.mustGet(proxyAddressHash, ErrorsPool.UsageRecordNotFound);
        val mcTimestamp = usageRec.rotation.checkRecoverRequirements(usageRec.heldFor);

        self.validators = validators.toCell();
        self.save();

        val recoveryStake = createMessage({
            dest: proxyState,
            bounce: false,
            value: actionableValue - calculateGasFee(BASECHAIN, getGasConsumedAtTheMoment() * 2),
            body: RecoverStakeCompat { queryId: mcTimestamp },
        });
        recoveryStake.send(SEND_MODE_REGULAR | SEND_MODE_BOUNCE_ON_ACTION_FAIL);
        reserveGramsOnBalance(
            0,
            RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_AT_MOST,
        );

        refundError(
            sender,
            {
                op,
                queryId,
                errorCode: 0,
            },
            SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS,
        );
    } catch (e) {
        refundError(
            sender,
            {
                op,
                queryId,
                errorCode: e,
            },
            SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS,
        );
    }
}
