import "@stdlib/reflection"
import "@acton/build"
import "@acton/crypto"
import "@acton/emulation/config"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/assert"
import "@acton/testing/expect"
import "@acton/tlb/maybe"
import "@acton/types/message"
import "@acton/types/transaction"
import "@contracts/Elector.types"
import "@contracts/config"
import "@contracts/messages"
import "@contracts/types"
import "@wrappers/ElectorCode.gen"

const PARTICIPANTS_IDX = 16
const STAKES_IDX = 17
const CUR_VSET_IDX = 34
const NEXT_VSET_IDX = 36
const DEFAULT_MIN_STAKE = ton("10000")

struct (0x8e81278a) VPublicKey {
    pubkey: bits256
}

struct (0x53) ValidatorDescr {
    pubkey: VPublicKey
    weight: uint64
}

struct (0x12) ValidaorSet {
    utimeSince: uint32
    utimeUntil: uint32
    total: uint16
    main: uint16
    totalWeight: uint64
    list: map<uint16, ValidatorDescr>
}

struct ParticipantsConfig {
    maxValidaotrs: uint16
    maxMain: uint16
    minValidators: uint16
}

struct StakesConfig {
    minStake: coins
    maxStake: coins
    minTotalStake: coins
    maxStakeFactor: uint32
}

struct (0x4e565354) UpdateNextVset {
    queryId: uint64
    nextVset: Cell<ValidaorSet>
}

fun setupSimplifiedElections(): (StakesConfig, ParticipantsConfig) {
    var config = testing.getConfig();
    var stakeConfig = StakesConfig.fromCell(config.getParamRaw(STAKES_IDX));
    var electionsConf = ParticipantsConfig.fromCell(config.getParamRaw(PARTICIPANTS_IDX));
    electionsConf.minValidators = 5;
    electionsConf.maxValidaotrs = 5;
    electionsConf.maxMain = 1;
    stakeConfig.minStake = DEFAULT_MIN_STAKE;
    stakeConfig.minTotalStake = stakeConfig.minStake;

    config.set(STAKES_IDX, stakeConfig.toCell());
    config.set(PARTICIPANTS_IDX, electionsConf.toCell());
    testing.setChecksigIgnore(true);
    testing.setConfig(config);

    return (stakeConfig, electionsConf);
}

fun getConfigAddress(): address {
    val config = testing.getConfig();
    val configHash = config.getParamRaw(0).beginParse().loadUint(256);
    return address.fromWorkchainAndHash(MASTERCHAIN, configHash);
}

fun updateVsetHash(elector: address? = null): uint256 {
    var config = testing.getConfig();
    var currentVset = ValidaorSet.fromCell(config.getParamRaw(CUR_VSET_IDX));

    currentVset.utimeUntil += 1;
    val vsetCell = currentVset.toCell();
    config.setParamRaw(CUR_VSET_IDX, vsetCell);
    testing.setConfig(config);
    if (elector != null) {
        testing.runTickTock(elector, true);
        testing.runTickTock(elector, false);
    }
    return vsetCell.hash();
}

fun runElections(
    elector: ElectorCode,
    stakes: StakesConfig,
    participants: ParticipantsConfig,
    reward: coins = ton("1000"),
): SendResultList {
    val configAddress = getConfigAddress();
    val minStake = stakes.minStake + ton("1");
    val factor = 1 << 16;
    val elections = elector.activeElectionId();
    // println(testing.getNow());
    // println("Before the loop", random.uint256());
    var i = 0;
    repeat (participants.minValidators) {
        // var newAddress = randomAddress(null, MASTERCHAIN);
        val newAddress = address.fromWorkchainAndHash(
            MASTERCHAIN,
            crypto.getSecureRandomBytes(32).loadUint(256),
        );
        val pubKey = random.uint256(); //crypto.getSecureRandomBytes(32).loadUint(256);
        // println("In the loop:", pubKey);
        val res = net.send(
            newAddress,
            createMessage({
                bounce: true,
                value: minStake,
                dest: elector.address,
                body: NewStakeDirect {
                    queryId: 1,
                    publicKey: pubKey,
                    stakeAt: elections,
                    maxFactor: factor,
                    adnl: 0,
                    signature: ValidatorSignature {
                        signature: crypto.getFastRandomBytes(64) as bits512,
                    }.toCell(),
                },
            }),
        );
        expect(res).toHaveSuccessfulTx({
            to: elector.address,
            from: newAddress,
            opcode: reflect.serializationPrefixOf<NewStake>().0,
        });
        i += 1;
    }
    testing.setNow(elections);
    val res = testing.runTickTock(elector.address, true);
    val vsetUpdateTx = res.findTransaction({ to: configAddress, from: elector.address });
    expect(vsetUpdateTx == null).toBeFalse();
    val nextVsetMsg = vsetUpdateTx!.loadBody<UpdateNextVset>();
    setNextVset(nextVsetMsg.nextVset);
    testing.runTickTock(elector.address, false);
    rotateVset(elector.address, reward);
    return res;
}

