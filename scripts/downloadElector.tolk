import "@acton/fmt"

import "@acton/fs"
import "@acton/io"
import "@acton/emulation/scripts"
import "@acton/types/transaction"

fun main() {
    val savePath = "./elector-code.boc.hex";
    if (fs.exists(savePath)) {
        println("Elector code already exists");
        return;
    }
    val stateInfo = scripts.fetchAccountState(
        address("Ef8zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM0vF"),
    );
    assert(stateInfo != null, 42);
    val state = stateInfo.storage.state;
    assert(state is TlbAccountStateActive, 43);
    assert(state.stateInit.code != null, 44);
    val codeCell = state.stateInit.code!;
    val bocHex = format("{}", codeCell);
    assert(fs.writeString(savePath, bocHex), 48);
    println("Elector code BOC hex saved at", savePath);
}
