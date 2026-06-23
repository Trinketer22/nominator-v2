import "@acton/build"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/messages"
import "@contracts/types"
import "@tests/elector-utils"
import "@wrappers/Pool.gen"

fun setupDeployedPool(): (Pool, Treasury, Treasury, address) {
    val deployer = testing.treasury("deployer");
    val notDeployer = testing.treasury("notDeployer");
    val mainValidator = randomAddress("validator", MASTERCHAIN);

    val contract = Pool.fromStorage(PoolStorageNotInitialized {
        owner: deployer.address,
        poolId: 42,
    });

    val deployMsg = defaultDeployMessage(deployer.address, 42, ton("10000"));

    val res = net.send(deployer.address, deployMsg);
    expect(res).toHaveSuccessfulDeploy({ to: contract.address });

    return (contract, deployer, notDeployer, mainValidator);
}

fun defaultDeployParams(): (int, ValidatorInitSettings, NominatorsSettings) {
    val validator = randomAddress("validator", MASTERCHAIN);
    val validatorSettings: ValidatorInitSettings = {
        maxTonPerValidator: ton("1000000"),
        minTonPerValidator: DEFAULT_MIN_STAKE,
        mainValidatorAddress: validator,
        maxRefund: ton("3"),
    };

    val nmSettings = NominatorsSettings {
        maxNominators: 1023,
        minStake: ton("1000"),
        minWithdrawableRewards: ton("1"),
    };

    return (SHARE_BASE / 2, validatorSettings, nmSettings);
}

fun defaultDeployBody(): InitPoolMessage {
    val (share, validatorSettings, nmSettings) = defaultDeployParams();

    return InitPoolMessage {
        queryId: 0,
        ownerShare: share,
        maxTonPerValidator: validatorSettings.maxTonPerValidator,
        minTonPerValidator: validatorSettings.minTonPerValidator,
        mainValidator: validatorSettings.mainValidatorAddress,
        limit: null,
        maxRefund: validatorSettings.maxRefund,
        nominatorsSettings: nmSettings.toCell(),
    };
}

fun getPoolStateInit(owner: address, poolId: int): AutoDeployAddress {
    val poolStateInit: AutoDeployAddress = {
        stateInit: {
            data: PoolStorageNotInitialized { owner, poolId }.toCell(),
            code: build("Pool"),
        },
    };

    return poolStateInit;
}

fun defaultDeployMessage(owner: address, poolId: int, value: int): OutMessage {
    val poolStateInit = getPoolStateInit(owner, poolId);
    return createMessage({
        bounce: false,
        dest: poolStateInit,
        value,
        body: defaultDeployBody(),
    });
}

fun deployPoolWith(owner: address, poolId: int, value: int, msg: InitPoolMessage): Pool {
    val poolStateInit = getPoolStateInit(owner, poolId);
    val res = net.send(
        owner,
        createMessage({
            bounce: false,
            dest: poolStateInit,
            value,
            body: msg,
        }),
    );
    expect(res).toHaveSuccessfulDeploy<InitPoolMessage>();
    return Pool.fromAddress(poolStateInit.calculateAddress());
}

fun setupDeployTest(): (Pool, Treasury, Treasury, address) {
    val deployer = testing.treasury("deployer");
    val notDeployer = testing.treasury("notDeployer");
    val mainValidator = randomAddress("validator", MASTERCHAIN);

    val contract = Pool.fromStorage(PoolStorageNotInitialized {
        owner: deployer.address,
        poolId: 42,
    });

    return (contract, deployer, notDeployer, mainValidator);
}
