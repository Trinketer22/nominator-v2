import "@acton/env"
import "@acton/fmt"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/emulation/testing"
import "@acton/testing/assert"

import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

fun main() {
    val poolAddress = promptPoolAddress();
    val pool = loadPool(poolAddress);
    val owner = poolOwner();

    val value = promptCoinsRequired("VALUE", "Amount to add to the pool (TON):");
    val queryId = (env<int>("QUERY_ID") ?? 1) as uint64;

    println("Adding {:gram} to pool {}", value, pool.address);

    val balanceBefore = testing.getAccountBalance(pool.address);
    val poolBefore = pool.getPoolData();
    val nominatorsAmountBefore = poolBefore.nominatorsAmount;

    confirmSend(
        format(
            "Add funds\n  pool:   {}\n  amount: {:gram}",
            pool.address,
            value,
        ),
    );

    val res = pool.sendAddFunds(
        owner.address,
        queryId,
        { value },
    );

    if (res.waitForFirstTransaction() == null) {
        Assert.fail("AddFunds message was not accepted by network");
    }

    val balanceAfter = testing.getAccountBalance(pool.address);
    val poolAfter = pool.getPoolData();

    // AddFunds just accepts funds; pool balance must increase by roughly the sent value
    // (modulo storage fees and gas). Nominator accounting must not change.
    if (!(balanceAfter > balanceBefore)) {
        Assert.fail(
            format(
                "Pool balance did not increase after AddFunds (before={:gram}, after={:gram})",
                balanceBefore,
                balanceAfter,
            ),
        );
    }
    assertEqual(poolAfter.nominatorsAmount, nominatorsAmountBefore, "nominatorsAmount");
    assertEqual(poolAfter.poolSupply, poolBefore.poolSupply, "poolSupply");

    println(
        "OK: pool balance {:gram} -> {:gram} (+{:gram})",
        balanceBefore,
        balanceAfter,
        balanceAfter - balanceBefore,
    );
    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
