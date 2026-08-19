# TON Nominator Pool V2 Smart Contract

A Tolk-based smart contract protocol for The Open Network (TON) that enables delegated staking through a **nominator pool**. The contract allows multiple validators to use pool funds for election participation while nominators deposit TON and receive pool shares representing their proportional ownership. Nominators can also withdraw rewards independently without fully exiting the pool. Rewards are auto-compounded into the share price; withdrawals execute directly when liquid funds are available, while pending operations use on-chain payout items to avoid gas-limit loops.

---

## Table of Contents

1. [General Principles](#general-principles)
2. [Differences from the Original TON Nominator Pool](#differences-from-the-original-ton-nominator-pool)
3. [Architecture Overview](#architecture-overview)
4. [Configuration Parameters](#configuration-parameters)
5. [Core Concepts](#core-concepts)
6. [How Rounds Work](#how-rounds-work)
7. [Validator Proxy](#validator-proxy)
8. [Contract Interactions](#contract-interactions)
9. [Fee Structure](#fee-structure)
10. [Getters](#getters)
11. [Security Model](#security-model)
12. [Known Limitations & Implementation Status](#known-limitations--implementation-status)
13. [Build & Test](#build--test)
14. [Scripts](#scripts)
15. [References](#references)

---

## General Principles

### 1. Delegated Staking
The pool aggregates TON from **nominators** (delegators) and makes them available to whitelisted **validators** for participation in the TON validator elections. Recovery profit or loss is split between owner equity and nominators according to `ownerShare`.

### 2. Share-Based Accounting
The pool uses a **share/token model**:
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
- Each validator is assigned **proxy contracts** deployed to the masterchain. The validator's own wallet can be in any workchain.
- Proxies act as dumb, stateless forwarders between the pool and the elector.
- Round parity (odd/even) allows a validator to have up to two proxies, enabling staggered recovery/staking windows. The number of proxies depends on the validator's round allowance: one proxy for odd-only or even-only, two for all rounds.

### 5. Halt on Insufficient Liquidity
If a pending-operation chain cannot be started because the liquid balance cannot cover pending withdrawals, the pool enters a **halted** state. While halted, new validator stakes and owner withdrawals are blocked. Withdrawals and reward claims are routed to pending mode (pending withdrawals remain outstanding throughout the halt), and deposits follow normal round-based logic. Stake recovery and round updates remain available so a later rotation can retry processing and clear the halt.

---

## Differences from the Original TON Nominator Pool

Critical differences are:

1. The v1 validator role is split into an `owner`, who carries out pool management and accrues profit, and a `validator` that is purely technical worker role allowed to only operate staking process with no profit share.
2. Pool can now operate with up to 32 validators, where a single validator is able to stake in two consecutive rounds via its odd/even proxies.
3. Validator expenses are compensated by `refundBonus` for rounds profitable enough to cover the bonus.

### Head to head comparison

#### For Nominators

| Area | Original TON Nominator Pool | This implementation |
|------|-----------------------------|---------------------|
| **Position and rewards** | Stores an address-bound active TON balance and pending deposit balance. Each round's reward is added proportionally to the active balance. | Stores address-bound internal shares priced by `nominatorsAmount / poolSupply`; profit and loss change the share price. Shares are accounting units, **not transferable Jettons or liquid-staking tokens**. |
| **Reward claims** | Rewards compound, but there is no separate claim operation. | Rewards compound and can be claimed with comment `"r"` without withdrawing principal, subject to `minWithdrawableRewards` limit. |
| **Withdrawals** | Comment `"w"` exits the entire position, including pending deposits. Partial withdrawal is unsupported. | Comment `"w"` withdraws all current shares, while `"r"` withdraws rewards. Arbitrary partial-principal withdrawal is unsupported, and `"w"` **does not cancel a pending deposit**, which may enter the pool later. |
| **Pending operations** | Records requests in the pool and pays them through a later permissionless processing call. New staking is blocked while withdrawals remain. | Uses asynchronous per-user `PayoutItem` contracts at clean round boundaries. Insufficient liquidity can halt new stakes and owner withdrawals until recovery and rotation restore progress; nominator withdrawals/rewards are routed to pending mode. |
| **Admission** | Designed and tested for at most 40 nominators and a recommended 10,000 TON minimum stake. Capacity and minimum stake are immutable. | Configures up to 1,023 nominators, subject to dictionary-depth limits. The owner can update the minimum stake and count limit and can apply an optional deposit whitelist. |
| **Workchains and deposit cost** | Nominator wallets must be in the masterchain. Each deposit has a fixed 1 TON deduction. | Nominator wallets may be in any workchain. `DEPOSIT_GAS` is 0.2 TON, with unused gas normally returned; the pool itself runs in the lower-cost basechain. |
| **Penalty exposure** | Losses consume the validator's balance first and reach nominators only when that balance is insufficient. | Profit and loss are split between owner equity and nominators by immutable `ownerShare`. The owner reserve is **not first-loss protection**, so nominators can immediately bear their configured loss share. |
| **Governance** | Nominators can signal on network proposals with `y<HASH>` and `n<HASH>`. | No voting interface is implemented; only `"d"`, `"w"`, and `"r"` nominator comments are accepted. |

#### For Validators

| Area | Original TON Nominator Pool | This implementation |
|------|-----------------------------|---------------------|
| **Validator set** | One immutable validator wallet per pool. | Up to 32 configured validators. Validators can be added, removed, or disabled by the owner. |
| **Wallet and elector access** | The validator wallet and pool both reside in the masterchain, and the wallet operates the pool directly. | Validator wallets may reside in any workchain. Deterministic stateless proxies in the masterchain forward stake and recovery messages to the elector. |
| **Round participation** | The single validator submits one pool stake according to the original state machine. | Each validator can be assigned odd, even, or all rounds. An all-round validator can have two concurrent slots through separate parity proxies. |
| **Stake limits** | Pool-wide immutable minimums and available funds constrain the validator. | Global limits and optional per-validator fixed-TON or proportional-share caps constrain each validator and can be changed by the owner. |
| **Funds and penalties** | The validator maintains its own balance in the pool. This balance receives commission, funds operations, and absorbs losses before nominators. | Validators have no individual pool balance or first-loss account. Owner equity supplies capitalization, while recovered profit or loss is shared globally according to `ownerShare`. |
| **Operating costs** | The original documentation estimates about 5 TON per round, paid by the validator. | A configurable `refundBonus` compensates a validator after a sufficiently profitable recovery. Part is borne by owner equity and part reduces profit before it is split with nominators. |
| **Recovery liveness** | Validator-set updates, recovery, and withdrawal processing can be funded by anyone if the validator disappears. | `UpdateVset` and unrestricted recovery can also be funded by third parties; new stake submission remains validator-only. |

#### For the Pool Owner or Operator

The original contract has no separate owner role: its single immutable validator is also the pool operator and economic counterparty. This implementation separates pool governance from validation.

| Area | Original TON Nominator Pool | This implementation |
|------|-----------------------------|---------------------|
| **Authority** | The immutable validator wallet submits stakes, adds validator funds, and withdraws funds not owed to nominators. | A separate owner manages pool configuration and owner equity. Validators are limited to staking and recovery operations. |
| **Configuration** | Validator address, reward share, capacity, and minimum stakes are fixed at deployment. | The owner can manage validators, validator limits, nominator minimum/count, whitelist, and `refundBonus`. `ownerShare`, `minWithdrawableRewards`, and round allowances remain immutable. |
| **Economics** | Positive reward pays immutable `validator_reward_share`; validator funds bear losses first. | Signed profit and loss are allocated by immutable `ownerShare`. A mutable `refundBonus` may reduce distributable profit, so users should monitor current settings. |
| **Owner withdrawals** | The validator can withdraw its accounted balance and otherwise unallocated funds while preserving nominator liabilities and the storage reserve. | The owner can withdraw only liquid owner equity remaining after nominator liabilities, pending deposits, storage reserve, and punishment capitalization. |
| **Operational scale** | One masterchain pool serves one validator and a small tested nominator set. | One basechain pool coordinates multiple validators through masterchain proxies and processes large pending sets asynchronously. |

Important similarities remain: positions are tied to the depositing address, rewards compound, withdrawals can be delayed by the validator/elector lifecycle and available liquidity, operational maintenance is still required, and nominators can lose principal after validator penalties. Neither implementation gives nominators a freely transferable liquid-staking asset.

The original limits and behavior above are based on its [pool-v1 README](https://github.com/ton-blockchain/nominator-pool/blob/2f35c36b5ad662f10fd7b01ef780c3f1949c399d/README.md) and [TON documentation](https://docs.ton.org/nodes/staking/nominator-pools).

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     NominatorPool                           │
│                    (basechain, wc=0)                        │
├─────────────────────────────────────────────────────────────┤
│  Owner          │  Validators Map  │  Nominators Map        │
│  Pool ID        │  Staking limits  │  Shares / TON amounts  │
│  Owner Share    │  Round usage     │  Pending ops (cells)   │
│  Round state    │  Proxy addresses │  Max count / min stake │
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
| `mainValidator` | `address` | The first validator address, registered during initialization. |
| `roundAllowance` | `RoundAllowance` | Which rounds the validator may participate in: `InOddRounds`, `InEvenRounds`, or `InAllRounds`. |
| `limit` | `ValidatorLimit?` | Optional per-validator staking limit. Can be an absolute TON cap (`ValidatorLimitTon`) or a share of total pool balance (`ValidatorLimitShare`). |
| `ownerShare` | `uint25` | The owner's share of signed recovery profit or loss, expressed as parts of `SHARE_BASE` (2^24). `SHARE_BASE` assigns all profit and loss to owner equity; `0` assigns it all to nominators. |
| `maxTonPerValidator` | `coins` | Global maximum stake any single validator may use from the pool. |
| `minTonPerValidator` | `coins` | Global minimum stake a validator must request for a `new_stake`. |
| `refundBonus` | `uint33` | Flat bonus compensating the validator for the staking "happy path" (NewStake fee + RecoverStake fee + external operational costs), capped at ~8.6 TON. See [Validator Refunds](#validator-refunds-automatic). |
| `nominatorsSettings` | `Cell<NominatorsSettings>` | Encapsulated nominator configuration (see below). |

### Nominator Settings (`NominatorsSettings`)

| Parameter | Type | Description |
|-----------|------|-------------|
| `maxNominators` | `uint10` | Maximum number of distinct nominator entries. Starting an empty pool at `0` creates owner-only mode. Lowering the value later does not block existing nominators from topping up. |
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

- **`ValidatorLimitShare`** — a share of projected pool balance (`maxShare`, expressed as parts of `SHARE_BASE = 16777216`). The calculation includes `stakeUsed` and excludes incoming transaction funding, pending deposits, the current TON value of pending-withdrawal shares, and `POOL_MIN_STORAGE`. The validator can stake up to `maxShare / SHARE_BASE` of this balance per round. This **auto-rebalances as profits accrue**.

The first validator's limit is set during `init-pool`; additional validators get their limit during `add-validator`. Both can be updated later via `update-validator-limit`.

Setting a validator's share limit to `0` effectively **soft-bans** it from new stakes without removing it from the pool — the validator stays registered (preserving its proxies and recovery state) but cannot stake until the limit is raised again. This is useful for any validator that should be temporarily disabled without losing its recovery state.

**Calculating the share:** the share limit is applied per round against the pool's projected balance. Because each validator can have stakes active in both the current and previous round simultaneously (one proxy staking, one recovering), the total number of concurrent stake slots is `sum of round allowances across all validators` (each validator contributes 1 slot per round it participates in: odd-only → 1, even-only → 1, all rounds → 2). To split the pool evenly when all validators use all rounds, set each validator's `maxShare` to `SHARE_BASE / (numValidators × 2)`.

#### Example: 2 validators, each using all rounds

Total concurrent slots = 2 validators × 2 rounds = 4. Each validator should get `SHARE_BASE / 4 = 4194304` (25% per round).

**Interactive:**
```bash
# Initialize with first validator at 25% share cap
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
  DEPLOYER_WALLET="owner" POOL_ADDRESS="kQ..." MAIN_VALIDATOR="kQ..." \
  VALIDATOR_ROUND_ALLOWANCE=3 \
  LIMIT_KIND=share MAX_SHARE=4194304 \
  INIT_VALUE=100000000000000 OWNER_SHARE=8388608 \
  MAX_TON_PER_VALIDATOR=10000000000000000 MIN_TON_PER_VALIDATOR=300000000000000 \
  REFUND_BONUS=3000000000 \
  MAX_NOMINATORS=1023 MIN_STAKE=1000000000000 MIN_WITHDRAWABLE_REWARDS=1000000000 \
  acton script scripts/init-pool.tolk --net mainnet

# Add second validator
BATCH=1 \
  DEPLOYER_WALLET="owner" POOL_ADDRESS="kQ..." VALIDATOR_ADDRESS="kQ..." \
  VALIDATOR_ROUND_ALLOWANCE=3 LIMIT_KIND=share MAX_SHARE=4194304 \
  ADD_VALIDATOR_VALUE=10000000000000 \
  acton script scripts/add-validator.tolk --net mainnet
```

Each validator can stake up to 25% of the pool per round. With both rounds active (one staking, one recovering), each validator effectively uses up to 50% of the pool across its two rounds, and the two validators together can utilize the full pool.

#### Example: 2 validators, one odd-only and one even-only

Each validator participates in only one round parity, so each has 1 concurrent slot. Total concurrent slots = 1 + 1 = 2. Each validator should get `SHARE_BASE / 2 = 8388608` (50% per round).

```bash
# Initialize with first validator (odd rounds) at 50% share cap
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
# Initialize with first validator at ~16.7% share cap
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
  DEPLOYER_WALLET="owner" POOL_ADDRESS="kQ..." MAIN_VALIDATOR="kQ..." \
  VALIDATOR_ROUND_ALLOWANCE=3 \
  LIMIT_KIND=share MAX_SHARE=2796203 \
  INIT_VALUE=100000000000000 OWNER_SHARE=8388608 \
  MAX_TON_PER_VALIDATOR=10000000000000000 MIN_TON_PER_VALIDATOR=300000000000000 \
  REFUND_BONUS=3000000000 \
  MAX_NOMINATORS=1023 MIN_STAKE=1000000000000 MIN_WITHDRAWABLE_REWARDS=1000000000 \
  acton script scripts/init-pool.tolk --net mainnet

# Add second and third validators
BATCH=1 DEPLOYER_WALLET="owner" POOL_ADDRESS="kQ..." VALIDATOR_ADDRESS="kQ_2..." \
  VALIDATOR_ROUND_ALLOWANCE=3 LIMIT_KIND=share MAX_SHARE=2796203 \
  ADD_VALIDATOR_VALUE=10000000000000 \
  acton script scripts/add-validator.tolk --net mainnet

BATCH=1 DEPLOYER_WALLET="owner" POOL_ADDRESS="kQ..." VALIDATOR_ADDRESS="kQ_3..." \
  VALIDATOR_ROUND_ALLOWANCE=3 LIMIT_KIND=share MAX_SHARE=2796203 \
  ADD_VALIDATOR_VALUE=10000000000000 \
  acton script scripts/add-validator.tolk --net mainnet
```

Each validator can stake up to ~16.7% of the pool per round. Across both rounds, each validator effectively uses up to ~33% of the pool, and the three validators together can utilize the full pool.

#### Soft-ban via zero share limit

To temporarily disable a validator, set its share limit to 0:

```bash
# Interactive
acton script scripts/update-validator-limit.tolk --net mainnet
# Pick the validator, then: share, maxShare = 0

# Batch
BATCH=1 DEPLOYER_WALLET="owner" POOL_ADDRESS="kQ..." VALIDATOR_ADDRESS="kQ..." \
  LIMIT_KIND=share MAX_SHARE=0 MSG_VALUE=1000000000 \
  acton script scripts/update-validator-limit.tolk --net mainnet
```

The validator stays registered but cannot stake. Raise the share limit above 0 to re-enable it.

---

## Core Concepts

### Shares and Pricing
- **Deposit**: `shares = depositAmount * poolSupply / nominatorsAmount`.
- **Withdrawal**: `tonValue = shares * nominatorsAmount / poolSupply`.
- Integer division floors deposit shares and withdrawal TON amounts. Reward withdrawals also floor the number of shares burned, favoring the nominator by less than one share unit.

### Rounds and Rotation
- `roundIndex` increments only after a clean rotation. If the validator set changes while `prevRound` still has usage records, the round closes without incrementing.
- `curRound` and `prevRound` store usage records (maps of `proxy_hash → TonUsage`). The proxy hash is the 256-bit address hash (without workchain prefix), reducing storage footprint and simplifying lookup consistency between round data and validator data.
- Validators can stake in the current round if the round is open, elections are active, and they have no prior usage in that round.
- `RecoverStake` requires at least two validator-set changes observed by pool calls. At exactly two changes, the configured holding period plus a 60-second margin must also have elapsed since the last observed rotation; after more than two, the timestamp is irrelevant.

### Pending Operations
To avoid unbounded map iteration inside a single transaction:
- **Pending deposits** and **pending withdrawals** are materialized as linked **PayoutItem** contracts.
- At round rotation, the pool triggers a chain of burns; each `PayoutItem` sends a `PayoutBurnNotification` back to the pool, which then finalizes the deposit/withdrawal one by one across multiple transactions.
- If insufficient liquidity prevents a chain from starting, the pool halts; nominator withdrawals and rewards requested during the halt are queued as pending, and a later rotation retries processing.

### Punishment / Slashing Reserve
The pool requires owner equity to participate in validator risk. Before each `new_stake`, after counting the prospective slot, the contract checks that owner equity is at least the worst-case punishment fine for a minimum-size stake multiplied by the resulting number of active slots. The punishment amount is derived from TON config param 40 (misbehavior fines), scaled by severity and duration multipliers. Recovery losses are still split between owner equity and nominators according to `ownerShare`; this reserve is a capitalization requirement, not first-loss protection for nominators.

### Validator Refunds (Automatic)

Validators **do not need to maintain a separate wallet balance** to track gas/TON tied up in the pool. The contract compensates the validator for the staking "happy path" costs via a single flat **`refundBonus`** parameter.

For accounting, the bonus is split into two parts. The **owner-only part** is one third of `refundBonus`, capped at 1 TON, and is borne entirely by owner equity. The remaining **shared part** is deducted from the recovered value before the residual profit or loss is divided according to `ownerShare`, so owner and nominators bear that part together.

- On successful `recover_stake_ok`, the pool calculates net profit (recovered amount minus staked amount).
- If the round was unprofitable (slashed or no profit), no bonus is paid. The validator's overspend on unsuccessful operations must be resolved directly with the pool owner if necessary.
- `refundBonus` is configured at initialization and can be updated later via `UpdateLimits`.

#### `refundBonus` explained

When a validator recovers a stake, the elector returns the staked TON plus any validation profit. The `refundBonus` is a flat amount that bundles three cost components:

1. **NewStake fee** (~1 TON) — covered by the owner-only part. The owner bears this alone because most of the NewStake value is not actually spent — the elector refunds it back to the proxy with `NewStakeOk`, so it returns to the pool rather than being consumed. Only forwarding fees and elector gas are truly lost, so assigning this part solely to the owner avoids diluting nominator profit for a cost that largely returns.
2. **RecoverStake fee** (~1 TON) — covered by the split part.
3. **External operational bonus** — the remainder of the split part, compensating for the validator's own wallet gas, forwarding fees, and transaction costs outside the pool.

The full bonus is paid only when profit exceeds the shared part. The shared part is taken before allocating the remaining profit; the owner-only part is charged to owner equity.

The **trust boundary** between the owner and nominators is `refundBonus`. The owner sets it, and nominators rely on the owner choosing a reasonable value. It is capped at approximately 8.6 TON and paid only when profit exceeds the shared part.

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

Because staking/recovery must happen on the masterchain where the elector resides, each validator is given one or two **proxy contracts** deployed to the masterchain, depending on its round allowance (odd-only → 1 proxy, even-only → 1 proxy, all rounds → 2 proxies).
- **Even proxy** — used in rounds where `roundIndex` is even
- **Odd proxy** — used in rounds where `roundIndex` is odd

Round parity is encoded as a **bit index**: even rounds map to bit 2 and odd rounds to bit 1.

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

If `prevRound.users` is **not empty**, the pool **closes the round** instead:
- `roundClosed = true`
- No new stakes are accepted until the round re-opens (all outstanding stakes must be recovered first).

### Active Slots and `stakeUsed`

The pool tracks global round-level metrics:
- **`activeSlots`**: number of unrecovered stake usages in the current or previous round. An all-round validator can occupy two slots simultaneously.
- **`stakeUsed`**: total TON currently locked in elector stakes.

When a `NewStake` succeeds, `activeSlots++` and `stakeUsed += tonUsed`.
When a `RecoverStakeOk` arrives, `activeSlots--` and `stakeUsed -= tonUsed`.

### New Stake Timing (Elections Window)

The contract only accepts `NewStake` during the election window, tracked via TON config parameter 15. Outside this window, stakes are rejected even if the round is technically open.

### Stake Recovery Timing

A validator cannot recover a stake immediately after staking. Each usage record carries a `RotationData` structure that tracks:
- `vsetHash`: validator set hash at the time of staking
- `rotationTime`: staking time initially, then the timestamp of the latest validator-set change observed by a pool call
- `rotationCount`: how many distinct validator-set changes have been observed for this usage

Recovery is only permitted after at least two distinct validator-set changes have been observed for that usage. When exactly two changes have been observed, recovery must additionally wait until the configured holding period (`heldFor`) plus a 60-second safety margin has elapsed since the last observed rotation. After more than two changes, the timestamp condition no longer applies. This enforces the configured holding period plus a safety margin in the two-change case.

### Round Closure and Re-Opening

If the vset changes while `prevRound` still contains unrecovered stakes, the pool **closes** the current round:
- `roundClosed = true`
- New stakes are forbidden
- Validators must recover their outstanding stakes

When recovery empties the affected round, `RecoverStakeOk` sends an asynchronous `UpdateVset` message to the pool itself. Rotation and pending-operation processing occur in that later transaction.

### Processing Pending Operations at Boundaries

Whenever `UpdateVset` completes a clean rotation, the pool checks for pending nominator deposits and withdrawals:
- If `pendingDeposits > 0` or `pendingWithdrawals > 0`, the pool loads the `NominatorsData` and processes them.
- This results in `halted = true` when liquid balance is below the payout-chain startup threshold or cannot cover pending withdrawals.
- While halted, new validator stakes and owner withdrawals are blocked; nominator withdrawals and reward claims route to pending mode. Stake recovery and `UpdateVset` remain available.

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

If the elector bounces a `NewStakeElector` or `RecoverStakeCompat` message, the proxy synthesizes a corresponding error and forwards it to the pool with `ProxyResponseData`. A `NewStakeError` unwinds the temporary usage record. A recovery error leaves usage active so recovery can be retried.

### Unfreeze Resilience

Proxy addresses are derived deterministically from proxy code and `(pool, validator, roundParity)`. Recovery requests include proxy `StateInit`, allowing a frozen proxy to be restored. `NewStake` targets the plain proxy address and can bounce if that proxy is frozen.

---

## Contract Interactions

### Nominator Operations (Text Comments)

Nominators interact with the pool using an exact text-comment body: a 32-bit zero prefix followed by one ASCII byte `d`, `w`, or `r`, with no trailing bits or references.

| Comment | Action |
|---------|--------|
| `"d"` | **Deposit**: TON minus `DEPOSIT_GAS` is converted to shares. If the round is closed or there are still unrecovered stakes in the previous round, funds go into a pending deposit queue. |
| `"w"` | **Full Withdrawal**: Withdraws all current shares. It becomes pending if the round is closed, liquid balance is insufficient, or the nominator already has a pending operation. A pending deposit is retained rather than cancelled. |
| `"r"` | **Reward Withdrawal**: Withdraws only profit (share value minus the deposit baseline). It uses the same pending conditions as other withdrawals. |

### Validator Operations

| Message | Sender | Effect |
|---------|--------|--------|
| `NewStake` | Validator | Uses pool TON and forwards it (via proxy) to the elector. Records usage in the current round. |
| `RecoverStakeCompat` | Validator | Requests stake recovery through the validator's proxy. Enforces timing and rotation checks. |
| `RecoverStakeUnrestricted` | Any | Allows a third party to fund recovery. Requested and forwarded funding is capped at `MAX_RECOVERY_VALUE`; the caller must also cover gas and forwarding fees. |

### Owner Operations

| Message | Effect |
|---------|--------|
| `InitPoolMessage` | Transitions contract from uninitialized to active. Deploys one or two main-validator proxies according to round allowance and sets all parameters. |
| `AddValidator` | Whitelists an additional validator and deploys one or two proxies according to round allowance. |
| `RemoveValidator` | Removes an idle validator immediately. A validator with active usage remains stored and banned from new stakes. |
| `UpdateLimits` | Adjusts global or per-validator staking/nominator limits. |
| `UpdateNominatorsWhitelist` | Replaces the nominator whitelist. If the whitelist is non-empty, only listed addresses may deposit. |
| `OwnerWithdrawal` | Withdraws available owner equity, including contributed principal, after nominator liabilities, pending deposits, storage reserve, and punishment capitalization are accounted for. |
| `AddFunds` | Permissionless typed message that adds TON to owner equity. |

---

## Fee Structure

All fees are defined in `contracts/fees.tolk`:

| Constant | Value | Purpose |
|----------|-------|---------|
| `POOL_MIN_STORAGE` | 10 TON | Normal pool storage reserve used by balance and solvency calculations. Emergency paths may spend into it. |
| `PROXY_MIN_STORAGE` | 10 TON | Target storage reserve for each deployed validator proxy. Extreme recovery handling may spend into it. |
| `DEPOSIT_GAS` | 0.2 TON | Amount excluded from every deposit before shares are calculated. It funds execution; unused message value is normally returned with the notification. |
| `WITHDRAWAL_GAS` | 0.2 TON | Minimum inbound value when a withdrawal enters the pending queue. The later burn chain is started separately with `PAYOUT_ITEM_BALANCE`; direct withdrawals do not have this gate. |
| `NEW_VALIDATOR_FEE` | 0.1 TON | Gas budget deducted when adding a new validator. |
| `PAYOUT_ITEM_BALANCE` | 0.05 TON | Forwarded to each PayoutItem on deployment. |
| `REFUND_THRESHOLD` | 1 TON | Caps the owner-only bonus component and the `NewStake` value retained for refund/gas handling. |
| `MAX_RECOVERY_VALUE` | 1 TON | Caps funding forwarded from the pool to the proxy/elector for a recovery request. It does not cap recovered stake returned to the pool. |
| `PROXY_INIT_VALUE` | 0.1 TON | Extra value attached on top of `PROXY_MIN_STORAGE` when deploying a validator proxy, to cover init gas. |

In addition, `fees.tolk` defines a gas-budget *constant* (in gas units, not TON) used by compute-path checks: `RECOVER_STAKE_OK_GAS`. This is an internal compute budget, not a user-facing fee.

---

## Getters

The pool exposes several getters for off-chain queries. Only `owner()` and `get_pool_id()` support uninitialized storage; all other getters below require initialization.

| Getter | Returns | Description |
|--------|---------|-------------|
| `owner()` | `address` | Pool owner address. Works in both uninitialized and active states. |
| `get_pool_id()` | `uint32` | Pool ID. Works in both uninitialized and active states. |
| `get_pool_data()` | `Storage` | Full pool state (owner, shares, round status, validator data, nominators, etc.). Only available after initialization. |
| `get_nominator_data(nominatorAddress: int)` | `GetNominatorData` | Nominator info from a 256-bit address hash. Searches workchain `0` and then `-1`, and throws 86 if absent. It cannot query other workchains or disambiguate identical hashes in both searched workchains. |
| `get_validator_info(address: address)` | `GetValidatorInfo` | Validator data, usage records, and a read-only projected `roundIndex`/`rotated` result. `stakeable` checks banned, closed and halted state, parity, usage, config-17 bounds, limits, balance, minimum stake, and owner capitalization. It intentionally omits election timing and message/body checks. The getter never persists projected rotation. |
| `get_validator_info_mtc(workchain: int, hash: int)` | `GetValidatorInfo` | Same as `get_validator_info`, but accepts workchain + hash for masterchain tooling compatibility. |
| `get_proxy_address(validator: address)` | `GetProxyAddressResult` | Even/odd proxy addresses for a given validator. |
| `get_limits_per_validator()` | `(coins, coins, int)` | `(minTonPerValidator, maxTonPerValidator, refundBonus)`. |
| `get_nominator_minimal_stake()` | `GetMinStake` | `(minStake, minExpectedValue)` where `minExpectedValue = minStake + DEPOSIT_GAS`. |
| `get_max_punishment(stake: int)` | `int` | Raises input below `minTonPerValidator` to that minimum, rejects input above `maxTonPerValidator`, and returns the config-40 maximum fine capped by stake. If config 40 is absent, the fallback is 101 TON. |
| `get_pool_invariants()` | `PoolInvariants` | Audit/diagnostic getter that recomputes the cached nominator aggregates (share supply, pending deposits/withdrawals, nominator count) from the primary nominator map and reports whether they match the stored aggregates (`supplyMatch`, `pendingWithdrawalsMatch`, `pendingDepositsMatch`, `nmCountMatch`, `allMatch`). No assertion is performed — it reports only. Also exposes `nominatorsAmount` and a `projectedBalance` (`balance + stakeUsed - pendingDeposits - POOL_MIN_STORAGE`) for off-chain solvency monitoring, plus the recomputed values for debugging. |

---

## Security Model

### Role Separation
- **Owner**: Controls economics (profit/loss share, validator and nominator whitelists, and limits). Can withdraw available owner equity.
- **Validator**: Only acts as the technical operator (new/recover stake). Cannot touch nominator funds directly.
- **Nominator**: Only depositor/withdrawer. Cannot influence validator operations.

### Proxy Authentication
All elector responses (`NewStakeOk`, `NewStakeError`, `RecoverStakeOk`, `RecoverStakeError`) are authenticated by deriving the expected proxy address from proxy code and `(pool, validator, roundParity)`. This prevents spoofed responses.

### Owner Share requirements
Before `new_stake`, the contract ensures owner equity covers the worst-case minimum-stake punishment multiplied by the resulting active slot count. Recovery losses are nevertheless split according to `ownerShare`.

### Solvency Check
Before processing nominator deposits/withdrawals, the pool verifies that its **projected balance** (`balance - pendingDeposits - POOL_MIN_STORAGE + stakeUsed`) exceeds `nominatorsAmount`; otherwise the message is rejected. The same projected balance is exposed by `get_pool_invariants()` for off-chain solvency monitoring.

### Bounce Handling
If a `new_stake` message bounces (e.g., proxy frozen or elector rejection), the usage record is automatically reversed and the validator's locked funds are released.

### Halt / Graceful Degradation
If liquidity prevents pending processing from starting, the pool sets `halted = true`. While halted, new validator stakes and owner withdrawals are blocked; nominator withdrawals and reward claims are routed to pending mode. A later rotation retries processing; asynchronous payout notifications may still be in flight when the halt clears.

---

## Known Limitations & Implementation Status

### Implemented optional features
- Configurable nominator quantity and minimum stake.
- Configurable per-validator and global staking limits, validated against network config 17 bounds.
- Nominator whitelist: owner can restrict deposits to a specific set of addresses via `NominatorsSettings.whitelist` or `UpdateNominatorsWhitelist`.
- Reward withdrawal via `"r"` comment.
- Dynamic validator quantity (up to **32** validators).
- Owner-only mode: initialize an empty pool with `maxNominators = 0` to prevent creation of nominator records. Existing nominators can still top up if the limit is lowered later.

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

The `scripts/` directory contains standalone Tolk scripts for deployment, initialization, owner administration, and inspection. Each script prompts for missing inputs and shows a confirmation dialog before sending. `BATCH=1` skips confirmation only; provide every prompted value through environment variables for a fully non-interactive run.

Scripts run in three modes:

- **Emulation** (default, no `--net`): runs locally, no real transactions. Use this to try things out.
- **Broadcast** (`--net testnet` or `--net mainnet`): sends real transactions using a wallet from `wallets.toml`.
- **TON Connect** (`--net mainnet --tonconnect`): sends real transactions through a TON Connect wallet connected in the browser.

### Operations

#### Deploy the pool

Derives and deploys an uninitialized pool in basechain workchain 0 for a given owner and pool ID. Anyone can deploy; the owner initializes it in a separate transaction.

```bash
acton script scripts/deploy.tolk --net mainnet
```

#### Initialize the pool

Sets the first validator, its round allowance (`1=odd`, `2=even`, `3=all`), owner share, staking limits, refund parameters, and nominator settings. Must be sent by the pool owner. Set `VALIDATOR_ROUND_ALLOWANCE` for batch use. The initial whitelist is empty and can be updated afterward.

```bash
acton script scripts/init-pool.tolk --net mainnet
```

#### Add funds to the pool

Sends an `AddFunds` message to increase owner equity. The contract accepts it from anyone; the supplied script sends from the selected owner wallet.

```bash
acton script scripts/add-funds.tolk --net mainnet
```

#### Add a validator

Whitelists an additional validator with a round allowance (odd / even / all rounds) and an optional per-validator staking limit. Sent by the owner.

```bash
acton script scripts/add-validator.tolk --net mainnet
```

#### Remove a validator

Removes an idle validator immediately. If it has active usage, its record remains banned from new stakes so recovery can complete. Sent by the owner.

```bash
acton script scripts/remove-validator.tolk --net mainnet
```

#### Set a per-validator staking limit

Sets an individual TON cap or share cap for a specific validator. Sent by the owner.

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

#### Withdraw owner equity

Withdraws available owner equity after contract reserves and liabilities are accounted for. If the requested amount exceeds what is available, the transaction is refunded. Sent by the owner.

```bash
acton script scripts/owner-withdrawal.tolk --net mainnet
```

#### Inspect the pool

Read-only script that prints the full pool state or per-validator info. No wallet is needed. Add `--net mainnet` or `--net testnet` for a live pool; without `--net`, it reads the local emulator snapshot.

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

Set `BATCH=1` to skip the confirmation dialog. It does not suppress missing-input prompts; provide all required environment variables, including `DEPLOYER_WALLET` for wallet-backed operations. `coins`-typed env vars (`MSG_VALUE`, `MAX_TON`, `MIN_TON_PER_VALIDATOR`, `VALUE`, etc.) are in **nanograms** (1 TON = 1000000000), while integer settings (`MAX_SHARE`, `MAX_NOMINATORS`, `OWNER_SHARE`, `VALIDATOR_ROUND_ALLOWANCE`) are plain integers.

```bash
BATCH=1 \
  DEPLOYER_WALLET="owner" \
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
- [Original TON Nominator Pool](https://github.com/ton-blockchain/nominator-pool/tree/2f35c36b5ad662f10fd7b01ef780c3f1949c399d) and single-nominator pool contracts served as interface and logic references.
- [TON Docs — Nominator Pool Contracts](https://docs.ton.org/nodes/staking/nominator-pools)
- Liquid staking payout NFT approach adapted for loop-free pending operations.
