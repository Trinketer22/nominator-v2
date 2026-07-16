import "@contracts/errors"
import "@contracts/opcode"
import "@contracts/utils"
import "@gen/PayoutItem.code"
import "fees"
import "messages"
import "types"

fun calculateItemStateInit(index: int, roundIndex: int, withdrawal: bool): StateInit {
    val itemData = ItemStorageNotInitialized {
        data: {
            pool: contract.getAddress(),
            index,
            roundIndex,
            isWithdrawal: withdrawal,
            prev: null,
            next: null,
        },
    }.toCell();
    return StateInit {
        fixedPrefixLength: 4,
        special: null,
        code: payoutItemCompiledCode(),
        data: itemData,
        library: null,
    };
}

fun calculateItemState(index: int, roundIndex: int, withdrawal: bool): AutoDeployAddress {
    val itemInit: AutoDeployAddress = {
        stateInit: calculateItemStateInit(index, roundIndex, withdrawal).toCell(),
        toShard: { closeTo: contract.getAddress(), fixedPrefixLength: 4 },
    };
    return itemInit;
}

fun Nominator.withdrawShare(
    mutate self,
    owner: address,
    shareCount: coins,
    shareValue: coins,
    roundClosed: bool,
    roundIndex: int,
    msgValue: coins,
    pending: Cell<PendingOps>?,
): Cell<PendingOps>? {
    val availableBalance = contract.getOriginalBalance() - msgValue - POOL_MIN_STORAGE;

    // Share value 0 allowed for emergency cases of withdrawal failure, and withdrawal index being reset
    // Should never happen in practice
    assert(shareValue > 0 || self.pendingWithdrawal > 0, ErrorsPool.NothingToWithdraw);

    // Idea is that nominator can request pending withdrawal once per round.
    // If something failed misserably(hopefully never happens), nominator can retry in a next round
    // Since all withdrawals are based on the current nominator pendingWithdrawal amount
    // there is no visible risk of double spending.
    // In theory
    // round closes->payout starts in this timeframe till PayoutBurnNotification has not reached the pool
    // nominator can create a new bill, but.
    // 1) It will only be redeemed next round
    // 2) By the time it will be redeemed, nominator will be fully withdrawn
    assert(self.withdrawalIndex <= roundIndex, ErrorsPool.WithdrawalAlreadyRequested);

    self.share -= shareCount;

    // 0 case can only be withdrawn in pending mode again
    if (roundClosed || availableBalance < shareValue || shareCount == 0) {
        assert(msgValue >= WITHDRAWAL_GAS, ErrorsPool.NotEnoughGas);
        // Means all the expenses are out of incommingValue
        reserveGramsOnBalance(
            0,
            RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
        );
        var pendingWithdrawals: PendingOps;

        if (pending == null) {
            pendingWithdrawals = PendingOps { isWithdraw: true };
        } else {
            pendingWithdrawals = pending.load();
        }

        val newPending = shareCount + self.pendingWithdrawal;
        pendingWithdrawals.addPending(owner, newPending, roundIndex);
        // In ROUNDS_DELAY rounds should be guaranteed to withdraw, but
        // if this doesn't happen for whatever reason,
        // nominator will be able to retry.
        // Something that is not possible in liquid pools
        self.withdrawalIndex = roundIndex + ROUNDS_DELAY;
        self.pendingWithdrawal += shareCount;
        val pendingRefund = createMessage({
            bounce: false,
            dest: owner,
            value: 0,
            body: RefundMessage {
                context: RefundContext {
                    op: opcode<WithdrawalMessage>(),
                    errorCode: 0,
                },
            },
        });
        // SAFETY: CARRY_ALL_BALANCE in this case is the incomming message value - gas - any outgoing value
        // from pending PayoutItem deployment.
        // IGNORE_ERRORS is safe because it is a refund.
        pendingRefund.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);

        return pendingWithdrawals.toCell();
    }

    reserveGramsOnBalance(
        shareValue,
        RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_NEGATE_AMOUNT |
        RESERVE_MODE_BOUNCE_ON_ACTION_FAIL,
    );
    val withdrawSuccess = createMessage({
        bounce: false,
        dest: owner,
        value: 0,
        body: WithdrawSuccess {
            queryId: 0,
            totalStaked: self.tonAmount,
            returned: shareValue,
            left: 0,
        },
    });
    // SAFETY: RESERVE_MODE_INCREASE_BY_ORIGINAL_BALANCE | RESERVE_MODE_NEGATE_AMOUNT reserves balanceOrig - shareValue,
    // leaving shareValue plus any unused gas from the incoming message available. CARRY_ALL_BALANCE sends all remaining
    // funds (the shareValue plus gas surplus) in one go. BOUNCE_ON_ACTION_FAIL ensures the gas surplus is returned to the user
    // if shareValue can't be withdrawn
    withdrawSuccess.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    return null;
}

