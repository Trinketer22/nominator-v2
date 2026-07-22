import "types"

struct (0x73cb21e6) InitPoolMessage {
    queryId: uint64
    mainValidator: address
    roundAllowance: RoundAllowance = RoundAllowance.InAllRounds
    limit: ValidatorLimit?
    ownerShare: uint25
    maxTonPerValidator: coins
    minTonPerValidator: coins
    maxRefund: coins
    refundBonus: uint33
    nominatorsSettings: Cell<NominatorsSettings>
}

struct (0xd9478669) InitPoolSuccess {
    queryId: uint64
}

struct (0x00000000) TextComment {
    comment: RemainingBitsAndRefs
}

struct (0x64) DepositMessage {
    // "d"
}

struct (0x1d462054) DepositSuccess {
    queryId: uint64
}

struct (0x77) WithdrawalMessage {
    // "w"
}

struct (0x72) WithdrawalReward {
    // "r"
}

struct (0xac9a3b31) WithdrawSuccess {
    queryId: uint64
    totalStaked: coins
    returned: coins
    left: coins
}

struct (0x00000007) UpdateVset {
    queryId: uint64
}

struct (0x4e73744b) NewStake {
    queryId: uint64
    value: coins
    signedBody: RemainingBitsAndRefs
}

struct NewStakeBody {
    publicKey: uint256
    stakeAt: uint32
    maxFactor: uint32
    adnl: uint256
    signature: Cell<ValidatorSignature>
}

struct (0x4e73744b) NewStakeElector {
    queryId: uint64
    body: RemainingBitsAndRefs
}

struct (0x4e73744b) NewStakeDirect {
    queryId: uint64
    publicKey: uint256
    stakeAt: uint32
    maxFactor: uint32
    adnl: uint256
    signature: Cell<ValidatorSignature>
}

struct (0xf374484c) NewStakeOk {
    queryId: uint64
    answer: uint32
    remaining: RemainingBitsAndRefs
}

struct ProxyResponseData {
    validator: address
    parity: bool
}

struct (0xee6f454c) NewStakeError {
    queryId: uint64
    reason: uint32
    remaining: RemainingBitsAndRefs
}

struct (0x47657424) RecoverStakeCompat {
    queryId: uint64
}

struct (0x47657442) RecoverStakeUnrestricted {
    queryId: uint64
    validator: address
    amount: coins
}

type RecoverStake = RecoverStakeCompat | RecoverStakeUnrestricted

struct (0xf96f7324) RecoverStakeOk {
    queryId: uint64
    remaining: RemainingBitsAndRefs
}

struct (0xfffffffe) RecoverStakeError {
    queryId: uint64
    answer: uint32
    remaining: RemainingBitsAndRefs
}

struct (0x7e522889) InitProxy {
    queryId: uint64
    response: address
}

struct (0x09f8fbfa) ProxyInitSuccessfull {
    queryId: uint64
    validator: address
    parity: bool
}

struct (0x326d84c1) ProxyRefundWrongSender {
    queryId: uint64
}

struct (0xf8e41961) PayoutInitMessage {
    queryId: uint64
    isWithdrawal: bool
    owner: address
    roundIndex: uint64
    prev: address?
    next: address?
}

struct (0x53899a1b) PayoutBurnMessage {
    queryId: uint64
    distribution: Distribution
}

struct (0x42a73984) PayoutBurnNotification {
    queryId: uint64
    isWithdrawal: bool
    owner: address
    index: uint64
    roundIndex: uint64
    distribution: Distribution
}

struct (0xd6d1ff31) StakeReturned {
    queryId: uint64
    validator: address
    used: coins
    returned: coins
}

struct (0x21a6a2b3) RefundMessage {
    context: RefundContext
}

struct (0x219d71f5) AddValidator {
    queryId: uint64
    validator: address
    roundAllowance: RoundAllowance
    limits: ValidatorLimit?
}

struct (0x66d3ad60) RemoveValidator {
    queryId: uint64
    validator: address
}

struct (0x42a515de) AddFunds {
    queryId: uint64
}

struct (0x11c31b99) OwnerWithdrawal {
    queryId: uint64
    amount: coins
}

struct (0xf36da828) UpdateLimits {
    queryId: uint64
    limit: GlobalValidatorsLimit | GlobalNominatorsLimit | ValidatorSpecific
}

struct (0xc2d9e5ad) UpdateNominatorsWhitelist {
    queryId: uint64
    whitelist: map<address, bool>
}

struct (0x43921f80) OwnerWithdrawalSuccess {
    queryId: uint64
}

struct (0xe4649054) RoundInfoMessage {
    queryId: uint64
    info: RoundInfo
}

fun refundError(to: address, ctx: RefundContext, mode: int) {
    val refund = createMessage({
        bounce: false,
        dest: to,
        value: 0,
        body: RefundMessage { context: ctx },
    });
    refund.send(mode);
}
