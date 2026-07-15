import "config"
import "fees"
import "messages"
import "types"

contract Proxy {
    author: ""
    version: "1.0.0"
    description: "My TON contract"
    incomingMessages: PoolMessages
    storage: ProxyStorage
}

struct ProxyResponse {
    electorResponse: slice
    validator: address
    parity: bool
}

type PoolMessages =
    | InitProxy
    | NewStake
    | RecoverStakeCompat

type PoolMessagesBounceable = NewStake | RecoverStakeCompat

type ElectorMessages =
    | NewStakeOk
    | NewStakeError
    | RecoverStakeOk
    | RecoverStakeError

fun proxyMsg(dst: address, body: slice, mode: int, value: int, bouncable: bool) {
    val outMessage = createMessage({
        bounce: bouncable,
        dest: dst,
        value,
        body,
    });
    outMessage.send(mode);
}

fun onBouncedMessage(in: InMessageBounced) {
    val msg = lazy PoolMessagesBounceable.fromSlice(in.bouncedBody.skipBouncedPrefix());
    val storage = ProxyStorage.fromCell(contract.getData());
    val resp = match (msg) {
        NewStake => createMessage({
            dest: storage.pool,
            bounce: false,
            value: 0,
            body: NewStakeError {
                queryId: msg.queryId,
                reason: 0,
                remaining: ProxyResponseData {
                    validator: storage.validator,
                    parity: storage.roundParity,
                }.toCell()
                    .beginParse(),
            },
        }),
        RecoverStakeCompat => createMessage({
            dest: storage.pool,
            bounce: false,
            value: 0,
            body: RecoverStakeError {
                queryId: msg.queryId,
                answer: 0,
                remaining: ProxyResponseData {
                    validator: storage.validator,
                    parity: storage.roundParity,
                }.toCell()
                    .beginParse(),
            },
        }),
    };

    resp.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
}

fun onInternalMessage(in: InMessage) {
    val elector = getElectorAddress();
    val storage = ProxyStorage.fromCell(contract.getData());
    val poolAddr = storage.pool;

    if (in.senderAddress == poolAddr) {
        val msg = lazy PoolMessages.fromSlice(in.body);

        match (msg) {
            InitProxy => {
                // Take the storage reserve, and refund rest to the owner
                reserveGramsOnBalance(PROXY_MIN_STORAGE, RESERVE_MODE_AT_MOST);
                val proxyInit = createMessage({
                    bounce: false,
                    dest: msg.response,
                    value: 0,
                    body: ProxyInitSuccessfull {
                        queryId: msg.queryId,
                        validator: storage.validator,
                        parity: storage.roundParity,
                    },
                });
                // SAFETY: PROXY_MIN_STORAGE was reserved with RESERVE_MODE_AT_MOST above, so CARRY_ALL_BALANCE sends only surplus.
                // Since refund is an optional action, IGNORE_ERRORS makes perfect sense.
                proxyInit.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
            }
            NewStake => {
                // Incoming value here is guaranteed to exceed compute budget by far.
                // So, by paying fees separately, we escentially borrow compute cost from
                // storage reserve, which is intended
                proxyMsg(
                    elector,
                    in.body,
                    SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_BOUNCE_ON_ACTION_FAIL,
                    in.valueCoins,
                    true,
                );
            }
            RecoverStakeCompat => {
                if (blockchain.now() > msg.queryId) {
                    proxyMsg(
                        elector,
                        in.body,
                        SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE,
                        0,
                        true,
                    );
                } else {
                    val recoverStakeError = createMessage({
                        bounce: false,
                        dest: storage.pool,
                        value: 0,
                        body: RecoverStakeError {
                            queryId: msg.queryId,
                            answer: blockchain.now(),
                            remaining: ProxyResponseData {
                                validator: storage.validator,
                                parity: storage.roundParity,
                            }.toCell()
                                .beginParse(),
                        },
                    });
                    recoverStakeError.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
                }
            }
        }
    } else if (in.senderAddress == elector) {
        val msg = ElectorMessages.fromSlice(in.body);
        val proxyResponse = ProxyResponse {
            electorResponse: in.body,
            validator: storage.validator,
            parity: storage.roundParity,
        }.toCell()
            .beginParse();

        var outValue = 0;
        var outMode = SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE;

        if (msg is RecoverStakeOk) {
            if (in.valueCoins < PROXY_MIN_STORAGE * 2) {
                // Something extreeme happend and the whole stake is slashed
                // Make sure at least something reaches the pool, even at storage expense
                outValue = max(in.valueCoins, ton("0.1"));
                outMode = SEND_MODE_PAY_FEES_SEPARATELY;
            } else {
                // Replenish
                reserveGramsOnBalance(PROXY_MIN_STORAGE, RESERVE_MODE_AT_MOST);
                outMode = SEND_MODE_CARRY_ALL_BALANCE;
            }
        }
        // Fall through for the other message types
        proxyMsg(poolAddr, proxyResponse, outMode, outValue, false);
    } else {
        val wrongSenderRefund = createMessage({
            bounce: false,
            value: 0,
            dest: in.senderAddress,
            body: ProxyRefundWrongSender { queryId: 0 },
        });
        wrongSenderRefund.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
    }
}
