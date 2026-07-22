import "@acton/env"
import "@acton/fmt"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@acton/testing/assert"

import "@contracts/messages"
import "@contracts/types"
import "@scripts/pool-utils"
import "@wrappers/Pool.gen"

fun main() {
    // Initialization = sending InitPoolMessage to an already-deployed (but
    // uninitialized) pool. Must be sent by the pool owner (the contract asserts
    // sender == storage.owner). Sets up the main validator, limits, and nominator
    // settings.

    val poolAddress = promptPoolAddress();
    val pool = loadPool(poolAddress);

    // The sender must be the owner. Use promptWallet to pick the owner's wallet.
    val walletName = env<string>("DEPLOYER_WALLET") ?? promptWallet("Select the owner wallet:");
    val owner = scripts.wallet(walletName);

    // Verify the wallet matches the pool's owner field.
    val poolOwnerAddr = pool.owner();
    if (owner.address != poolOwnerAddr) {
        Assert.fail(
            format(
                "Selected wallet {} does not match the pool owner {}. The init message must be sent by the owner.",
                owner.address,
                poolOwnerAddr,
            ),
        );
    }

    // Main validator address — no workchain restriction, no default.
    val mainValidator = promptAddressWithEnv(
        "MAIN_VALIDATOR",
        "Main validator address:",
        null,
    );

    val deployValue = promptCoins(
        "INIT_VALUE",
        "Init value (TON, covers proxies + reserve):",
        "250",
    );

    val ownerShare = promptIntWithEnvOrConst(
        "OWNER_SHARE",
        "Owner share (0..16777216):",
        SHARE_BASE / 2,
    );
    val maxTonPerValidator = promptCoins(
        "MAX_TON_PER_VALIDATOR",
        "Max TON per validator:",
        "10000000",
    );
    val minTonPerValidator = promptCoins(
        "MIN_TON_PER_VALIDATOR",
        "Min TON per validator:",
        "300000",
    );
    val maxRefund = promptCoins("MAX_REFUND", "Max refund to validator:", "5");
    val refundBonus = promptCoins("REFUND_BONUS", "Refund bonus to validator:", "1");

    val maxNominators = promptIntWithEnvOrConst(
        "MAX_NOMINATORS",
        "Max nominators (0..1023):",
        1023,
    );
    val minStake = promptCoins("MIN_STAKE", "Min nominator stake (TON):", "1000");
    val minWithdrawableRewards = promptCoins(
        "MIN_WITHDRAWABLE_REWARDS",
        "Min withdrawable rewards (TON):",
        "1",
    );

    if (ownerShare < 0 || ownerShare > SHARE_BASE) {
        Assert.fail(
            format(
                "Owner share {} is out of range (0..{})",
                ownerShare,
                SHARE_BASE,
            ),
        );
    }
    if (maxTonPerValidator <= minTonPerValidator) {
        Assert.fail(
            format(
                "Max TON per validator ({:gram}) must be greater than min TON per validator ({:gram})",
                maxTonPerValidator,
                minTonPerValidator,
            ),
        );
    }
    if (maxNominators < 0 || maxNominators > 1023) {
        Assert.fail(
            format(
                "Max nominators {} is out of range (0..1023)",
                maxNominators,
            ),
        );
    }

    println("Pool address:    {}", pool.address);
    println("Owner wallet:     {} ({})", walletName, owner.address);
    println("Main validator:   {}", mainValidator);
    println("Owner share:      {}/{}", ownerShare, SHARE_BASE);
    println("Init value:       {:gram}", deployValue);

    // SAFETY: ownerShare is range-checked above to fit uint25 (SHARE_BASE = 2^24 - 1).
    // SAFETY: maxNominators is range-checked above to fit uint10 (0..1023).
    val initMessage = createMessage({
        bounce: false,
        value: deployValue,
        dest: pool.address,
        body: InitPoolMessage {
            queryId: 0,
            mainValidator,
            roundAllowance: RoundAllowance.InAllRounds,
            limit: null,
            ownerShare: ownerShare as uint25,
            maxTonPerValidator,
            minTonPerValidator,
            maxRefund,
            refundBonus: refundBonus as uint33,
            nominatorsSettings: NominatorsSettings {
                maxNominators: maxNominators as uint10,
                minStake,
                minWithdrawableRewards,
            }.toCell(),
        },
    });

    val res = net.send(owner.address, initMessage);
    if (res.waitForFirstTransaction() == null) {
        Assert.fail("InitPoolMessage was not accepted by network");
    }

    val initOkTx = res.findTransaction<InitPoolSuccess>({
        from: pool.address,
        to: owner.address,
    });

    if (initOkTx == null) {
        Assert.fail("InitPoolMessage transaction exists but InitPoolSuccess was not observed");
    }

    println("Pool initialized successfully at {}", pool.address);

    // EMUL-TEST-ONLY: persist emulator state so the next `acton script` invocation
    // sees this transaction's effects. No-op under `--net`.
    saveEmulationSnapshot();
}
