import "@stdlib/reflection"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"
import "@acton/testing/fuzz"

import "@contracts/errors"
import "@contracts/fees"
import "@contracts/messages"
import "@contracts/messages"
import "@contracts/types"
import "@wrappers/Pool.gen"
import "deploy-utils"
import "proxy-utils.tolk"

@test.fuzz(20)
get fun `test should deploy with specified parameters`(
    maxTon: coins,
    minTon: coins,
    minStake: coins,
    minReward: coins,
    refund: coins,
    ownerShare: int,
    maxNominators: int,
) {
    fuzz.assume(minTon < maxTon);

    val (pool, deployer, _notOwnerr, validator) = setupDeployTest();

    expect(testing.isDeployed(pool.address)).toBeFalse();

    val boundedNm = fuzz.bound(maxNominators, 1, 1023);
    val boundedShare = fuzz.bound(ownerShare, 0, (1 << 24) - 1);
    val deployMsg = createMessage({
        dest: { stateInit: pool.stateInit! },
        value: ton("1000"),
        bounce: false,
        body: InitPoolMessage {
            queryId: 0,
            ownerShare: boundedShare,
            maxTonPerValidator: maxTon,
            minTonPerValidator: minTon,
            mainValidator: validator,
            limit: null,
            maxRefund: refund,
            nominatorsSettings: NominatorsSettings {
                maxNominators: boundedNm,
                minStake,
                minWithdrawableRewards: minReward,
            }.toCell(),
        },
    });

    val res = net.send(deployer.address, deployMsg);

    expect(res).toHaveSuccessfulTx({
        to: pool.address,
        from: deployer.address,
        opcode: reflect.serializationPrefixOf<InitPoolMessage>().0,
        aborted: false,
    });
    expect(res).toHaveSuccessfulDeploy({ to: pool.address });
    // Check for proxy deployment
    val proxyOdd = getProxy(pool.address, validator, false);
    val proxyEven = getProxy(pool.address, validator, true);

    expect(res).toHaveSuccessfulTx({ from: proxyOdd.address, to: deployer.address });
    expect(res).toHaveSuccessfulTx({ from: proxyEven.address, to: deployer.address });

    expect(res).toHaveSuccessfulTx({ from: pool.address, to: proxyOdd.address });
    expect(res).toHaveSuccessfulTx({ from: pool.address, to: proxyEven.address });

    expect(res).toHaveSuccessfulTx({ from: pool.address, to: deployer.address });

    val poolAfter = pool.getPoolData();
    expect(poolAfter.ownerShare).toEqual(boundedShare);

    val validatorsAfter = poolAfter.validators.load();
    expect(validatorsAfter.mainValidatorAddress).toEqual(validator);

    expect(validatorsAfter.maxTonPerValidator).toEqual(maxTon);
    expect(validatorsAfter.minTonPerValidator).toEqual(minTon);
    expect(validatorsAfter.maxRefundAmount).toEqual(refund);

    val nominatorsAfter = poolAfter.nominators.load();
    expect(poolAfter.maxNominators).toEqual(boundedNm);
    expect(nominatorsAfter.minStake).toEqual(minStake);
    expect(nominatorsAfter.minWithdrawableReward).toEqual(minReward);
}

get fun `test should reject low value in case maxNominators > 0 and values is not enough to cover validator fine`() {
    val (pool, owner, _NotOwner, validator) = setupDeployTest();

    val testVal = POOL_MIN_STORAGE + PROXY_MIN_STORAGE * 2 + ton("1");

    var res = net.send(owner.address, defaultDeployMessage(owner.address, 42, testVal));

    expect(res).toHaveFailedTx({ to: pool.address, exitCode: ErrorsPool.NotEnoughGas });

    // Default fine is currently 101 TON
    val fine = ton("101") * 2; // Default fine * 2 rounds
    res = net.send(owner.address, defaultDeployMessage(owner.address, 42, testVal + fine - 1));

    expect(res).toHaveFailedTx({ to: pool.address, exitCode: ErrorsPool.NotEnoughGas });

    res = net.send(owner.address, defaultDeployMessage(owner.address, 42, testVal + fine));

    expect(res).toHaveSuccessfulTx({ to: pool.address });
    // Check for proxy deployment
    val proxyOdd = getProxy(pool.address, validator, false);
    val proxyEven = getProxy(pool.address, validator, true);

    expect(res).toHaveSuccessfulTx({ from: proxyOdd.address, to: owner.address });
    expect(res).toHaveSuccessfulTx({ from: proxyEven.address, to: owner.address });
}

@test.fuzz(20)
get fun `test should only allow init from the owner address`(
    maxTon: coins,
    minTon: coins,
    minStake: coins,
    minReward: coins,
    refund: coins,
    ownerShare: int,
    maxNominators: int,
) {
    fuzz.assume(minTon < maxTon);

    val (pool, deployer, notOwner, validator) = setupDeployTest();

    val poolStateInit = getPoolStateInit(deployer.address, 42);

    expect(testing.isDeployed(pool.address)).toBeFalse();

    val boundedNm = fuzz.bound(maxNominators, 0, 1023);
    val boundedShare = fuzz.bound(ownerShare, 0, (1 << 24) - 1);
    val deployMsg = createMessage({
        dest: poolStateInit,
        value: ton("100"),
        bounce: false,
        body: InitPoolMessage {
            queryId: 0,
            ownerShare: boundedShare,
            maxTonPerValidator: maxTon,
            minTonPerValidator: minTon,
            mainValidator: validator,
            limit: null,
            maxRefund: refund,
            nominatorsSettings: NominatorsSettings {
                maxNominators: boundedNm,
                minStake,
                minWithdrawableRewards: minReward,
            }.toCell(),
        },
    });

    val res = net.send(notOwner.address, deployMsg);
    expect(res).toHaveFailedTx({ to: pool.address, exitCode: ErrorsPool.NotOwner });
}

get fun `test should not allow to init pool with maxTonPerValidator < minTonPerValidator`() {
    val (pool, owner, _notOwner, _validator) = setupDeployTest();

    var deployMsg = defaultDeployBody();
    deployMsg.minTonPerValidator = deployMsg.maxTonPerValidator + 1;

    val res = net.send(
        owner.address,
        createMessage({
            bounce: false,
            dest: { stateInit: pool.stateInit! },
            value: ton("100"),
            body: deployMsg,
        }),
    );
    expect(res).toHaveFailedTx({
        to: pool.address,
        exitCode: ErrorsPool.InvalidMaxMin,
    });
}

get fun `test should not allow to init the pool twice`() {
    val (pool, deployer, _notOwner, _validator) = setupDeployedPool();

    val _poolBefore = pool.getPoolData();

    val res = net.send(
        deployer.address,
        defaultDeployMessage(deployer.address, 42, ton("100")),
    );

    expect(res).toHaveFailedTx({ to: pool.address, exitCode: ErrorsPool.AlreadyInitialized });
}
