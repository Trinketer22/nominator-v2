struct ElectionsTiming {
    electedFor: uint32
    startBefore: uint32
    endBefore: uint32
    stakeHeldFor: uint32
}

struct StakingLimits {
    minStake: coins
    maxStake: coins
    minTotal: coins
    maxFactor: uint32
}

struct ElectorAddress {
    hash: uint256
}

fun getElectionsTiming(): ElectionsTiming {
    return ElectionsTiming.fromCell(blockchain.configParam(15)!);
}

fun getElectorAddress(): address {
    return address.fromWorkchainAndHash(
        -1,
        ElectorAddress.fromCell(blockchain.configParam(1)!).hash,
    );
}

fun StakingLimits.load(): StakingLimits {
    return StakingLimits.fromCell(blockchain.configParam(17)!);
}
