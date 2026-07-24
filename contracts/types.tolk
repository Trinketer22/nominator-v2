import "@contracts/errors"

const SHARE_BASE = 256 * 256 * 256
const ROUNDS_DELAY = 3
const MAX_NM_DEPTH = 15
const MAX_VALIDATORS = 32

struct Nominator {
    share: coins
    tonAmount: coins
    pendingDeposit: coins = 0
    pendingWithdrawal: coins = 0
    depositIndex: uint64 = 0
    withdrawalIndex: uint64 = 0
}

struct NominatorsSettings {
    maxNominators: uint10
    minStake: coins
    minWithdrawableRewards: coins
    whitelist: map<address, bool> = []
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
    users: map<uint256, TonUsage> = []
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
    // 32 validators will fit
    activeValidators: uint6 = 1
    activeSlots: uint7 = 0
    stakeUsed: coins = 0
    minTonPerValidator: coins
    maxTonPerValidator: coins
    maxRefundAmount: uint33 = ton("5") as int
    refundBonus: uint33 = ton("1") as int
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
    maxRefund: uint33
    refundBonus: uint33
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
    evenProxy: uint256? = null
    oddProxy: uint256? = null
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
    nominatorsWhitelist: map<address, bool> = []
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
    roundIndex: uint64
    rotated: bool
}

struct ValidatorUsageStats {
    proxy: uint256
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
struct (0x01) PunishmentConfig {
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

// Audit/diagnostic result for get_pool_invariants.
// Recomputes cached aggregates from the primary nominator map and reports
// whether they match the stored aggregates. No assertion — reports only.
//
// Share lifecycle note: pending-withdrawal shares are deducted from
// nominator.share at request time but remain counted in poolSupply until
// PayoutBurnNotification burns them. Thus:
//   poolSupply == sum(nominator.share) + sum(nominator.pendingWithdrawal)
// not  poolSupply == sum(nominator.share).
//
// nominatorsAmount has no non-tautological invariant (it is a primary state
// variable, moved globally by profit/loss at RecoverStakeOk with no
// per-nominator mirror), so it is exposed alongside the independent balance
// projection for off-chain solvency monitoring rather than checked.
struct PoolInvariants {
    // Real invariants — recomputed from nominator map, compared to stored aggregates
    supplyMatch: bool             // sum(share) + sum(pendingWithdrawal) == poolSupply
    pendingWithdrawalsMatch: bool // sum(pendingWithdrawal) == storage.pendingWithdrawals
    pendingDepositsMatch: bool    // sum(pendingDeposit) == storage.pendingDeposits
    nmCountMatch: bool            // count(nominators) == nominators.nmCount
    allMatch: bool                // AND of the four above

    // Transparency pair for off-chain solvency monitoring
    nominatorsAmount: coins
    projectedBalance: coins // balance + stakeUsed - pendingDeposits - POOL_MIN_STORAGE

    // Recomputed values for debugging / monitoring
    recomputedSupply: coins
    recomputedPendingWithdrawals: coins
    recomputedPendingDeposits: coins
    recomputedNmCount: int
    recomputedTonAmount: coins // sum(nominator.tonAmount) (deposit-time baselines)
}
