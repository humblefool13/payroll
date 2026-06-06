# Web3 Payroll — Technical Specification & Audit Plan

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Contract Architecture](#2-contract-architecture)
3. [PayrollFactory — Full Feature Spec](#3-payrollfactory--full-feature-spec)
4. [PayrollPool — Full Feature Spec](#4-payrollpool--full-feature-spec)
5. [Data Model & Invariants](#5-data-model--invariants)
6. [Security Properties](#6-security-properties)
7. [Known Limitations & Gas Considerations](#7-known-limitations--gas-considerations)
8. [Multi-Agent Audit Plan](#8-multi-agent-audit-plan)
9. [Deployment Checklist](#9-deployment-checklist)

---

## 1. System Overview

A non-custodial, pull-payment payroll platform on EVM. Any wallet can deploy a **PayrollPool** through the **PayrollFactory**. The pool admin deposits funds (ETH or whitelisted ERC-20s), sets recurring allocations for beneficiaries, and beneficiaries pull their accrued pay on-demand.

The platform owner earns a fee (in basis points, capped at 1%) on every withdrawal — both admin withdrawals and beneficiary claims.

**Key design choices:**
- Pull-based claiming — no automatic transfers, no keeper required.
- Unclaimed amounts accumulate indefinitely; they are never forfeited.
- Edits to allocation rates create tranche boundaries; historical accrual is immutable.
- Token whitelist is additive-only; once whitelisted, a token cannot be removed (pools depend on it).
- Pool authenticity is enforced by a registry in the factory (`isDeployedPool`), not by trusting values returned from pool contracts.

---

## 2. Contract Architecture

```
PayrollFactory  (Ownable)
│
│  deployPool() → creates PayrollPool, registers in isDeployedPool
│  setFeeBps()  → platform fee, max 100 bps (1%)
│  whitelistToken()
│  collectFees()
│  registerBeneficiary()  ← called by pools only
│  recordFee()            ← called by pools only
│
└── PayrollPool  (Ownable + ReentrancyGuard)   [1..N per factory]
       │
       │  depositETH / depositToken
       │  adminWithdraw
       │  setAllocation / removeAllocation
       │  claim
       │  pausePool / unpausePool / closePool
       │
       └── _tranches[beneficiary][token][]   (append-only tranche log)
```

### Dependency graph

```
PayrollPool  →  IPayrollFactory  (interface, not concrete)
PayrollFactory  →  PayrollPool   (only for new PayrollPool(...) in deployPool)
```

The pool calls the factory only through `IPayrollFactory` to read `feeBps`, `tokenWhitelisted`, `registerBeneficiary`, and `recordFee`. The factory calls no pool functions after deployment — all pool-origin validation uses `isDeployedPool[msg.sender]`.

---

## 3. PayrollFactory — Full Feature Spec

### 3.1 State

| Variable | Type | Description |
|---|---|---|
| `feeBps` | `uint256` | Platform fee in bps. Max `MAX_FEE_BPS` (100). Default 0. |
| `MAX_FEE_BPS` | `uint256 constant` | Hard cap = 100 (1%). |
| `accruedFees[token]` | `mapping` | Fees collected per token waiting for withdrawal. `address(0)` = ETH. |
| `tokenWhitelisted[token]` | `mapping` | Additive-only whitelist. ETH (`address(0)`) is pre-whitelisted at deploy. |
| `isDeployedPool[pool]` | `mapping` | Source of truth for pool authenticity. Set on `deployPool()`, never unset. |
| `_adminPools[admin]` | `mapping` | Ordered list of pools where `admin` is owner. |
| `_beneficiaryPools[beneficiary]` | `mapping` | Ordered list of pools where `beneficiary` has at least one allocation. |

### 3.2 Functions

#### `setFeeBps(uint256 newFeeBps)` — `onlyOwner`
- Reverts with `FeeTooHigh` if `newFeeBps > MAX_FEE_BPS`.
- Emits `FeeBpsSet(oldFeeBps, newFeeBps)`.
- Takes effect immediately; all future fee calculations in pools read live from factory.

#### `whitelistToken(address token)` — `onlyOwner`
- Reverts with `AlreadyWhitelisted` if already listed.
- **Never destructive.** Once added, a token stays on the whitelist permanently.
- ETH (`address(0)`) is whitelisted in the constructor.
- Emits `TokenWhitelisted(token)`.

#### `collectFees(address token, address payable to)` — `onlyOwner`
- Reverts with `NothingToCollect` if `accruedFees[token] == 0`.
- Zeroes out `accruedFees[token]` before transferring (CEI pattern).
- For ETH: uses low-level `.call{value: amount}("")`; reverts with `ETHTransferFailed` on failure.
- For ERC-20: uses `SafeERC20.safeTransfer`.
- Emits `FeeCollected(token, to, amount)`.

#### `deployPool()` — public
- Deploys a new `PayrollPool(msg.sender, address(this))`.
- Registers the pool address in `isDeployedPool` and `_adminPools[msg.sender]`.
- Emits `PoolDeployed(pool, admin)`.
- Returns the new pool address.

#### `registerBeneficiary(address beneficiary, address pool)` — pool-only
- Reverts with `NotAValidPool` if `isDeployedPool[pool]` is false.
- Reverts with `OnlyPool` if `msg.sender != pool`.
- Appends `pool` to `_beneficiaryPools[beneficiary]`.
- Called once per beneficiary per pool (enforced in `PayrollPool._everRegistered`).

#### `recordFee(address token, uint256 amount)` — pool-only, `payable`
- Reverts with `NotAValidPool` if `isDeployedPool[msg.sender]` is false.
- For ETH: reverts with `ETHValueMismatch` if `msg.value != amount`.
- Increments `accruedFees[token] += amount`.

### 3.3 Events

| Event | Trigger |
|---|---|
| `PoolDeployed(pool, admin)` | New pool deployed |
| `FeeBpsSet(old, new)` | Fee changed |
| `TokenWhitelisted(token)` | Token added to whitelist |
| `FeeCollected(token, to, amount)` | Owner pulls fees |

---

## 4. PayrollPool — Full Feature Spec

### 4.1 State

| Variable | Description |
|---|---|
| `factory` | Immutable address of the factory that deployed this pool. |
| `paused` | When true, beneficiary `claim()` is blocked. Admin functions remain available. |
| `closed` | Permanent. Blocks deposits and new allocations. All tranches frozen at close timestamp. |
| `poolBalance[token]` | Tracked balance per token. Updated on deposit, withdrawal, claim, fee send. |
| `_tranches[b][token][]` | Append-only tranche history per (beneficiary, token). |
| `_claimed[b][token]` | Cumulative amount paid out. Never decreases. |
| `_beneficiaries[]` | All beneficiaries ever added (for `_totalCommitted` iteration). |
| `_beneficiaryTokens[b][]` | All tokens ever allocated to beneficiary `b`. |

### 4.2 Tranche Model

Each tranche represents one contiguous rate epoch:

```
struct Tranche {
    uint256 amountPerPeriod;  // rate
    uint256 startTime;        // first period start (unix timestamp)
    uint256 periodSeconds;    // 7d / 30d / 90d
    uint256 endTime;          // 0 = active; else sealed timestamp
}
```

**Accrual formula per tranche:**

```
effectiveEnd  = (endTime == 0) ? block.timestamp : endTime
periodsEarned = floor((effectiveEnd - startTime) / periodSeconds)   // if effectiveEnd > startTime, else 0
trancheAccrued = periodsEarned * amountPerPeriod
```

**Total claimable:**

```
totalAccrued = Σ trancheAccrued over all tranches
claimable    = totalAccrued - _claimed[beneficiary][token]
```

**Edit semantics:**  
When `setAllocation` is called on an existing active allocation, the current tranche's `endTime` is set to `block.timestamp`. A new tranche is pushed with the new rate and the caller-supplied `startTime`. Because `_claimed` is never reset, past pay is already accounted for — the new tranche rate only affects future periods.

### 4.3 Frequencies

| Enum | Seconds |
|---|---|
| `WEEKLY` | `7 days` (604 800 s) |
| `MONTHLY` | `30 days` (2 592 000 s) |
| `QUARTERLY` | `90 days` (7 776 000 s) |

### 4.4 Functions

#### `depositETH()` — `onlyOwner`, `notClosed`, `payable`
- Checks ETH is whitelisted in factory (always true given constructor whitelist).
- `poolBalance[address(0)] += msg.value`.
- Emits `Deposited(address(0), admin, amount)`.

#### `depositToken(address token, uint256 amount)` — `onlyOwner`, `notClosed`
- Reverts with `UseDepositETH` if `token == address(0)`.
- Reverts with `TokenNotWhitelisted` if not on factory whitelist.
- Records balance before/after to handle fee-on-transfer tokens correctly.
- `poolBalance[token] += received`.
- Emits `Deposited(token, admin, received)`.

#### `adminWithdraw(address token, uint256 amount)` — `onlyOwner`, `nonReentrant`
- Computes `available = poolBalance[token] - _totalCommitted(token)`.
- Reverts with `AmountExceedsAvailable` if `amount > available`.
- Deducts fee: `fee = amount * feeBps / 10_000`. Net = `amount - fee`.
- Decrements `poolBalance[token] -= amount` before external calls (CEI).
- Sends fee to factory via `_sendFee`; sends net to admin via `_transfer`.
- Emits `AdminWithdrew(token, admin, net, fee)`.

#### `setAllocation(address beneficiary, address token, uint256 amountPerPeriod, Frequency frequency, uint256 startTime)` — `onlyOwner`, `notClosed`
- Reverts: `ZeroBeneficiary`, `TokenNotWhitelisted`, `ZeroAmount`, `StartTimeInPast`.
- Seals active tranche (if any) at `block.timestamp`.
- Pushes new tranche with `endTime = 0`.
- Registers beneficiary in factory (once per beneficiary per pool).
- Emits `AllocationSet(beneficiary, token, amountPerPeriod, startTime, frequency)`.

#### `removeAllocation(address beneficiary, address token)` — `onlyOwner`
- Reverts with `NoAllocation` if no tranches exist.
- Reverts with `AllocationAlreadyRemoved` if last tranche already sealed.
- Sets `endTime = block.timestamp` on the last tranche. Future periods stop accruing. Past accrual remains claimable forever.
- Emits `AllocationRemoved(beneficiary, token)`.
- **Does not remove beneficiary from factory registry** — they can still claim past amounts.

#### `claim(address token)` — `nonReentrant`, `notPaused`
- Reverts with `NothingToClaim` if claimable == 0.
- Reverts with `PoolUnderfunded` if `poolBalance[token] < claimable`.
- CEI: increments `_claimed`, decrements `poolBalance` before external calls.
- Fee: `fee = claimable * feeBps / 10_000`. Net = `claimable - fee`.
- Emits `Claimed(beneficiary, token, net, fee)`.

#### `pausePool()` / `unpausePool()` — `onlyOwner`, `notClosed`
- `pausePool`: reverts with `PoolAlreadyPaused`.
- `unpausePool`: reverts with `PoolNotPaused`.
- Pausing blocks `claim()`. All admin operations remain available.
- Emits `PoolPausedEvent` / `PoolUnpausedEvent`.

#### `closePool()` — `onlyOwner`
- Reverts with `PoolAlreadyClosed`.
- Sets `closed = true`. Calls `_freezeAllTranches()` to seal all active tranches at `block.timestamp`.
- After close: no deposits, no new allocations; admin may withdraw uncommitted funds; beneficiaries may claim accrued amounts.
- Emits `PoolClosedEvent`.

### 4.5 View Functions

| Function | Returns |
|---|---|
| `claimableAmount(beneficiary, token)` | Current claimable amount |
| `nextUnlockTime(beneficiary, token)` | Timestamp of next period unlock; 0 if inactive |
| `getAllocations(beneficiary)` | `AllocationView[]` — one entry per token ever allocated |
| `getBeneficiaries()` | All beneficiary addresses ever added to this pool |
| `totalCommitted(token)` | Sum of claimable across all beneficiaries for a token |

### 4.6 Events (transaction log for UI)

| Event | Who sees it | Data |
|---|---|---|
| `Deposited` | Admin log | token, from, amount |
| `AdminWithdrew` | Admin log | token, to, net, fee |
| `AllocationSet` | Admin log | beneficiary, token, rate, startTime, frequency |
| `AllocationRemoved` | Admin log | beneficiary, token |
| `Claimed` | Admin log + beneficiary | beneficiary, token, net, fee |
| `PoolPausedEvent` | Admin log | — |
| `PoolUnpausedEvent` | Admin log | — |
| `PoolClosedEvent` | Admin log | — |

---

## 5. Data Model & Invariants

### Critical invariants

1. **Balance accounting:** `poolBalance[token]` always equals the actual token balance held by the contract minus any tokens in transit during the current call.

2. **Committed funds protection:** `adminWithdraw` can never withdraw `_totalCommitted(token)` — the sum of all beneficiary claimable amounts.

3. **Claimed monotonicity:** `_claimed[b][token]` only ever increases. It is never reset on allocation edit or removal.

4. **Tranche ordering:** Tranches for a given `(beneficiary, token)` are append-only. `tranche[i].endTime <= tranche[i+1].startTime` for all sealed pairs. (Can be equal if new tranche starts immediately.)

5. **No double-counting:** Because `_claimed` persists across tranche edits, total paid out + claimable always equals total accrued across all tranches.

6. **Fee consistency:** `fee + net == gross` for every claim/withdrawal. No rounding error can result in more than `gross` leaving the pool.

7. **Pool authenticity:** `isDeployedPool[x]` is true only for contracts created by `PayrollFactory.deployPool()`.

### Edge cases encoded in tests

- Partial period at tranche seal time is dropped (floor division).
- Future `startTime` on a new tranche creates an intentional gap; nothing accrues during the gap.
- `closePool` freezes tranches at the close timestamp; time after close does not add accrual.
- Admin can withdraw remaining balance after close, as long as committed amounts are preserved.

---

## 6. Security Properties

### Access control matrix

| Operation | Factory Owner | Pool Admin | Beneficiary | Anyone |
|---|---|---|---|---|
| `setFeeBps` | ✓ | | | |
| `whitelistToken` | ✓ | | | |
| `collectFees` | ✓ | | | |
| `deployPool` | | | | ✓ |
| `depositETH/Token` | | ✓ | | |
| `adminWithdraw` | | ✓ | | |
| `setAllocation` | | ✓ | | |
| `removeAllocation` | | ✓ | | |
| `pausePool/unpausePool` | | ✓ | | |
| `closePool` | | ✓ | | |
| `claim` | | | ✓ (self only) | |
| `registerBeneficiary` | | | | Pool contract only |
| `recordFee` | | | | Pool contract only |

### Reentrancy

- `adminWithdraw` and `claim` are both `nonReentrant`.
- Both follow CEI strictly: all state mutations happen before `_sendFee` and `_transfer`.
- `_sendFee` calls into `factory.recordFee` — factory is trusted, not arbitrary. For ETH fees, this is the only external call before the user transfer.

### Fee accounting

- Fees are tracked in `accruedFees` on the factory, not held loose in the pool.
- ETH fees flow `pool → factory` via `recordFee{value: fee}`. Factory's `receive()` accepts them.
- ERC-20 fees are transferred directly to `factory` via `safeTransfer`, then `recordFee` is called (no value). The factory holds the tokens; `collectFees` pulls them to a designated address.

### Pool authenticity (anti-spoofing)

- `registerBeneficiary` and `recordFee` both guard with `isDeployedPool[pool]` / `isDeployedPool[msg.sender]`.
- This mapping is set only inside `deployPool()`, making it impossible for an attacker to spoof a pool by deploying a contract with a matching `factory()` return value.

### Token safety

- All ERC-20 interactions use OpenZeppelin `SafeERC20` (`safeTransfer`, `safeTransferFrom`).
- `depositToken` uses balance-delta accounting to handle fee-on-transfer tokens correctly (though such tokens will cause `poolBalance` to reflect actual received amounts, not requested amounts, which the UI must account for).

---

## 7. Known Limitations & Gas Considerations

| Issue | Impact | Notes |
|---|---|---|
| `_totalCommitted(token)` is O(n×m) | `adminWithdraw` gas scales with beneficiary count × tranches | Acceptable for small pools. Large pools (100+ beneficiaries) may hit gas limits. Future mitigation: track committed balance as a running counter. |
| `_freezeAllTranches()` is O(n×m) | `closePool` gas scales similarly | One-time cost; acceptable. |
| Unbounded beneficiary list | `getBeneficiaries()` could exceed call gas at extreme scale | View function only; does not affect state-changing operations until `_totalCommitted` is called. |
| Factory `receive()` accepts ETH from anyone | Non-harmful: ETH sits in `accruedFees[address(0)]` only when pools call `recordFee` | Random ETH sent directly to factory is accepted but not tracked in `accruedFees`. Could be reclaimed via `collectFees` only if recorded. |
| Tranche count per (beneficiary, token) grows unboundedly | `_claimable` is O(tranche count) | In practice, low. Each edit adds one tranche. |
| No pool ownership transfer | Pool admin cannot hand off the pool to another wallet | Ownable supports `transferOwnership` — this is available via the standard OZ API. |
| 30-day "month" and 90-day "quarter" | Not calendar-aligned | Intentional simplification. Documented. |

---

## 8. Multi-Agent Audit Plan

The audit is structured as five parallel specialist agents plus a final synthesis agent. Each agent has a defined scope, specific checks, and deliverables.

---

### Agent 1 — Access Control & Authorization Auditor

**Scope:** Every function that modifies state. Verify that the access control layer is complete, correct, and has no bypass paths.

**Checks:**
1. Enumerate all `onlyOwner`, `notPaused`, `notClosed` modifier placements. Verify no state-changing function is missing a required modifier.
2. Confirm `registerBeneficiary` and `recordFee` cannot be called by any address not in `isDeployedPool`. Try calling them as EOA, as a rogue contract with `factory()` returning the real factory address, as the factory owner, and as a legitimate pool address for a different factory.
3. Confirm `claim` can only be called by the beneficiary themselves (`msg.sender`). Verify no admin can trigger a claim on behalf of a beneficiary (which would allow admin to manipulate who receives the fee-net vs fee split).
4. Verify that `Ownable.transferOwnership` on `PayrollPool` correctly transfers admin rights and that the previous admin cannot call `onlyOwner` functions after transfer.
5. Verify that factory owner cannot directly touch pool funds.
6. Check that `collectFees` cannot drain the wrong token due to incorrect `token` argument (it reads from `accruedFees[token]` so it is safe, but verify).

**Deliverable:** Table of every function → required roles → is modifier present and correct → pass/fail.

---

### Agent 2 — Arithmetic & Tranche Math Auditor

**Scope:** `_claimable`, `_totalCommitted`, `_calcFee`, tranche sealing logic in `setAllocation`/`removeAllocation`/`closePool`.

**Checks:**
1. **Tranche boundary correctness:** When a tranche is sealed at `T`, and the next tranche starts at `T` (or `T + delta`), verify no period is double-counted or lost. Trace through the loop manually for at least 3 scenarios: immediate edit (new start == now), future-start edit (new start > now), removal then re-allocation.
2. **Floor division:** Verify that `(effectiveEnd - startTime) / periodSeconds` is strictly floor division and cannot be manipulated to over-count periods (e.g., via an off-by-one on timestamps).
3. **Claimed monotonicity:** After a claim, can `_claimable` ever return a non-zero value before a new period elapses? Trace through: `claim()` increments `_claimed` by the full `claimable` amount at the time of claim. Immediately after, `totalAccrued` equals `alreadyClaimed`, so result is 0. Confirm.
4. **Overflow analysis:** `amountPerPeriod * periods` — at `uint256 max` rates and very large period counts, does this overflow? With `amountPerPeriod` up to `~1e59` (realistic max for any ERC-20 with 18 decimals given max supply ~1e27) and periods up to `~50` years / 7 days = ~2600, max product is `~2.6e62`, well within `uint256`. Confirm.
5. **Fee rounding:** `(amount * bps) / 10_000` — rounding is always down (Solidity floor). This means the platform collects slightly less than exact percentage, never more. Verify this is intentional and that `net + fee == amount` always holds with no dust remaining in the pool.
6. **totalCommitted undercounting:** If `_claimable` returns 0 for a beneficiary who actually has a future allocation (not yet started), is `adminWithdraw` safe? Yes — future accrual not yet elapsed is not committed. Confirm this is the intended behaviour and document it (admin can withdraw funds that will be needed for a future-start allocation).
7. **`_freezeAllTranches` idempotency:** Can `closePool` be called in a state where some tranches are already sealed? Sealed tranches (`endTime != 0`) are skipped by the freeze loop. Confirm no tranche gets a double-seal.

**Deliverable:** Annotated trace of each scenario with expected vs actual values, and a statement on whether arithmetic is safe or requires a fix.

---

### Agent 3 — Reentrancy & CEI Auditor

**Scope:** All functions that perform external calls. Verify checks-effects-interactions discipline is consistent throughout.

**Checks:**
1. **`claim()`:** State mutations (`_claimed += claimable`, `poolBalance -= claimable`) happen before `_sendFee` and `_transfer`. The `nonReentrant` modifier is present. Verify that a malicious ERC-20 that calls back into `claim()` or `adminWithdraw()` during `safeTransfer` would be blocked by the reentrancy guard.
2. **`adminWithdraw()`:** Same CEI check. `poolBalance[token] -= amount` happens before fee send and transfer. `nonReentrant` is present.
3. **`_sendFee()` with ETH:** Calls `factory.recordFee{value: fee}(...)`. The factory's `recordFee` updates `accruedFees` — it does not call back into the pool. Verify this call cannot reenter `claim` or `adminWithdraw` (no mutual call chain).
4. **`_transfer()` for ETH:** Uses `.call{value: amount}("")` to the beneficiary. A malicious beneficiary contract could attempt reentrancy here. The guard is the `nonReentrant` modifier on `claim()`. Verify the guard is in place and covers this path.
5. **`depositToken()`:** `safeTransferFrom` is called, then balance is read. Can a malicious token call back into the pool during `transferFrom`? If it calls `depositToken` again, `nonReentrant` is NOT present on `depositToken`. Assess: is a reentrancy into `depositToken` during another `depositToken` harmful? (It would inflate `poolBalance` twice for one actual transfer.) Recommend adding `nonReentrant` to `depositToken`.
6. **`collectFees()` in factory:** Same CEI check. `accruedFees[token] = 0` before the transfer. Covered.

**Deliverable:** Call graph showing all external calls and their position relative to state mutations, with pass/fail on CEI and reentrancy guard coverage. Flag any unguarded external call.

---

### Agent 4 — Economic & Incentive Auditor

**Scope:** Fee mechanics, fund custody, and economic incentive alignment between factory owner, pool admins, and beneficiaries.

**Checks:**
1. **Fee capture completeness:** Is there any withdrawal or claim path where tokens leave the pool without paying a fee? Check: `adminWithdraw` (yes, fee applied), `claim` (yes, fee applied). Is there any emergency path that bypasses fees?
2. **Fee = 0 edge case:** When `feeBps == 0`, fee is 0, net equals gross. `_sendFee` returns early. Verify this path doesn't cause any state inconsistency (e.g., `poolBalance` still decremented by `amount`, `net = amount`).
3. **Admin cannot steal committed funds:** The `availble = poolBalance - _totalCommitted` calculation — can an admin set up a large allocation, wait for accrual, then call `adminWithdraw` and get more than the uncommitted portion? The check is computed at time of withdrawal, not set aside at allocation time. So if `poolBalance` was 10,000 and committed is 6,000, admin can only withdraw 4,000. Verify this holds even if the pool is underfunded for beneficiaries (i.e., `poolBalance < committed`: then `available = 0`, admin withdraws 0).
4. **Underfunded pool:** If admin deploys allocations totalling more than the pool holds, `claim` will revert with `PoolUnderfunded`. Beneficiaries cannot force a payout. The admin bears responsibility for keeping the pool funded. Confirm there is no mechanism that could cause partial state corruption on a failed claim (it reverts entirely due to CEI, so no issue).
5. **Fee-on-transfer token double accounting:** `depositToken` handles fee-on-transfer via balance delta. But in `_sendFee`, `safeTransfer(factory, fee)` is called — if the token deducts a transfer fee, the factory receives less than `fee`. The `accruedFees[token]` records the full `fee`, but the factory holds less. When `collectFees` tries to `safeTransfer` the recorded amount, it may fail or overdraw. **This is a potential issue.** Assess severity and recommend mitigation (e.g., disallow fee-on-transfer tokens via whitelist policy, or use balance-delta in `_sendFee`).
6. **Factory `receive()` accepts arbitrary ETH:** Any ETH sent directly to the factory accumulates but is not recorded in `accruedFees`. It is not collectible via `collectFees`. Assess if this is a risk (locked ETH) or acceptable.

**Deliverable:** Risk register with severity (Critical / High / Medium / Low / Info), description, and recommended mitigation for each finding.

---

### Agent 5 — Integration & Edge Case Auditor

**Scope:** Cross-contract interactions, lifecycle transitions, and rare but valid usage combinations.

**Checks:**
1. **Factory upgrade scenario:** The factory is not upgradeable. If a new factory is deployed, existing pools point to the old factory permanently (via `immutable factory`). The new factory's whitelist and fee settings will not apply to old pools. Document this as a known deployment constraint.
2. **Admin transfers pool ownership:** `Ownable.transferOwnership` is inherited but not overridden. After transfer, the new owner can call all `onlyOwner` functions. The old owner cannot. However, the `_adminPools` mapping on the factory still points to the original deployer. **The factory registry becomes stale after ownership transfer.** Assess: is this a critical issue for the UI? (Yes — the UI reads `getAdminPools` to show "my pools".) Recommend either emitting an event on ownership transfer or adding a factory function to update the admin mapping.
3. **Beneficiary is also the pool admin:** The spec explicitly allows this. Verify: admin sets allocation for themselves, deposits, then claims — the full flow. No modifier should block this.
4. **closePool with no beneficiaries:** `_freezeAllTranches` loops over empty `_beneficiaries` array — benign, no gas waste.
5. **setAllocation called on closed pool:** The `notClosed` modifier reverts with `PoolClosedError`. New tranches cannot be added after close.
6. **removeAllocation on a closed pool:** There is no `notClosed` modifier on `removeAllocation`. After close, all tranches are frozen. A subsequent `removeAllocation` call would try to seal the last tranche again but it already has `endTime != 0`, so it reverts with `AllocationAlreadyRemoved`. This is safe but confirm it doesn't waste a SSTORE.
7. **Token delisted from factory whitelist:** The whitelist is additive-only, so this cannot happen. But verify the factory interface has no `removeToken` or similar function that could be added later.
8. **Pool with 0 balance and active allocations:** Admin sets allocations but never deposits. Beneficiary calls `claim` — it reverts with `PoolUnderfunded`. Subsequent deposits allow the claim to succeed. Verify claim does not partially succeed or leave dirty state on revert.
9. **Two pools, same beneficiary:** `_beneficiaryPools` in factory correctly appends both pool addresses. `getAllocations` on each pool returns independent allocation views. Verify no cross-pool state contamination.
10. **Frequency boundary (exactly at period end):** If `block.timestamp == startTime + N * periodSeconds` exactly, `periods = N` (not N+1). Verify this is consistent with the UI's expected behaviour (claim shows claimable at the exact boundary moment).

**Deliverable:** Test scenarios for each case with pass/fail results, and a list of state transition diagrams covering all lifecycle paths.

---

### Agent 6 — Synthesis & Pre-Deployment Sign-Off

**Scope:** Collects all five agent reports. Makes final go/no-go recommendation.

**Checks:**
1. All Critical and High findings from Agents 1–5 must be resolved with code changes + re-audit confirmation before deployment.
2. Medium findings must have documented mitigations or accepted risks.
3. Verify the final deployed bytecode matches the audited source (use `forge verify-contract` or equivalent).
4. Confirm `forge test --fuzz-runs 10000` passes with zero failures.
5. Confirm `forge coverage` shows >95% line coverage across `PayrollFactory` and `PayrollPool`.
6. Confirm no `console.log` or debug artifacts remain in production contracts.
7. Review deployment script: correct constructor args, correct initial fee, correct initial whitelist.
8. Confirm the deployer wallet is a multisig (e.g., Gnosis Safe) for the factory owner role, not an EOA.
9. Confirm the deployment transaction was broadcast on the correct chain and the correct network (mainnet vs testnet).
10. Confirm `etherscan` (or equivalent) source verification is complete for both contracts.

**Deliverable:** Final signed-off audit report with all finding statuses and deployment parameters.

---

## 9. Deployment Checklist

### Pre-deployment

- [ ] All 6 audit agents completed; Critical and High findings resolved
- [ ] `forge build` succeeds with no warnings
- [ ] `forge test --fuzz-runs 10000` passes (0 failures)
- [ ] `forge coverage` >= 95% line coverage
- [ ] No hardcoded addresses in production contracts
- [ ] Deployment script reviewed: `DEPLOYER_ADDRESS`, `PRIVATE_KEY`, `INITIAL_FEE_BPS`, `WHITELIST_TOKENS`
- [ ] Factory owner address is a multisig, not an EOA
- [ ] Contracts verified on block explorer

### Deployment order

1. Deploy `PayrollFactory(multisigAddress)` — record address
2. Call `setFeeBps(initialFee)` if non-zero (via multisig)
3. Call `whitelistToken(USDT)`, `whitelistToken(USDC)`, etc. (via multisig)
4. Verify all state on-chain before announcing

### Post-deployment smoke test

- [ ] `factory.tokenWhitelisted(address(0))` returns `true`
- [ ] `factory.feeBps()` returns the expected value
- [ ] `factory.deployPool()` succeeds and registers in `isDeployedPool`
- [ ] Deposit, set allocation, wait, claim — full happy path on testnet first
- [ ] Fee accrues correctly in `accruedFees`; `collectFees` withdraws correctly

---

*Document version: 1.0 — reflects contracts at commit where PayrollFactory and PayrollPool use custom errors and OZ SafeERC20.*
