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
13. [Scripts](#scripts)
14. [References](#references)

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
The pool itself lives in the **basechain** (workchain 0) for lower fees, but validator staking/recovery must be performed on the **masterchain** (workchain -1) where the elector contract resides.
- Each validator is assigned **proxy contracts** deployed to the masterchain. The validator's own wallet can be in any workchain — only the proxies need to be on masterchain.
- Proxies act as dumb, stateless forwarders between the pool and the elector.
- Round parity (odd/even) allows a validator to have up to two proxies, enabling staggered recovery/staking windows. The number of proxies depends on the validator's round allowance: one proxy for odd-only or even-only, two for all rounds.

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
| **ValidatorProxy** | -1 (masterchain) | Stateless proxy that forwards `new_stake` / `recover_stake` to the elector and relays responses back to the pool. One or two proxies per validator depending on round allowance (odd-only → 1, even-only → 1, all rounds → 2). The validator's own wallet can be in any workchain. |
| **PayoutItem** | 0 (basechain) | Individual on-chain bill for a pending deposit or withdrawal. Burned to trigger the final TON transfer or share conversion. |

---

## Configuration Parameters

### Pool Initialization Parameters (`InitPoolMessage`)

| Parameter | Type | Description |
|-----------|------|-------------|
| `mainValidator` | `address` | The primary validator address. This validator cannot be removed. |
| `roundAllowance` | `RoundAllowance` | Which rounds the validator may participate in: `InOddRounds`, `InEvenRounds`, or `InAllRounds`. |
| `limit` | `ValidatorLimit?` | Optional per-validator staking limit. Can be an absolute TON cap (`ValidatorLimitTon`) or a share of total pool balance (`ValidatorLimitShare`). |
| `ownerShare` | `uint25` | The owner's cut of validator profits, expressed as parts of `SHARE_BASE` (2^24). For example, `ownerShare = SHARE_BASE` means 100% of profit goes to the owner; `0` means all profit goes to nominators. |
| `maxTonPerValidator` | `coins` | Global maximum stake any single validator may use from the pool. |
| `minTonPerValidator` | `coins` | Global minimum stake a validator must request for a `new_stake`. |
| `refundBonus` | `uint33` | Flat bonus compensating the validator for the staking "happy path" (NewStake fee + RecoverStake fee + external operational costs), capped at ~8.6 TON. See [Validator Refunds](#validator-refunds-automatic). |
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
| **GlobalValidatorsLimit** | `minTonPerValidator`, `maxTonPerValidator`, `refundBonus` | Adjusts global staking bounds and per-round bonus. Validated against **network config 17** limits (`minTonPerValidator ≥ minStake`, `maxTonPerValidator ≤ maxStake`). |
| **ValidatorSpecific** | `validator`, `limit` | Sets an individual validator's `ValidatorLimit` (TON cap or share cap). |
| **GlobalNominatorsLimit** | `minStake`, `maxNm` | Updates minimum nominator stake and the total nominator count ceiling. |
| **NominatorsWhitelist** | `whitelist` | Replaces the current nominator whitelist map. A non-empty whitelist restricts deposits to the listed addresses only. An empty map clears the restriction and allows all addresses. |

### Per-Validator Limits: TON Cap vs Share Cap

Each validator can have an individual staking limit set via `ValidatorSpecific`. There are two kinds:

- **`ValidatorLimitTon`** — an absolute TON cap (`maxTon`). The validator can stake up to this fixed amount per round. The downside is that it does not adapt as the pool grows: if the pool balance doubles from profits, a fixed TON cap still limits the validator to the original amount, underutilizing the pool.

- **`ValidatorLimitShare`** — a share of the pool's projected balance (`maxShare`, expressed as parts of `SHARE_BASE = 16777216`). The projected balance is `pool balance + stakeUsed - pendingDeposits - pendingWithdrawals - POOL_MIN_STORAGE` — i.e. the full pool balance including stake currently locked in the elector. The validator can stake up to `maxShare / SHARE_BASE` of this projected balance per round. This **auto-rebalances as profits accrue**: when the pool grows, each validator's absolute stake allowance grows proportionally. In most cases, share limits are preferable because they keep utilization balanced across validators regardless of pool size.

The main validator's limit is set during `init-pool`; extra validators get their limit during `add-validator`. Both can be updated later via `update-validator-limit`.

Setting a validator's share limit to `0` effectively **soft-bans** it from new stakes without removing it from the pool — the validator stays registered (preserving its proxies and recovery state) but cannot stake until the limit is raised again. This is especially important for the main validator, which cannot be removed via `RemoveValidator` — a zero share limit is the only way to temporarily disable it.

**Calculating the share:** the share limit is applied per round against the pool's projected balance. Because each validator can have stakes active in both the current and previous round simultaneously (one proxy staking, one recovering), the total number of concurrent stake slots is `sum of round allowances across all validators` (each validator contributes 1 slot per round it participates in: odd-only → 1, even-only → 1, all rounds → 2). To split the pool evenly when all validators use all rounds, set each validator's `maxShare` to `SHARE_BASE / (numValidators × 2)`.

#### Example: 2 validators, each using all rounds

Total concurrent slots = 2 validators × 2 rounds = 4. Each validator should get `SHARE_BASE / 4 = 4194304` (25% per round).

**Interactive:**
```bash
# Initialize with main validator at 25% share cap
acton script scripts/init-pool.tolk --net mainnet
# When prompted for the limit, pick: share, maxShare = 4194304

# Add second validator at 25% share cap
acton script scripts/add-validator.tolk --net mainnet
# When prompted for the limit, pick: share, maxShare = 4194304
# When prompted for round allowance, pick: all rounds (3)
```

**Batch (non-interactive):**
```bash
# Initialize
BATCH=1 \
  POOL_ADDRESS="kQ..." MAIN_VALIDATOR="kQ..." \
  LIMIT_KIND=share MAX_SHARE=4194304 \
  INIT_VALUE=100000000000000 OWNER_SHARE=8388608 \
  MAX_TON_PER_VALIDATOR=10000000000000000 MIN_TON_PER_VALIDATOR=300000000000000 \
  REFUND_BONUS=3000000000 \
  MAX_NOMINATORS=1023 MIN_STAKE=1000000000000 MIN_WITHDRAWABLE_REWARDS=1000000000 \
  acton script scripts/init-pool.tolk --net mainnet

# Add second validator
BATCH=1 \
  POOL_ADDRESS="kQ..." VALIDATOR_ADDRESS="kQ..." \
  VALIDATOR_ROUND_ALLOWANCE=3 LIMIT_KIND=share MAX_SHARE=4194304 \
  ADD_VALIDATOR_VALUE=10000000000000 \
  acton script scripts/add-validator.tolk --net mainnet
```

Each validator can stake up to 25% of the pool per round. With both rounds active (one staking, one recovering), each validator effectively uses up to 50% of the pool across its two rounds, and the two validators together can utilize the full pool.

#### Example: 2 validators, one odd-only and one even-only

Each validator participates in only one round parity, so each has 1 concurrent slot. Total concurrent slots = 1 + 1 = 2. Each validator should get `SHARE_BASE / 2 = 8388608` (50% per round).

```bash
# Initialize with main validator (odd rounds) at 50% share cap
acton script scripts/init-pool.tolk --net mainnet
# When prompted for the limit, pick: share, maxShare = 8388608

# Add second validator (even rounds) at 50% share cap
acton script scripts/add-validator.tolk --net mainnet
# When prompted for round allowance, pick: even rounds (2)
# When prompted for the limit, pick: share, maxShare = 8388608
```

Each validator stakes in only its own round (odd or even), so they never compete for the same round's balance. Each gets 50% of the pool in its round.

#### Example: 3 validators, each using all rounds

Total concurrent slots = 3 validators × 2 rounds = 6. Each validator should get `SHARE_BASE / 6 ≈ 2796203` (~16.7% per round).

**Interactive:**
```bash
# Initialize with main validator at ~16.7% share cap
acton script scripts/init-pool.tolk --net mainnet
# When prompted for the limit, pick: share, maxShare = 2796203

# Add second validator
acton script scripts/add-validator.tolk --net mainnet
# When prompted for the limit, pick: share, maxShare = 2796203
# When prompted for round allowance, pick: all rounds (3)

# Add third validator
acton script scripts/add-validator.tolk --net mainnet
# When prompted for the limit, pick: share, maxShare = 2796203
# When prompted for round allowance, pick: all rounds (3)
```

**Batch (non-interactive):**
```bash
# Initialize
BATCH=1 \
  POOL_ADDRESS="kQ..." MAIN_VALIDATOR="kQ..." \
  LIMIT_KIND=share MAX_SHARE=2796203 \
  INIT_VALUE=100000000000000 OWNER_SHARE=8388608 \
  MAX_TON_PER_VALIDATOR=10000000000000000 MIN_TON_PER_VALIDATOR=300000000000000 \
  REFUND_BONUS=3000000000 \
  MAX_NOMINATORS=1023 MIN_STAKE=1000000000000 MIN_WITHDRAWABLE_REWARDS=1000000000 \
  acton script scripts/init-pool.tolk --net mainnet

# Add second and third validators
BATCH=1 POOL_ADDRESS="kQ..." VALIDATOR_ADDRESS="kQ_2..." \
  VALIDATOR_ROUND_ALLOWANCE=3 LIMIT_KIND=share MAX_SHARE=2796203 \
  ADD_VALIDATOR_VALUE=10000000000000 \
  acton script scripts/add-validator.tolk --net mainnet

BATCH=1 POOL_ADDRESS="kQ..." VALIDATOR_ADDRESS="kQ_3..." \
  VALIDATOR_ROUND_ALLOWANCE=3 LIMIT_KIND=share MAX_SHARE=2796203 \
  ADD_VALIDATOR_VALUE=10000000000000 \
  acton script scripts/add-validator.tolk --net mainnet
```

Each validator can stake up to ~16.7% of the pool per round. Across both rounds, each validator effectively uses up to ~33% of the pool, and the three validators together can utilize the full pool.

#### Soft-ban via zero share limit

To temporarily disable a validator (including the main validator, which cannot be removed), set its share limit to 0:

```bash
# Interactive
acton script scripts/update-validator-limit.tolk --net mainnet
# Pick the validator, then: share, maxShare = 0

# Batch
BATCH=1 POOL_ADDRESS="kQ..." VALIDATOR_ADDRESS="kQ..." \
  LIMIT_KIND=share MAX_SHARE=0 MSG_VALUE=1000000000 \
  acton script scripts/update-validator-limit.tolk --net mainnet
```

The validator stays registered but cannot stake. Raise the share limit above 0 to re-enable it.

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

Validators **do not need to maintain a separate wallet balance** to track gas/TON tied up in the pool. The contract compensates the validator for the staking "happy path" costs via a single flat **`refundBonus`** parameter:

- On successful `recover_stake_ok`, the pool calculates net profit (recovered amount minus staked amount).
- If the round was profitable, the **full `refundBonus`** is sent to the validator via a `StakeReturned` message.
- The bonus cost is split into two parts:
  - **Owner-only part** (one third of the bonus, capped at 1 TON): representing the NewStake fee the owner covers alone. This is **not** deducted from the recovered amount, so it does not reduce nominator profit — it comes out of the owner's equity.
  - **Split part** (two thirds of the bonus): deducted from the recovered amount before computing profit, so it is **split between the owner and nominators** according to `ownerShare`.
- If the round was unprofitable (slashed or no profit), no bonus is paid. The validator's overspend on unsuccessful operations must be resolved directly with the pool owner if necessary.
- `refundBonus` is configured at initialization and can be updated later via `UpdateLimits`.

#### `refundBonus` explained

When a validator recovers a stake, the elector returns the staked TON plus any validation profit. The `refundBonus` is a flat amount that bundles three cost components:

1. **NewStake fee** (~1 TON) — covered by the owner-only part. The owner bears this alone because most of the NewStake value is not actually spent — the elector refunds it back to the proxy with `NewStakeOk`, so it returns to the pool rather than being consumed. Only forwarding fees and elector gas are truly lost, so assigning this part solely to the owner avoids diluting nominator profit for a cost that largely returns.
2. **RecoverStake fee** (~1 TON) — covered by the split part.
3. **External operational bonus** — the remainder of the split part, compensating for the validator's own wallet gas, forwarding fees, and transaction costs outside the pool.

The full bonus is paid **only if the round was profitable**, so it is funded out of real validation profit, never out of nominator principal. This gates the bonus behind real validation profit to discourage bonus inflation from rogue validators.

The **trust boundary** between the owner and nominators is `refundBonus`. It is paid out of validation profit — the owner sets it, and nominators rely on the owner choosing a reasonable value. The bonus is capped at ~8.6 TON and is only paid when the round's profit exceeds the split part. So even a rogue owner can only direct up to 8.6 TON of a round's profit to the validator, and only in rounds where profit exceeds that amount.

**Typical values on masterchain :** the default `refundBonus` is 3 TON. The validator receives the full 3 TON; of that, 2 TON is deducted from the recovered amount (reducing profit shared by owner and nominators) and 1 TON is borne by the owner alone. The actual external validator cost per round is ~0.6 TON, so a validator's wallet balance grows over time. This is done for simplicity — the owner does not need to measure exact gas costs per round. An owner who wants tighter accounting can measure actual per-round costs and adjust `refundBonus` downward.

**Owner gas costs:**
The owner share growth is lower that the nominators by a margin of (~0.25 TON) per stake round(single stake round trip). Mainly due to gas and forwarding cost.

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

Because staking/recovery must happen on the masterchain where the elector resides, each validator is given one or two **proxy contracts** deployed to the masterchain, depending on its round allowance (odd-only → 1 proxy, even-only → 1 proxy, all rounds → 2 proxies). The validator's own wallet can be in any workchain — only the proxies need to be on masterchain.
- **Even proxy** — used in rounds where `roundIndex` is even
- **Odd proxy** — used in rounds where `roundIndex` is odd

Round parity is encoded as a **bit index**:
```
bitIdx = 2 - (roundIndex & 1)
```
- Even rounds → `bitIdx = 2`
- Odd rounds  → `bitIdx = 1`

Each validator stores a `usageState` (`uint2` bitmask) indicating which of its proxies currently has an active stake. When a validator stakes, the appropriate bit is set; when recovery completes, the bit is cleared.

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
2. Compares it against the truncated vset hash stored in the pool's `ValidatorsData`.
3. If the hash changed, the validator set has rotated into a new vset.

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

Because the elector contract lives on the **masterchain** (workchain -1), the pool (on basechain) cannot send `new_stake` or `recover_stake` messages directly to the elector. Each validator is therefore assigned one or two **ValidatorProxy** contracts deployed to the masterchain. The validator's own wallet can live in any workchain — only the proxies are required to be on masterchain. The proxy is deliberately **stateless** beyond its immutable deployment data, so it can be destroyed and redeployed without losing protocol state.

### Proxy Storage

```tolk
struct ProxyStorage {
    roundParity: bool,   // true = odd round proxy, false = even round proxy
    pool: address,      // basechain pool address
    validator: address   // validator wallet address (any workchain)
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

Nominators interact with the pool by sending text-comment messages. Nominators can deposit TON, withdraw their entire position, or withdraw only accrued rewards while leaving the principal stake in the pool.

| Comment | Action |
|---------|--------|
| `"d"` | **Deposit**: TON minus `DEPOSIT_GAS` is converted to shares. If the round is closed or there are still unrecovered stakes in the previous round, funds go into a pending deposit queue. |
| `"w"` | **Full Withdrawal**: Removes the nominator. If balance is insufficient, creates a pending withdrawal PayoutItem for later. |
| `"r"` | **Reward Withdrawal**: Withdraws only the profit (share value minus original deposit). Also subject to pending-queue logic if the round is closed. |

### Validator Operations

| Message | Sender | Effect |
|---------|--------|--------|
| `NewStake` | Validator | Uses pool TON and forwards it (via proxy) to the elector. Records usage in the current round. |
| `RecoverStakeCompat` | Validator | Requests stake recovery through the validator's proxy. Enforces timing and rotation checks. |
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
| `NEW_VALIDATOR_FEE` | 0.1 TON | Gas budget deducted when adding a new validator. |
| `PAYOUT_ITEM_BALANCE` | 0.05 TON | Forwarded to each PayoutItem on deployment. |
| `REFUND_THRESHOLD` | 1 TON | Max forwarded TON for various refund/proxy gas buffers. |
| `MAX_RECOVERY_VALUE` | 1 TON | Cap on the value forwarded from a `RecoverStakeOk` response when relaying recovered stake back to the pool. |
| `PROXY_INIT_VALUE` | 0.1 TON | Extra value attached on top of `PROXY_MIN_STORAGE` when deploying a validator proxy, to cover init gas. |

In addition, `fees.tolk` defines a gas-budget *constant* (in gas units, not TON) used by compute-path checks: `RECOVER_STAKE_OK_GAS`. This is an internal compute budget, not a user-facing fee.

---

## Getters

The pool exposes several getters for off-chain queries:

| Getter | Returns | Description |
|--------|---------|-------------|
| `owner()` | `address` | Pool owner address. Works in both uninitialized and active states. |
| `get_pool_id()` | `uint32` | Pool ID. Works in both uninitialized and active states. |
| `get_pool_data()` | `Storage` | Full pool state (owner, shares, round status, validator data, nominators, etc.). Only available after initialization. |
| `get_nominator_data(nominatorAddress: int)` | `GetNominatorData` | Nominator info from a 256-bit address hash. Searches basechain (`wc=0`) and masterchain (`wc=-1`) for compatibility. |
| `get_validator_info(address: address)` | `GetValidatorInfo` | Validator data, usage records for both rounds, and a **projected `roundIndex` and `rotated` flag** after running the same vset rotation check as `UpdateVset`. It also returns the **current `stakeable` amount** — the TON the validator is allowed to use in the current round — computed by applying the exact same validation checks as `NewStake` (round state, parity, usage, limits, balance, owner undercapitalization, etc). The goal is to let off-chain tools know whether a validator is actually eligible to stake and how much, without attempting a real transaction. Because this getter evaluates `rotateRound`, calling it may advance the round state in the same way a real `UpdateVset` message would. |
| `get_validator_info_mtc(workchain: int, hash: int)` | `GetValidatorInfo` | Same as `get_validator_info`, but accepts workchain + hash for masterchain tooling compatibility. |
| `get_proxy_address(validator: address)` | `GetProxyAddressResult` | Even/odd proxy addresses for a given validator. |
| `get_limits_per_validator()` | `(coins, coins, int)` | `(minTonPerValidator, maxTonPerValidator, refundBonus)`. |
| `get_nominator_minimal_stake()` | `GetMinStake` | `(minStake, minExpectedValue)` where `minExpectedValue = minStake + DEPOSIT_GAS`. |
| `get_max_punishment(stake: int)` | `int` | Max punishment fine for a given stake amount, derived from config param 40. |
| `get_pool_invariants()` | `PoolInvariants` | Audit/diagnostic getter that recomputes the cached nominator aggregates (share supply, pending deposits/withdrawals, nominator count) from the primary nominator map and reports whether they match the stored aggregates (`supplyMatch`, `pendingWithdrawalsMatch`, `pendingDepositsMatch`, `nmCountMatch`, `allMatch`). No assertion is performed — it reports only. Also exposes `nominatorsAmount` and a `projectedBalance` (`balance + stakeUsed - pendingDeposits - POOL_MIN_STORAGE`) for off-chain solvency monitoring, plus the recomputed values for debugging. |

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

### Solvency Check
Before processing nominator deposits/withdrawals, the pool verifies that its **projected balance** (`balance - pendingDeposits - POOL_MIN_STORAGE + stakeUsed`) exceeds `nominatorsAmount`; otherwise the message is rejected. The same projected balance is exposed by `get_pool_invariants()` for off-chain solvency monitoring.

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
- Dynamic validator quantity (up to **32** validators).
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

## Scripts

The `scripts/` directory contains standalone Tolk scripts that drive the full pool lifecycle. Each script prompts interactively for any required input (wallet, pool address, amounts, validators, limits) and shows a confirmation dialog before sending a transaction. Set `BATCH=1` to skip the dialog for non-interactive runs.

Scripts run in three modes:

- **Emulation** (default, no `--net`): runs locally, no real transactions. Use this to try things out.
- **Broadcast** (`--net testnet` or `--net mainnet`): sends real transactions using a wallet from `wallets.toml`.
- **TON Connect** (`--net mainnet --tonconnect`): sends real transactions through a TON Connect wallet connected in the browser.

### Operations

#### Deploy the pool

Deploys the pool contract for a given owner and pool ID. Anyone can deploy; the owner initializes afterwards.

```bash
acton script scripts/deploy.tolk --net mainnet
```

#### Initialize the pool

Sets the main validator, owner share, staking limits, refund parameters, and nominator settings. Must be sent by the pool owner. An optional per-validator limit can be set for the main validator during init.

```bash
acton script scripts/init-pool.tolk --net mainnet
```

#### Add funds to the pool

Sends TON to the pool to increase the owner's effective share. Anyone could send.

```bash
acton script scripts/add-funds.tolk --net mainnet
```

#### Add a validator

Whitelists an additional validator with a round allowance (odd / even / all rounds) and an optional per-validator staking limit. Sent by the owner.

```bash
acton script scripts/add-validator.tolk --net mainnet
```

#### Remove a validator

Bans a validator from new stakes. If the validator has outstanding stake, it is banned until recovery completes; otherwise it is removed immediately. The main validator cannot be removed. Sent by the owner.

```bash
acton script scripts/remove-validator.tolk --net mainnet
```

#### Set a per-validator staking limit

Sets an individual TON cap or share cap for a specific validator (main or extra). Sent by the owner.

```bash
acton script scripts/update-validator-limit.tolk --net mainnet
```

#### Update global validator limits

Updates the global min/max TON per validator and refund bonus. Sent by the owner.

```bash
acton script scripts/update-validator-limits.tolk --net mainnet
```

#### Update nominator limits

Updates the max nominator count and min nominator stake. Sent by the owner.

```bash
acton script scripts/update-nominator-limits.tolk --net mainnet
```

#### Update the nominator whitelist

Replaces the nominator whitelist. A non-empty whitelist restricts deposits to the listed addresses; an empty whitelist clears the restriction. Sent by the owner.

```bash
acton script scripts/update-nominators-whitelist.tolk --net mainnet
```

#### Withdraw owner profits

Withdraws the owner's share of accrued profits. If the requested amount exceeds what is available, the transaction is refunded. Sent by the owner.

```bash
acton script scripts/owner-withdrawal.tolk --net mainnet
```

#### Inspect the pool

Read-only script that prints the full pool state or per-validator info. No wallet needed.

```bash
# Pool overview
acton script scripts/pool-info.tolk

# Validator info (interactive picker)
acton script scripts/pool-info.tolk
```

### Running via TON Connect

TON Connect lets you send transactions through a external wallet instead of a local acton key file. The first run opens a local page to connect the wallet; the session is saved and reused by later runs.

```bash
# First run — connect wallet in browser
acton script scripts/init-pool.tolk --net mainnet --tonconnect

# Later runs — reuse the same connection
acton script scripts/add-validator.tolk --net mainnet --tonconnect
acton script scripts/owner-withdrawal.tolk --net mainnet --tonconnect
```

### Batch / non-interactive

Set `BATCH=1` to skip the confirmation dialog. All interactive prompts can be pre-filled via env vars. Note: `coins`-typed env vars (`MSG_VALUE`, `MAX_TON`, `MIN_TON_PER_VALIDATOR`, `VALUE`, etc.) are in **nanograms** (1 TON = 1000000000), while `int`-typed env vars (`MAX_SHARE`, `MAX_NOMINATORS`, `OWNER_SHARE`) are plain integers.

```bash
BATCH=1 \
  POOL_ADDRESS="kQ..." \
  VALIDATOR_ADDRESS="kQ..." \
  LIMIT_KIND=ton \
  MAX_TON=500000000000000 \
  MSG_VALUE=1000000000 \
  acton script scripts/update-validator-limit.tolk --net mainnet --tonconnect
```

---

## References

- [TON Docs — Tolk Overview](https://docs.ton.org/tolk/overview)
- [TON Docs — TON Blockchain](https://docs.ton.org/)
- Original nominator pool and single-nominator pool contracts served as interface and logic references.
- Liquid staking payout NFT approach adapted for loop-free pending operations.
