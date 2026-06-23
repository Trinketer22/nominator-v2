import "@stdlib/lisp-lists"
import "@acton/fmt"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/tlb/maybe"
import "@acton/types/message"
import "@acton/types/transaction"

const DEFAULT_QUERY_ID = 42
const DEFAULT_MSG_VALUE = ton("1")

fun getRandomValue(min: int, max: int): int {
    return random.range(max) + min;
}

fun getDifferentValue(initial: int, min: int, max: int): int {
    var newValue: int;
    do {
        newValue = random.range(max) + min;
    } while (newValue == initial);
    return newValue;
}

fun getDifferentAddress(initial: address): address {
    var newAddress: address;
    val workchain = initial.getWorkchain();
    do {
        newAddress = randomAddress(null, workchain);
    } while (newAddress == initial);

    return newAddress;
}

fun getTxComputePh(tx: TlbTransaction): TlbTrComputeVm {
    val description = tx.description.load();
    assert(description is TlbTransOrd, 842);
    val compute = description.computePh;

    assert(compute is TlbTrComputeVm, 43);
    return compute;
}

fun getTxActionPh(tx: TlbTransaction): TlbTrActionPhase {
    val description = tx.description.load();
    assert(description is TlbTransOrd, 842);
    val action = description.action;
    if (action !is TlbNone) {
        return action.value.load();
    }
    Assert.fail(format("Action phase not found in {}!", tx));
}

fun getTxStorage(tx: TlbTransaction): TlbTrStoragePhase {
    val description = tx.description.load();
    assert(description is TlbTransOrd, 842);
    val storage = description.storagePh;

    assert(storage !is TlbNone, 43);
    return storage.value;
}

fun getInternalMessageInfo(info: TlbCommonMessageInfo): TlbInternalMessage {
    if (info is TlbInternalMessage) {
        return info;
    }
    Assert.fail(format("Message {} is not internal", info));
}

fun getAccountData(address: address): cell {
    val accountState = testing.getAccountState(address)!;
    var data: cell;
    match (accountState.storage.state) {
        TlbAccountStateActive => {
            data = accountState.storage.state.stateInit.data!;
        }
        TlbAccountStateUninit => {
            Assert.fail(format("Account {} is not initialized!", address));
        }
        TlbAccountStateFrozen => {
            Assert.fail(format("Account {} is frozen!", address));
        }
    }
    return data;
}

fun getInternalMessageValue(info: TlbCommonMessageInfo): TlbCurrencyCollection {
    return getInternalMessageInfo(info).value;
}

fun lisp_list<T>.get(self, index: int): T {
    assert (index >= 0) throw 5;
    var list = self;
    var curElem = list.popHead();

    repeat (index) {
        curElem = list.popHead();
    }

    return curElem;
}
