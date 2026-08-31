import "@tests/elector-utils"

// Simplified def
struct ElectorStorage {
    elections: cell? = null
    credists: cell? = null
    pastElections: cell? = null
    grams: coins = 0
    activeId: uint32 = 0
    activeHash: uint256
}

// Default values specified just
struct ParticipantListExt {
    electAt: int
    electClose: int
    minStake: coins
    totalStake: coins
    participants: lisp_list<tuple>
    failed: bool
    finished: bool
}

get fun active_election_id(): int {
    return 0;
}

get fun compute_returned_stake(_addressHash: int): int {
    return 0;
}

get fun participant_list_extended(): ParticipantListExt {
    return ParticipantListExt {
        electAt: 0,
        electClose: 0,
        minStake: DEFAULT_MIN_STAKE,
        totalStake: DEFAULT_MIN_STAKE * 10,
        participants: [],
        failed: false,
        finished: true,
    };
}