fun setupElector(): (ElectorCode, StakesConfig, ParticipantsConfig) {
    val electorAddress = address("Ef8zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM0vF");
    val (stakes, participantsLimits) = setupSimplifiedElections();
    setExpiredVset(testing.getConfig());

    testing.setShardAccount(
        electorAddress,
        TlbShardAccount {
            account: (TlbAccountInfo {
                addr: electorAddress,
                storage: TlbAccountStorage {
                    lastTransLt: 0,
                    balance: TlbCurrencyCollection {
                        grams: ton("1000000"),
                        other: [],
                    },
                    state: TlbAccountStateActive {
                        stateInit: {
                            fixedPrefixLength: null,
                            special: (true, true),
                            library: null,
                            code: build("Elector"),
                            data: ElectorStorage {
                                activeHash: testing.getConfig().mustGet(CUR_VSET_IDX, 42)!.hash(),
                            }.toCell(),
                        },
                    },
                },
                storageStat: TlbStorageInfo {
                    used: TlbStorageUsed {
                        cells: 10,
                        bits: 1024,
                    },
                    storageExtra: TlbStorageExtraNone {},
                    lastPaid: 0,
                    duePayment: TlbNone {},
                },
            } as TlbAccount).toCell(),
            lastTransHash: 0,
            lastTransLt: 0,
        },
    );

    return (ElectorCode.fromAddress(electorAddress), stakes, participantsLimits);
}

fun setExpiredVset(config: BlockchainConfigMap) {
    val curVset = ValidaorSet.fromCell(config.getParamRaw(CUR_VSET_IDX)!);
    val electionTiming = getElectionsTiming();
    testing.setNow(curVset.utimeUntil - electionTiming.endBefore - 100);
}

fun rotateVset(elector: address, reward: int) {
    var config = testing.getConfig();
    val nextSet = config.getParamRaw(NEXT_VSET_IDX);
    val parsed = ValidaorSet.fromCell(nextSet);
    testing.setNow(parsed.utimeSince);
    testing.runTickTock(elector, false);
    config.delete(NEXT_VSET_IDX);
    config.setParamRaw(CUR_VSET_IDX, nextSet);
    testing.setConfig(config);
    sendElectorReward(elector, reward);
    // Should trigger unfreeze
    testing.runTickTock(elector, true);
}

fun setNextVset(next: ValidaorSet | Cell<ValidaorSet>) {
    var config = testing.getConfig();
    val nextSet: Cell<ValidaorSet> = match (next) {
        Cell<ValidaorSet> => next,
        ValidaorSet => next.toCell(),
    };
    config.set(NEXT_VSET_IDX, nextSet);
    testing.setConfig(config);
}

fun clearNextValidators() {
    var config = testing.getConfig();
    config.delete(NEXT_VSET_IDX);
    testing.setConfig(config);
}

fun announceElections(elector: ElectorCode): int {
    setExpiredVset(testing.getConfig());
    clearNextValidators();
    var activeElections = elector.activeElectionId();
    var tryCount = 3;
    while (activeElections == 0 && tryCount > 0) {
        testing.runTickTock(elector.address, true);
        activeElections = elector.activeElectionId();
        tryCount -= 1;
    }

    if (tryCount == 0) {
        Assert.fail("Failed to announce elections!");
    }
    return activeElections;
}

fun getSignedBody(
    elections: int,
    publicKey: uint256? = null,
    adnl: uint256? = null,
    factor: uint32? = null,
    signature: slice? = null,
): slice {
    return getSignedCell(elections, publicKey, adnl, factor, signature).beginParse();
}

fun getSignedCell(
    elections: int,
    publicKey: uint256? = null,
    adnl: uint256? = null,
    factor: uint32? = null,
    signature: slice? = null,
): Cell<NewStakeBody> {
    if (publicKey == null) {
        publicKey = random.uint256();
    }
    if (adnl == null) {
        adnl = random.uint256();
    }
    if (factor == null) {
        factor = (1 << 16);
    }
    if (signature == null) {
        signature = crypto.getFastRandomBytes(64);
    }
    return NewStakeBody {
        publicKey,
        stakeAt: elections,
        maxFactor: factor,
        adnl,
        signature: ValidatorSignature { signature: signature as bits512 }.toCell(),
    }.toCell();
}

fun sendElectorReward(elector: address, value: coins = ton("1000000")) {
    val zeroAddress = address.fromWorkchainAndHash(MASTERCHAIN, 0);
    net.send(
        zeroAddress,
        createMessage({
            bounce: false,
            value,
            dest: elector,
        }),
    );
}
