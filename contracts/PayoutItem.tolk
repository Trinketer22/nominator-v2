import "@stdlib/reflection"
import "@contracts/messages"
import "@contracts/types"
import "errors"

contract PayoutItem {
    author: "TON Core"
    version: "1.0.0"
    description: "Nominator payout bill contract"
    storage: ItemStorage
    storageAtDeployment: ItemStorageNotInitialized
}

const MIN_STORAGE: int = ton("0.04")
const BURN_NOTIFICATION_AMOUNT: int = ton("0.01")

type ItemStorage = ItemStorageNotInitialized | ItemStorageInitialized

type ItemMessages = PayoutInitMessage | PayoutBurnMessage

fun ItemStorage.load(): ItemStorage {
    return ItemStorage.fromCell(contract.getData());
}

fun ItemStorage.save(self) {
    contract.setData(self.toCell());
}

fun burnItem(sender: address, distribution: Distribution, queryId: int) {
    val storage = lazy ItemStorage.load();
    match (storage) {
        ItemStorageInitialized => {
            val staticData = storage.data.load();
            assert(sender == staticData.pool ||
            sender == staticData.prev!, ErrorsPayout.InvalidSender);
            if (staticData.next != null) {
                createMessage({
                    bounce: false,
                    value: BURN_NOTIFICATION_AMOUNT,
                    dest: staticData.next,
                    body: PayoutBurnMessage { queryId, distribution },
                }).send(SEND_MODE_PAY_FEES_SEPARATELY);
            }

            createMessage({
                bounce: false,
                value: 0,
                dest: staticData.pool,
                body: PayoutBurnNotification {
                    queryId,
                    owner: storage.owner,
                    isWithdrawal: staticData.isWithdrawal,
                    index: staticData.index,
                    roundIndex: staticData.roundIndex,
                    distribution,
                },
            }).send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_DESTROY);
        }
        ItemStorageNotInitialized => {
            throw 0xffff;
        }
    }
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy ItemMessages.fromSlice(in.body);

    match (msg) {
        PayoutInitMessage => {
            var storage = ItemStorage.load();
            assert(storage is ItemStorageNotInitialized, ErrorsPayout.AlreadyInitialized);
            assert(storage.data.pool == in.senderAddress, ErrorsPayout.InvalidSender);

            val storageInitialized: ItemStorageInitialized = {
                owner: msg.owner,
                data: ({
                    // Not really necessary, but for additional entropy sake
                    roundIndex: msg.roundIndex,
                    isWithdrawal: msg.isWithdrawal,
                    pool: storage.data.pool,
                    index: storage.data.index,
                    prev: msg.prev,
                    next: msg.next,
                } as StaticData).toCell(),
            };

            val updStorage: ItemStorage = storageInitialized;
            updStorage.save();

            reserveGramsOnBalance(MIN_STORAGE, RESERVE_MODE_AT_MOST);

            createMessage({
                bounce: false,
                dest: msg.owner,
                value: 0,
                body: RefundMessage {
                    context: {
                        op: reflect.serializationPrefixOf<PayoutInitMessage>().0,
                        queryId: msg.queryId,
                        errorCode: 0,
                    },
                },
            }).send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        PayoutBurnMessage => {
            burnItem(in.senderAddress, msg.distribution, msg.queryId);
        }
        else => {
            throw 0xffff;
        }
    }
}

get fun get_payout_info(): PayoutItemInfo {
    val storage = ItemStorage.load();
    return match (storage) {
        ItemStorageNotInitialized => PayoutItemInfo {
            owner: null,
            data: storage.data,
        },
        ItemStorageInitialized => PayoutItemInfo {
            owner: storage.owner,
            data: storage.data.load(),
        },
    };
}
