import "@acton/env"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"

import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

fun main() {
    // Deployment = sending the contract code + initial data (StateInit) to the
    // blockchain. Anybody can deploy; the owner initializes afterwards via
    // init-pool.tolk. The pool address is derived from (owner, poolId).

    val owner = promptAddressWithEnv(
        "OWNER_ADDRESS",
        "Pool owner address (who will initialize the pool):",
        null,
    );

    val poolId = promptIntWithEnvOrConst("POOL_ID", "Pool ID:", 0);
    val deployValue = promptCoins("DEPLOY_VALUE", "Deploy value (TON, covers storage):", "1");

    // SAFETY: poolId is range-checked above to be non-negative; uint32 range is implicit.
    val pool = Pool.fromStorage({
        owner,
        poolId: poolId as uint32,
    });

    println("Pool owner:   {}", owner);
    println("Pool address: {}", pool.address);

    if (scripts.isContractDeployed(pool.address)) {
        println("Pool is already deployed at {}", pool.address);
        // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
        // sees this transaction's effects. No-op under `--net`.
        saveEmulationSnapshot();
        return;
    }

    // The deployer wallet just pays for the deployment transaction.
    val walletName = env<string>("DEPLOYER_WALLET") ??
    promptWallet("Select a wallet to pay for deployment:");
    val deployer = scripts.wallet(walletName);

    println("Deploying from wallet: {} ({})", walletName, deployer.address);

    val deployMessage = createMessage({
        bounce: false,
        value: deployValue,
        dest: { stateInit: pool.stateInit! },
    });

    val res = net.send(deployer.address, deployMessage);
    if (res.waitForFirstTransaction() == null) {
        println("Deployment message was not accepted by network");
        return;
    }

    println("Pool deployed successfully at {}", pool.address);
    println("Value sent: {:gram}", deployValue);
    println("Next step: run init-pool to initialize the pool (must be sent by the owner).");

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
