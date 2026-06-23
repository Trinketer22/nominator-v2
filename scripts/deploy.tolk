import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"

import "@contracts/messages"
import "@contracts/types"
import "@wrappers/Pool.gen"

fun main() {
    val walletName = env<string>("DEPLOYER_WALLET") ?? "deployer";
    val deployer = scripts.wallet(walletName);

    val poolId = env<int>("POOL_ID") ?? 42;
    val deployValue = env<coins>("DEPLOY_VALUE") ?? ton("10000");

    val mainValidator = env<address>("MAIN_VALIDATOR") ??
    address.fromWorkchainAndHash(MASTERCHAIN, deployer.address.getWorkchainAndHash().1);
    assert(mainValidator.getWorkchain() == MASTERCHAIN, 100);

    val ownerShare = env<int>("OWNER_SHARE") ?? (SHARE_BASE / 2);
    val maxTonPerValidator = env<coins>("MAX_TON_PER_VALIDATOR") ?? ton("1000000");
    val minTonPerValidator = env<coins>("MIN_TON_PER_VALIDATOR") ?? ton("10000");
    val maxRefund = env<coins>("MAX_REFUND") ?? ton("3");

    val maxNominators = env<int>("MAX_NOMINATORS") ?? 1023;
    val minStake = env<coins>("MIN_STAKE") ?? ton("1000");
    val minWithdrawableRewards = env<coins>("MIN_WITHDRAWABLE_REWARDS") ?? ton("1");

    assert(poolId >= 0, 101);
    assert(ownerShare >= 0 && ownerShare <= SHARE_BASE, 102);
    assert(maxTonPerValidator > minTonPerValidator, 103);
    assert(maxNominators >= 0 && maxNominators <= 1023, 104);

    val pool = Pool.fromStorage({
        owner: deployer.address,
        poolId: poolId as uint32,
    });

    println("Deployer wallet: {} ({})", walletName, deployer.address);
    println("Pool address: {}", pool.address);

    if (scripts.isContractDeployed(pool.address)) {
        println("Pool is already deployed at {}", pool.address);
        return;
    }

    val deployMessage = createMessage({
        bounce: false,
        value: deployValue,
        dest: { stateInit: pool.stateInit! },
        body: InitPoolMessage {
            queryId: 0,
            mainValidator,
            roundAllowance: RoundAllowance.InAllRounds,
            limit: null,
            ownerShare: ownerShare as uint25,
            maxTonPerValidator,
            minTonPerValidator,
            maxRefund,
            nominatorsSettings: NominatorsSettings {
                maxNominators: maxNominators as uint10,
                minStake,
                minWithdrawableRewards,
            }.toCell(),
        },
    });

    val res = net.send(deployer.address, deployMessage);
    if (res.waitForFirstTransaction() == null) {
        println("Deployment message was not accepted by network");
        return;
    }

    val initOkTx = res.findTransaction<InitPoolSuccess>({
        from: pool.address,
        to: deployer.address,
    });

    if (initOkTx == null) {
        println("Pool deployment transaction exists but InitPoolSuccess was not observed");
        return;
    }

    println("Pool deployed successfully at {}", pool.address);
    println("Main validator: {}", mainValidator);
    println("Owner share: {}/{}", ownerShare, SHARE_BASE);
    println("Value sent: {:gram}", deployValue);
}
