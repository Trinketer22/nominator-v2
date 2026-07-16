enum ErrorsPool {
    InvalidWorkchain = 78
    QueryIdRequired = 80
    StakeBelowLimit = 81
    NotEnoughPoolBalance = 82
    NotEnoughValueForNewStake = 86
    PoolStorageNotInitialized = 90
    AlreadyInitialized = 91
    InvalidMaxMin = 92
    AtLeastOneRoundShouldBeAlowed = 93
    InvalidOwnerShare = 94
    InvalidValidatorShare
    IndividualLimitIsAboveGlobal
    IndividualLimitIsBelowGlobal
    MinStakeBelowNetworkLimit
    MaxStakeAboveNetworkLimit

    NotOwner = 200
    OwnerNotFound
    WithdrawalAlreadyRequested
    DepositAlreadyRequested
    NothingToWithdraw
    NothingToDeposit
    RewardIsBelowMinimal
    DepositNotFound
    DepositNotAllowed
    NotEnoughGas = 300
    TooManyNominators = 400
    TooManyValidators
    InvalidNewStakeMessage = 500
    RoundTooEarly = 501
    RecoveryTimeTooEarly = 502
    ValidatorNotFound = 600
    ValidatorAlreadyExits
    MainValidatorCantBeRemoved
    ElectionsNotStarted
    ElectionsAlreadyEnded
    OwnerShareIsUndercapitalized
    StakeAboveTheLimit
    RoundIsClosed
    AlreadyStakedInThatRound
    RoundNotAllowed
    UsageRecordNotFound = 700
    NotFromProxy
    PoolIsHalted
    InvalidMessage = 0xFFFF
}

enum ErrorsPayout {
    InvalidSender = 800
    AlreadyInitialized
}