fun NominatorsData.processPending(
    mutate self,
    availableBalance: coins,
    supply: coins,
    total: coins,
): PendingProcessingResult {
    var halted = false;
    var withdrawn: coins = 0;
    var deposited: coins = 0;

    // If there is remotely not enough balance to fail the chain start - halt
    if (availableBalance < PAYOUT_ITEM_BALANCE * 3) {
        return {
            withdrawn,
            deposited,
            halted: true,
        };
    }
    if (self.pendingWithdrawals != null) {
        val withdrawals = self.pendingWithdrawals.load();
        (withdrawn, halted) = withdrawals.process(availableBalance, supply, total);
        if (!halted) {
            self.pendingWithdrawals = null;
        }
    }
    if (self.pendingDeposits != null && !halted) {
        val deposits = self.pendingDeposits.load();
        (deposited, halted) = deposits.process(availableBalance, supply, total);
        if (!halted) {
            self.pendingDeposits = null;
        }
    }

    return PendingProcessingResult { withdrawn, deposited, halted };
}

fun Nominator.add(mutate self, nm: Nominator): Nominator {
    self.share += nm.share;
    self.tonAmount += nm.tonAmount;
    return self;
}

fun PendingOps.process(self, availableBalance: coins, supply: coins, total: coins): (coins, bool) {
    var processedAmount: coins;

    if (self.isWithdraw) {
        processedAmount = calcSharePrice(self.pendingAmount, total, supply);
        if (availableBalance < processedAmount) {
            return (0 as coins, true);
        }
    } else {
        processedAmount = calcShareCount(self.pendingAmount, supply, total);
    }
    // No balance check here, since that is an action we can execute
    // even at a cost of loosing fraction of storage reserve.
    // If this ever happens, that would mean pool is already at dire situation
    if (processedAmount > 0) {
        val burnMessage = createMessage({
            bounce: false,
            dest: self.cur!,
            value: PAYOUT_ITEM_BALANCE, // Item balance - fwd fees is more than enough to cover gas
            body: PayoutBurnMessage {
                queryId: blockchain.logicalTime(),
                distribution: Distribution {
                    pendingCoins: total,
                    pendingShare: supply,
                },
            },
        });
        burnMessage.send(SEND_MODE_REGULAR);
    }
    return (processedAmount, false);
}

fun PendingOps.addPending(mutate self, owner: address, amount: int, roundIndex: int): uint64 {
    // Repilcating the mechanics of liquid staking payout
    self.index += 1;
    self.pendingAmount += amount;
    if (self.nextStateInit == null) {
        self.nextStateInit = calculateItemStateInit(
            self.index,
            roundIndex,
            self.isWithdraw,
        ).toCell();
        self.next = AutoDeployAddress {
            stateInit: self.nextStateInit!,
            toShard: { closeTo: contract.getAddress(), fixedPrefixLength: 4 },
        }.calculateAddress();
    }

    self.prev = self.cur;
    self.cur = self.next;

    val curStateInit = self.nextStateInit!;

    self.nextStateInit = calculateItemStateInit(
        self.index + 1,
        roundIndex,
        self.isWithdraw,
    ).toCell();
    self.next = AutoDeployAddress {
        stateInit: self.nextStateInit!,
        toShard: { closeTo: contract.getAddress(), fixedPrefixLength: 4 },
    }.calculateAddress();

    val payoutInit = createMessage({
        bounce: false,
        dest: {
            stateInit: curStateInit,
            toShard: { closeTo: contract.getAddress(), fixedPrefixLength: 4 },
        },
        value: PAYOUT_ITEM_BALANCE,
        body: PayoutInitMessage {
            isWithdrawal: self.isWithdraw,
            roundIndex,
            queryId: 0,
            owner,
            prev: self.next,
            next: self.prev,
        },
    });
    payoutInit.send(SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL);

    return self.index;
}
