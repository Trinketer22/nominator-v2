# TON Nominator Pool V2 Smart Contract

A Tolk-based smart contract protocol for The Open Network (TON) that enables delegated staking through a **nominator pool**. The contract allows multiple validators to use pool funds for election participation while nominators deposit TON and receive pool shares representing their proportional ownership. Nominators can also withdraw rewards independently without fully exiting the pool. Rewards are auto-compounded into the share price, and withdrawals are orchestrated via on-chain payout items to avoid gas-limit loops.

---

## Table of Contents

1. [General Principles](#general-principles)
2. [Architecture Overview](#architecture-overview)
3. [Configuration Parameters](#configuration-parameters)
4. [Core Concepts](#core-concepts)
5. [How Rounds Work](#how-rounds-work)
6. [Validator Proxy](#validator-proxy)
7. [Contract Interactions](#contract-interactions)
8. [Fee Structure](#fee-structure)
9. [Getters](#getters)
10. [Security Model](#security-model)
11. [Known Limitations & Implementation Status](#known-limitations--implementation-status)
12. [Build & Test](#build--test)

---

## General Principles

### 1. Delegated Staking
The pool aggregates TON from **nominators** (delegators) and makes them available to whitelisted **validators** for participation in the TON validator elections. Validators do not need to maintain a separate wallet balance to track funds — the pool handles all usage records, stake recovery, and profit refunds automatically. Profits from validation are distributed proportionally to nominator shares.

### 2. Share-Based Accounting
Instead of tracking individual TON balances directly, the pool uses a **share/token model**:
- Nominators receive `pool shares` upon deposit.
- The ratio `nominatorsAmount / poolSupply` defines the share price.
- As validation profits accrue, `nominatorsAmount` grows, increasing the TON value of each share.
- This design natively supports auto-compounding and simplifies reward distribution.

### 3. Round-Based Operation
Funds usage is organized into **rounds**, which are tied to validator set rotations:
- A round opens when the validator set (`vset`) rotates.
- Validators can use pool funds for staking during elections.
- After stake recovery and profit realization, the round rotates forward.
- Pending deposits and withdrawals are processed at round boundaries.

### 4. Basechain Pool / Masterchain Proxies
The pool itself lives in the **basechain** (workchain 0) for lower fees, but validator operations (staking/recovery) must be performed from the **masterchain** (workchain -1) because the elector contract resides there.
- Each validator is assigned **proxy contracts** deployed to the masterchain.
- Proxies act as dumb, stateless forwarders between the pool and the elector.
- Round parity (odd/even) allows a validator to have two proxies, enabling staggered recovery/staking windows.

### 5. Halt-on-Overload
If processing pending deposits/withdrawals exhausts available gas or balance in a single transaction, the pool can enter a **halted** state, preventing new validator stakes and owner withdrawals until the backlog is cleared. Nomination deposits and full withdrawals are also blocked while halted.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     NominatorPool                           │
│                    (basechain, wc=0)                        │
├─────────────────────────────────────────────────────────────┤
│  Owner          │  Validators Map  │  Nominators Map         │
│  Pool ID        │  Main validator  │  Shares / TON amounts   │
│  Owner Share    │  Extra validators│  Pending ops (cells)    │
│  Round state    │  Round usage     │  Max count / min stake  │
└─────────────────────────────────────────────────────────────┘
         │                           │
         │ deploys                   │ proxies for stake/recover
         ▼                           ▼
    PayoutItem                  ValidatorProxy
    (basechain)                 (masterchain, wc=-1)
    for each pending             dumb forwarder to elector
    deposit/withdrawal
```

### Contracts in the Protocol

| Contract | Workchain | Role |
|----------|-----------|------|
| **NominatorPool** | 0 (basechain) | Core logic; holds funds, shares, validator config, and round state. |
| **ValidatorProxy** | -1 (masterchain) | Stateless proxy that forwards `new_stake` / `recover_stake` to the elector and relays responses back to the pool. Two proxies per validator (odd/even round parity). |
| **PayoutItem** | 0 (basechain) | Individual on-chain bill for a pending deposit or withdrawal. Burned to trigger the final TON transfer or share conversion. |

---

## Configuration Parameters

### Pool Initialization Parameters (`InitPoolMessage`)

| Parameter | Type | Description |
|-----------|------|-------------|
| `mainValidator` | `address` | The primary validator address (masterchain). This validator cannot be removed. |
| `roundAllowance` | `RoundAllowance` | Which rounds the validator may participate in: `InOddRounds`, `InEvenRounds`, or `InAllRounds`. |
| `limit` | `ValidatorLimit?` | Optional per-validator staking limit. Can be an absolute TON cap (`ValidatorLimitTon`) or a share of total pool balance (`ValidatorLimitShare`). |
| `ownerShare` | `uint25` | The owner's cut of validator profits, expressed as parts of `SHARE_BASE` (2^24). For example, `ownerShare = SHARE_BASE` means 100% of profit goes to the owner; `0` means all profit goes to nominators. |
| `maxTonPerValidator` | `coins` | Global maximum stake any single validator may use from the pool. |
| `minTonPerValidator` | `coins` | Global minimum stake a validator must request for a `new_stake`. |
| `maxRefund` | `coins` | Maximum TON refunded to a validator on top of recovered stake if the validator made a profit. |
| `nominatorsSettings` | `Cell<NominatorsSettings>` | Encapsulated nominator configuration (see below). |

### Nominator Settings (`NominatorsSettings`)

| Parameter | Type | Description |
|-----------|------|-------------|
| `maxNominators` | `uint10` | Maximum number of distinct nominator entries the pool will accept. If set to `0`, the contract operates in **owner-only mode** (nominator deposits are rejected). Note: fully relaxed single-nominator election timing (as in the original single-nominator pool contract) is not yet implemented; all validators are subject to the same round and election-window checks. |
| `minStake` | `coins` | Minimum deposit amount accepted from a nominator. This is the true configurable economic gate; the contract also requires a small gas constant on top of this (see `DEPOSIT_GAS` in the fee table), but that constant is not itself a fee charged to the owner. |
| `minWithdrawableRewards` | `coins` | Minimum profit a nominator must have accrued before a reward withdrawal (`"r"` comment) is accepted. |
| `whitelist` | `map<address, bool>` | Optional nominator whitelist. If the map is non-empty, only addresses present in it are allowed to deposit. If empty, all addresses are accepted. Can be updated post-initialization via `UpdateNominatorsWhitelist`. |

### Global Limits (`UpdateLimits`)

After initialization, the owner can adjust limits via the `UpdateLimits` or `UpdateNominatorsWhitelist` messages:

| Category | Fields | Description |
|----------|--------|-------------|
| **GlobalValidatorsLimit** | `minTonPerValidator`, `maxTonPerValidator`, `maxRefund` | Adjusts staking bounds for all validators and the refund cap. These bounds are also validated against **network config 17** staking limits: `minTonPerValidator` must be ≥ `minStake` and `maxTonPerValidator` must be ≤ `maxStake` from network config. |
| **ValidatorSpecific** | `validator`, `limit` | Sets an individual validator's `ValidatorLimit` (TON cap or share cap). |
| **GlobalNominatorsLimit** | `minStake`, `maxNm` | Updates minimum nominator stake and the total nominator count ceiling. |
| **NominatorsWhitelist** | `whitelist` | Replaces the current nominator whitelist map. A non-empty whitelist restricts deposits to the listed addresses only. An empty map clears the restriction and allows all addresses. |

---

## Core Concepts

### Shares and Pricing
- **Deposit**: `shares = depositAmount * poolSupply / nominatorsAmount`.
- **Withdrawal**: `tonValue = shares * nominatorsAmount / poolSupply`.
- Rounding favors the nominator at the 1-share-point level (initially 1 nanoton).

### Rounds and Rotation
- `roundIndex` increments each time the validator set hash changes.
- `curRound` and `prevRound` store usage records (maps of `proxy_hash → TonUsage`). The proxy hash is the 256-bit address hash (without workchain prefix), reducing storage footprint and simplifying lookup consistency between round data and validator data.
- Validators can stake in the current round if the round is open, elections are active, and they have no prior usage in that round.
- `RecoverStake` can only be called after enough time has passed (`rotationCount >= 2` or `now > rotationTime + heldFor + 60`).

### Pending Operations
To avoid unbounded map iteration inside a single transaction:
- **Pending deposits** and **pending withdrawals** are materialized as linked **PayoutItem** contracts.
- At round rotation, the pool triggers a chain of burns; each `PayoutItem` sends a `PayoutBurnNotification` back to the pool, which then finalizes the deposit/withdrawal one by one across multiple transactions.
- If the process halts (e.g., out of gas or funds), subsequent rounds can resume it.

### Punishment / Slashing Reserve
The pool enforces solvency in case a validator is fined by the elector. Before each `new_stake`, the contract checks:
```
ownerShare >= maxPunishment(minTonPerValidator) * activeSlots
```
The punishment amount is derived from TON config param 40 (misbehavior fines), scaled by severity and duration multipliers.

### Validator Refunds (Automatic)
Validators **do not need to maintain a separate wallet balance** to track how much gas or TON they have tied up in the pool. The contract tracks a `refundAmount` per validator automatically:
- Incoming message value from `new_stake` and `recover_stake` calls is recorded.
- Upon successful `recover_stake_ok`, the pool calculates net profit (`returned - used`) and reimburses the validator by sending a `StakeReturned` message.
- The refund is capped by `maxRefundAmount`, and the validator only receives reimbursement if the overall operation was profitable.
- This means the validator can simply send requests and rely on the pool to settle usage costs, without manually tracking balances or ensuring their wallet always holds a specific amount.

---

## How Rounds Work

Rounds are the central lifecycle mechanism of the pool. A **round** is a fund-usage cycle tied to the TON validator set (`vset`) rotation. All validator staking, recovery, profit realization, and nominator pending-operation processing happen within the context of rounds.

### Round Storage

The pool stores **two rounds at any given time** inside `ValidatorsData`:

| Field | Type | Purpose |
|-------|------|---------|
| `curRound` | `Cell<RoundData>` | Current active round. New stakes are recorded here. |
| `prevRound` | `Cell<RoundData>` | Previous round. Stakes that are awaiting recovery or already recovered live here. |

Each `RoundData` contains:
- `roundIndex`: sequential round identifier (`uint64`)
- `used`: total TON used (staked) in this round
- `returned`: total TON returned (recovered) in this round
- `users`: a map of `proxy_hash → TonUsage`

### Round Parity and Proxy Assignment

Because validators need to interact with the masterchain elector, each validator is given **two proxy contracts**:
- **Even proxy** — used in rounds where `roundIndex` is even
- **Odd proxy** — used in rounds where `roundIndex` is odd

Round parity is encoded as a **bit index**:
```
bitIdx = 2 - (roundIndex & 1)
```
- Even rounds → `bitIdx = 2`
- Odd rounds  → `bitIdx = 1`

Each validator stores a `usageState` (`uint2` bitmask) indicating which of its two proxies currently has an active stake. When a validator stakes, the appropriate bit is set; when recovery completes, the bit is cleared.

### Round Allowance

When a validator is added, the owner can restrict which rounds it may participate in:

| Allowance | Value | Meaning |
|-----------|-------|---------|
| `InOddRounds` | `1` | Validator may only stake in odd rounds |
| `InEvenRounds` | `2` | Validator may only stake in even rounds |
| `InAllRounds` | `3` | Validator may stake in any round |

This is enforced by checking `validator.roundParity & roundBitIdx != 0` before accepting a `NewStake`.

### Triggering Rotation: `UpdateVset`

Anyone can send an `UpdateVset` message to the pool. The pool then:
1. Reads the **current validator set** hash from TON config parameter 34.
2. Compares it against the truncated hash stored in the **main validator** record.
3. If the hash changed, the **main validator** has rotated into a new vset.

If `prevRound.users` is **empty**, the pool executes a **clean rotation**:
- `prevRound` becomes the old `curRound`
- A fresh empty `RoundData` is created with `roundIndex + 1`
- `storage.roundIndex` increments
- Pending deposits and withdrawals are processed

If `prevRound.users` is **not empty** (i.e., outstanding stakes exist), the pool **closes the round** instead:
- `roundClosed = true`
- No new stakes are accepted until the round re-opens (all outstanding stakes must be recovered first).

### Active Slots and `stakeUsed`

The pool tracks global round-level metrics:
- **`activeSlots`**: number of validators with an unrecovered stake in the current or previous round.
- **`stakeUsed`**: total TON currently locked in elector stakes.

When a `NewStake` succeeds, `activeSlots++` and `stakeUsed += tonUsed`.
When a `RecoverStakeOk` arrives, `activeSlots--` and `stakeUsed -= tonUsed`.

### New Stake Timing (Elections Window)

A validator can only call `NewStake` during the **elections window** defined by TON config parameter 15:
```
curTime > curVset.utimeUntil - electionsTiming.startBefore
curTime < curVset.utimeUntil - electionsTiming.endBefore
```
Outside this window, stakes are rejected even if the round is technically open.

### Stake Recovery Timing

A validator cannot recover a stake immediately after staking. Each usage record carries a `RotationData` structure that tracks:
- `vsetHash`: validator set hash at the time of staking
- `rotationTime`: timestamp of the last vset rotation
- `rotationCount`: how many times the vset has rotated since this stake

Recovery is only permitted when:
```
rotationCount >= 2
  OR
now > rotationTime + heldFor + 60
```
This ensures the elector has held the stake for the required duration (`stakeHeldFor`, also from config 15) plus a small safety margin.

### Round Closure and Re-Opening

If the main validator's vset changes while `prevRound` still contains unrecovered stakes, the pool **closes** the current round:
- `roundClosed = true`
- New stakes are forbidden
- Validators must recover their outstanding stakes

Once the **last** usage record in `prevRound` is recovered (i.e., `roundDone`), the pool attempts a **forced rotation** inside the `RecoverStakeOk` handler. If successful, the round re-opens and pending operations are processed.

### Processing Pending Operations at Boundaries

Whenever a clean rotation occurs (either via `UpdateVset` or as the last recovery in a closed round), the pool checks for pending nominator deposits and withdrawals:
- If `pendingDeposits > 0` or `pendingWithdrawals > 0`, the pool loads the `NominatorsData` and processes them.
- This can result in `halted = true` if the combined gas cost would exceed the transaction budget.
- While halted, new validator stakes, nominator deposits/withdrawals, and owner withdrawals are blocked, but stake recovery can still proceed.

---

## Validator Proxy

Because the pool lives on the **basechain** (workchain 0) while the elector lives on the **masterchain** (workchain -1), the pool cannot send `new_stake` or `recover_stake` messages directly to the elector. Each validator is therefore assigned one or two **ValidatorProxy** contracts deployed to the masterchain. The proxy is deliberately **stateless** beyond its immutable deployment data, so it can be destroyed and redeployed without losing protocol state.

### Proxy Storage

```tolk
struct ProxyStorage {
    roundParity: bool,   // true = odd round proxy, false = even round proxy
    pool: address,      // basechain pool address
    validator: address   // masterchain validator wallet address
}
```

The proxy stores only these three fields. All operational context (usage records, stakes, refunds) lives in the pool.

### Message Flows

#### Pool → Elector

The pool sends three message types to the proxy. The proxy **only** accepts messages from its configured `pool` address; anything else is refunded.

| Pool Message | Proxy Action |
|--------------|--------------|
| `InitProxy` | Reserves `PROXY_MIN_STORAGE`, then refunds the rest to the `response` destination with a `ProxyInitSuccessfull` notification. |
| `NewStake` | Forwards the **full attached value** to the elector with `bounce: true`. Gas is paid separately from the remaining balance so the stake amount never leaks into gas. |
| `RecoverStakeCompat` | Forwards the request to the elector with `bounce: true` and `SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE`. The incoming message value pays for the recovery gas. |

#### Elector → Pool

When the elector replies (`NewStakeOk`, `NewStakeError`, `RecoverStakeOk`, `RecoverStakeError`), the proxy wraps the raw elector body together with the proxy's own identity:

```tolk
struct ProxyResponse {
    electorResponse: slice,  // the original elector response body
    validator: address,       // proxy's validator address
    parity: bool              // proxy's round parity
}
```

This wrapper lets the pool authenticate that the response really came from an expected proxy, and tells it which validator and which round parity the response belongs to.

**`RecoverStakeOk` edge case:** Elector responses must carry the recovered stake back. If the returned value is very small (`< PROXY_MIN_STORAGE * 2`), the proxy assumes the stake was heavily slashed. In that case it deliberately **spends its own storage reserve** to make sure at least `0.1` TON reaches the pool (rather than trapping funds in a depleted proxy). If the value is healthy, the proxy replenishes its `PROXY_MIN_STORAGE` reserve first and forwards the rest.

### Bounce Handling

If the elector bounces a `NewStake` or `RecoverStakeCompat` message (e.g., the proxy was frozen or the elector rejected the message during the action phase), the proxy receives a bounced inbound message. Its `onBouncedMessage` handler immediately synthesizes a `NewStakeError` or `RecoverStakeError` and forwards it back to the pool, again tagged with the `ProxyResponseData` identity. The pool then unwinds the temporary usage record exactly as if the elector had sent the error explicitly.

### Unfreeze Resilience

Because proxy addresses are derived deterministically from `(validator_address, pool_address, proxy_code)`, the pool can always attach the proxy `StateInit` to its outbound messages. This means a proxy that has been frozen due to inactivity can be **transparently unfrozen** the next time the pool sends a `NewStake` or `RecoverStakeCompat` message to it.

---

## Contract Interactions

### Nominator Operations (Text Comments)

Nominators interact with the pool by sending text-comment messages. Every deposit/withdrawal triggers an **implicit vset rotation check** (`UpdateVset`) before the request is processed, so nominators' actions can also advance round transitions and clear pending queues. Validators do not need to send a separate `UpdateVset` solely for this purpose. Nominators can deposit TON, withdraw their entire position, or withdraw only accrued rewards while leaving the principal stake in the pool.

| Comment | Action |
|---------|--------|
| `"d"` | **Deposit**: TON minus `DEPOSIT_GAS` is converted to shares. If the round is closed or there are still unrecovered stakes in the previous round, funds go into a pending deposit queue. |
| `"w"` | **Full Withdrawal**: Removes the nominator. If balance is insufficient, creates a pending withdrawal PayoutItem for later. |
| `"r"` | **Reward Withdrawal**: Withdraws only the profit (share value minus original deposit). Also subject to pending-queue logic if the round is closed. |

### Validator Operations

| Message | Sender | Effect |
|---------|--------|--------|
| `NewStake` | Validator (masterchain) | Uses pool TON and forwards it (via proxy) to the elector. Records usage in the current round. |
| `RecoverStakeCompat` | Validator (masterchain) | Requests stake recovery through the validator's proxy. Enforces timing and rotation checks. |
| `RecoverStakeUnrestricted` | Any | Allows a third party to pay for recovering a validator's stake (useful if validator is low on gas). |

### Owner Operations

| Message | Effect |
|---------|--------|
| `InitPoolMessage` | Transitions contract from uninitialized to active. Deploys the main validator's proxy and sets all parameters. |
| `AddValidator` | Whitelists an additional validator with its own proxy and round allowance. |
| `RemoveValidator` | Bans a validator from new stakes. Record is kept until stake recovery is complete. |
| `UpdateLimits` | Adjusts global or per-validator staking/nominator limits. |
| `UpdateNominatorsWhitelist` | Replaces the nominator whitelist. If the whitelist is non-empty, only listed addresses may deposit. |
| `OwnerWithdrawal` | Withdraws the owner's share of profits, provided free balance exists and the pool is not halted. |
| `AddFunds` | Accepts bare TON to increase the owner's effective share. |

---

## Fee Structure

All fees are defined in `contracts/fees.tolk`:

| Constant | Value | Purpose |
|----------|-------|---------|
| `POOL_MIN_STORAGE` | 10 TON | Minimum balance the pool must always retain. |
| `PROXY_MIN_STORAGE` | 10 TON | Storage reserve for each deployed validator proxy. |
| `DEPOSIT_GAS` | 0.2 TON | Gas constant required on every nominator deposit. This is **not a fee** retained by the owner; it is simply the minimum message value needed to cover the compute and action-phase gas of processing a deposit. The configurable economic gate is `minStake`. |
| `WITHDRAWAL_GAS` | 0.2 TON | Minimum gas constant required when a withdrawal enters the pending queue (covers the cost of deploying and burning a `PayoutItem`). Direct withdrawals that execute instantly do not incur this constant. |
| `NEW_STAKE_FEE` | 1 TON | Deduction from the validator's requested stake to cover proxy/elector gas. |
| `RECOVER_STAKE_FEE` | 0.1 TON | Deduction when stake is successfully recovered. |
| `NEW_VALIDATOR_FEE` | 0.1 TON | Gas budget deducted when adding a new validator. |
| `PAYOUT_ITEM_BALANCE` | 0.05 TON | Forwarded to each PayoutItem on deployment. |
| `REFUND_THRESHOLD` | 1 TON | Max forwarded TON for various refund/proxy gas buffers. |

---

## Getters

The pool exposes several getters for off-chain queries:

| Getter | Returns | Description |
|--------|---------|-------------|
| `owner()` | `address` | Pool owner address. |
| `get_pool_data()` | `Storage` | Full pool state (owner, shares, round status, validator data, nominators, etc.). |
| `get_nominator_data(nominatorAddress: int)` | `GetNominatorData` | Nominator info from a 256-bit address hash. Searches basechain (`wc=0`) and masterchain (`wc=-1`) for compatibility. |
| `get_validator_info(address: address)` | `GetValidatorInfo` | Validator data, usage records for both rounds, and a **projected `roundIndex` and `rotated` flag** after running the same vset rotation check as `UpdateVset`. It also returns the **current `stakeable` amount** — the TON the validator is allowed to use in the current round — computed by applying the exact same validation checks as `NewStake` (round state, parity, usage, limits, balance, owner undercapitalization, etc). The goal is to let off-chain tools know whether a validator is actually eligible to stake and how much, without attempting a real transaction. Because this getter evaluates `rotateRound`, calling it may advance the round state in the same way a real `UpdateVset` message would. |
| `get_validator_info_mtc(workchain: int, hash: int)` | `GetValidatorInfo` | Same as `get_validator_info`, but accepts workchain + hash for masterchain tooling compatibility. |
| `get_proxy_address(validator: address)` | `GetProxyAddressResult` | Even/odd proxy addresses for a given validator. |
| `get_limits_per_validator()` | `(coins, coins, coins)` | `(minTonPerValidator, maxTonPerValidator, maxRefundAmount)`. |
| `get_nominator_minimal_stake()` | `GetMinStake` | `(minStake, minExpectedValue)` where `minExpectedValue = minStake + DEPOSIT_GAS`. |
| `get_max_punishment(stake: int)` | `int` | Max punishment fine for a given stake amount, derived from config param 40. |

---

## Security Model

### Role Separation
- **Owner**: Controls economics (share of profit, validators and nominators whitelists, limits). Can withdraw owner profits.
- **Validator**: Only acts as the technical operator (new/recover stake). Cannot touch nominator funds directly.
- **Nominator**: Only depositor/withdrawer. Cannot influence validator operations.

### Proxy Authentication
All elector responses (`NewStakeOk`, `NewStakeError`, `RecoverStakeOk`, `RecoverStakeError`) are authenticated by deriving the expected proxy address from `(validator_address, pool_address, proxy_code)` state-init. This prevents spoofed responses.

### Owner Share requirements
Before any `new_stake`, the contract ensures the owner's share of total balance exceeds the worst-case punishment fine multiplied by the number of active validator slots. This supposed to protect nominators from validator slashing.

### Bounce Handling
If a `new_stake` message bounces (e.g., proxy frozen or elector rejection), the usage record is automatically reversed and the validator's locked funds are released.

### Halt / Graceful Degradation
If pending nominator operations cannot be cleared in a single round rotation, the pool sets `halted = true`, temporarily blocking new validator stakes until the queue is fully processed.

---

## Known Limitations & Implementation Status

### Implemented optional features
- Nominators from arbitrary workchains are supported for deposit/withdrawal.
- Configurable nominator quantity and minimum stake.
- Configurable per-validator and global staking limits, validated against network config 17 bounds.
- Nominator whitelist: owner can restrict deposits to a specific set of addresses via `NominatorsSettings.whitelist` or `UpdateNominatorsWhitelist`.
- Reward withdrawal via `"r"` comment.
- Dynamic validator quantity (up to 128 validators).
- Owner-only mode: set `maxNominators = 0` to reject nominator deposits.

### Not yet implemented
- **Single-nominator relaxed timing**: The original single-nominator pool allowed the validator to bypass election-window timing checks. This contract always enforces `ElectionsTiming` bounds, even when `maxNominators = 0`.

### Notes on fee model
- `DEPOSIT_GAS` and `WITHDRAWAL_GAS` are hardcoded **gas constants** in `contracts/fees.tolk` (`0.2` TON each). They are not fees collected by the owner.
- The actual configurable economic gate for deposits is `minStake`, which is set during pool initialization and can be updated later via `GlobalNominatorsLimit`.

## Build & Test

This project uses **Acton**, the Tolk build and test framework for TON.

### Build
```bash
acton build
```

### Test
```bash
acton test
```

## References

- [TON Docs — Tolk Overview](https://docs.ton.org/tolk/overview)
- [TON Docs — TON Blockchain](https://docs.ton.org/)
- Original nominator pool and single-nominator pool contracts served as interface and logic references.
- Liquid staking payout NFT approach adapted for loop-free pending operations.
