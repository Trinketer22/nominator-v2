import "@acton/env"
import "@acton/fmt"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"

import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

// Collects whitelist entries from WHITELIST_0, WHITELIST_1, ... env vars.
// If none are set, falls back to an interactive prompt loop. The user is asked
// whether to add an address; an empty input ends the loop. Setting
// WHITELIST_CLEAR=1 (or answering "no" to the first add prompt) produces an
// empty whitelist, which clears the on-chain restriction.
fun collectWhitelist(): map<address, bool> {
    var wl: map<address, bool> = [];

    // Env path: WHITELIST_0, WHITELIST_1, ...
    var hasEnv = false;
    var i = 0;
    var envDone = false;
    while (!envDone) {
        val name = format("WHITELIST_{}", i);
        val addr = env<address>(name);
        if (addr == null) {
            envDone = true;
        } else {
            hasEnv = true;
            wl.set(addr, true);
            i += 1;
        }
    }
    if (hasEnv) {
        return wl;
    }

    // Interactive path
    if (env<bool>("WHITELIST_CLEAR") ?? false) {
        return wl;
    }

    var interactiveDone = false;
    while (!interactiveDone) {
        val add = confirm(
            "Add an address to the nominators whitelist?",
            true,
            "Answer 'no' to finish and apply the list.",
        );
        if (!add) {
            interactiveDone = true;
        } else {
            val addr = promptAddress(
                "Whitelist entry (TON address):",
                null,
                "EQ... / kQ... / Ef... / kf...",
            );
            wl.set(addr, true);
        }
    }
    return wl;
}

fun main() {
    val poolAddress = promptPoolAddress();
    val pool = loadPool(poolAddress);
    val owner = poolOwner();

    val whitelist = collectWhitelist();
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;
    val value = promptCoins(
        "MSG_VALUE",
        "Value to send with UpdateNominatorsWhitelist (TON):",
        "1",
    );

    val count = whitelist.isEmpty() ? 0 : 1;
    println(
        "Updating nominators whitelist: {} entr{}",
        count,
        count == 1 ? "y" : "ies",
    );

    var wlSummary = "  entries:";
    if (whitelist.isEmpty()) {
        wlSummary = format("{} (clearing whitelist)", wlSummary);
    } else {
        var wlIter = whitelist.findFirst();
        while (wlIter.isFound) {
            wlSummary = format("{}\n    {}", wlSummary, wlIter.getKey());
            wlIter = whitelist.iterateNext(wlIter);
        }
    }

    confirmSend(
        format(
            "Update nominators whitelist\n  pool:  {}\n{}",
            pool.address,
            wlSummary,
        ),
    );

    val res = pool.sendUpdateNominatorsWhitelist(
        owner.address,
        queryId,
        whitelist,
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("UpdateNominatorsWhitelist message was not accepted by network");
    }

    val poolAfter = pool.getPoolData();
    val nominatorsAfter = lazy poolAfter.nominators.load();
    val storedWl = nominatorsAfter.nominatorsWhitelist;

    // Verify each env-supplied entry is present (we cannot iterate a Tolk map,
    // so the interactive path is verified only by the contract accepting the tx).
    var j = 0;
    var verifyDone = false;
    while (!verifyDone) {
        val name = format("WHITELIST_{}", j);
        val addr = env<address>(name);
        if (addr == null) {
            verifyDone = true;
        } else {
            if (!storedWl.exists(addr)) {
                Assert.fail(
                    format("Whitelist entry {} ({}) was not stored on the pool", name, addr),
                );
            }
            j += 1;
        }
    }

    if (whitelist.isEmpty()) {
        if (!storedWl.isEmpty()) {
            Assert.fail("Whitelist was expected to be cleared but is non-empty on the pool");
        }
        println("OK: nominators whitelist cleared on pool {}", pool.address);
    } else {
        if (storedWl.isEmpty()) {
            Assert.fail("Whitelist was expected to be non-empty but is cleared on the pool");
        }
        println("OK: nominators whitelist updated on pool {}", pool.address);
    }

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
