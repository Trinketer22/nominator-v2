import "@contracts/errors"

const SHARE_BASE = 256 * 256 * 256

enum ValidatorState {
    NoTonUsed = 0
    AwaitingStakeConfirmation
    AwaitingStakeRecovery
}

struct Nominator {
    share: coins
    tonAmount: coins
    pendingDeposit: coins = 0
    pendingWithdrawal: coins = 0
    withdrawalIndex: uint64 = 0
}

struct NominatorsSettings {
    maxNominators: uint10
    minStake: coins
    minWithdrawableRewards: coins
}

struct ValidatorInitSettings {
    maxTonPerValidator: coins
    minTonPerValidator: coins
    mainValidatorAddress: address
    maxRefund: coins
}

struct RoundInfo {
    used: coins = 0
    returned: coins = 0
    roundIndex: uint64
}

struct RoundData {
    used: coins = 0
    returned: coins = 0
    roundIndex: uint64
    users: map<address, TonUsage> = []
}

struct (0x12) CurrentVsetParsed {
    utimeSince: uint32
    utimeUntil: uint32
}

struct CurrentVset {
    utimeSince: uint32
    utimeUntil: uint32
    vsetHash: int
}

struct ValidatorsData {
    mainValidatorAddress: address
    vsetHash: uint128
    mainValidatorData: Cell<Validator>
    // 127 validators will fit
    activeValidators: uint8 = 1
    activeSlots: uint9 = 0
    stakeUsed: coins = 0
    minTonPerValidator: coins
    maxTonPerValidator: coins
    maxRefundAmount: coins = ton("5")
    validators: map<address, Validator> = []
    curRound: Cell<RoundData>
    prevRound: Cell<RoundData>
}

struct ValidatorLimitTon {
    maxTon: coins
}

struct ValidatorLimitShare {
    maxShare: uint25
}

type ValidatorLimit = ValidatorLimitTon | ValidatorLimitShare

struct GlobalValidatorsLimit {
    minTonPerValidator: coins
    maxTonPerValidator: coins
    maxRefund: coins
}

struct GlobalNominatorsLimit {
    minStake: coins
    maxNm: uint10
}

struct ValidatorSpecific {
    validator: address
    limit: ValidatorLimit
}

enum RoundAllowance {
    InOddRounds = 1
    InEvenRounds = 2
    InAllRounds = 3
}

struct RotationData {
    vsetHash: uint256
    rotationTime: uint32
    rotationCount: uint8 = 0
}

struct Validator {
    isBanned: bool = false
    usageState: uint2
    evenProxy: address? = null
    oddProxy: address? = null
    limit: ValidatorLimit? = null
    refundAmount: coins
    roundParity: RoundAllowance = RoundAllowance.InAllRounds
}

struct ValidatorLookup {
    isMain: bool
    data: Validator
}

struct UsageLookup {
    isCurrentRound: bool
    data: TonUsage
    round: RoundData
}

struct Distribution {
    pendingShare: coins = 0
    pendingCoins: coins = 0
}

struct PendingOps {
    cur: address? = null
    prev: address? = null
    next: address? = null
    nextStateInit: Cell<StateInit>? = null
    index: uint64 = 0
    isWithdraw: bool
    pendingAmount: coins = 0
}

struct PendingOpsCtx {
    balance: coins
    supply: coins
}

struct PendingProcessingResult {
    withdrawn: coins
    deposited: coins
    halted: bool
}

struct NominatorsData {
    nmCount: uint16 = 0
    minStake: coins
    minWithdrawableReward: coins
    poolNominators: map<address, Nominator> = []
    pendingDeposits: Cell<PendingOps>? = null
    pendingWithdrawals: Cell<PendingOps>? = null
}

struct TonUsage {
    heldFor: uint32
    tonUsed: coins
    validator: address
    rotation: RotationData
}

struct GetValidatorInfo {
    validator: Validator
    usage: ValidatorUsageRecords
    stakeable: coins
}

struct ValidatorUsageStats {
    proxy: address
    usage: TonUsage
}

struct ValidatorUsageRecords {
    curRoundUsage: ValidatorUsageStats?
    prevRoundUsage: ValidatorUsageStats?
}

struct (0b0) PoolStorageNotInitialized {
    owner: address
    poolId: uint32
}

fun PoolStorageNotInitialized.load(): PoolStorageNotInitialized {
    return PoolStorageNotInitialized.fromCell(
        contract.getData(),
        { throwIfOpcodeDoesNotMatch: ErrorsPool.AlreadyInitialized },
    );
}

struct (0b1) Storage {
    owner: address
    poolId: uint32 = 0
    halted: bool = false
    ownerShare: uint25
    poolSupply: coins = 0
    roundClosed: bool = false
    roundIndex: uint64 = 0
    validators: Cell<ValidatorsData>
    nominators: Cell<NominatorsData>
    maxNominators: uint10
    nominatorsAmount: coins = 0
    pendingDeposits: coins = 0
    pendingWithdrawals: coins = 0
}

type PoolStorage = PoolStorageNotInitialized | Storage

struct WithdrawalStatus {
    pendingWithdrawals: Cell<PendingOps>?
}

struct GetNominatorData {
    amount: coins               // Total ton amount,
    pendingDepositAmount: coins // Total ton amount
    withdrawFound: bool         // Wether there is pending withdrawal registered
    reward: coins
}

struct GetMinStake {
    minStake: coins
    minExpectedValue: coins
}

// https://github.com/ton-blockchain/ton/blob/master/crypto/block/block.tlb#L801-L808
struct (0x01) PushishmentConfig {
    defaultFlatFine: coins
    defaultProportionalFine: uint32
    severityFlatMult: uint16
    severityProportinalMult: uint16
    unpunishableInterval: uint16
    longInterval: uint16
    longFlatMult: uint16
    longProportinalMult: uint16
    mediumInterval: uint16
    mediumFlatMult: uint16
    mediumProportionalMult: uint16
}

struct ValidatorSignature {
    signature: bits512
}

fun Storage.load(): Storage {
    return Storage.fromCell(
        contract.getData(),
        { throwIfOpcodeDoesNotMatch: ErrorsPool.PoolStorageNotInitialized },
    );
}

fun PoolStorage.load(): PoolStorage {
    return PoolStorage.fromCell(
        contract.getData(),
    );
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

struct ProxyStorage {
    roundParity: bool
    pool: address
    validator: address
}

struct StaticData {
    pool: address
    roundIndex: uint64
    index: uint64
    isWithdrawal: bool
    prev: address?
    next: address?
}

struct (0b1) ItemStorageInitialized {
    owner: address
    data: Cell<StaticData>
}

struct PayoutItemInfo {
    owner: address?
    data: StaticData
}

struct (0b0) ItemStorageNotInitialized {
    data: StaticData
}

struct RefundContext {
    queryId: uint64 = 0
    op: uint32
    errorCode: uint32
    additionalCtx: cell? = null
}

struct GetProxyAddressResult {
    evenRounds: address?
    oddRounds: address?
}

struct RotationStatus {
    roundRotated: bool
    roundIsClosed: bool
    prevRoundInfo: RoundInfo?
}
