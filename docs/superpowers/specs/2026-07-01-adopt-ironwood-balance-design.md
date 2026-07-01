# Design Spec — Adopt Ironwood (NU6.3) balance in the ZODL app

**Ticket:** MOB-1455
**Date:** 2026-07-01
**SDK branch:** `michal/MOB-1455-3-ironwood-sdk-support` (local SwiftPM package at `../zcash-swift-wallet-sdk`)

## 1. Background

The Zcash Swift SDK gained Ironwood (NU6.3) receive/sync readiness. The only app-facing
consequence is a new, additive field on a public struct:

```swift
public struct AccountBalance {
    public let saplingBalance: PoolBalance
    public let orchardBalance: PoolBalance
    public let ironwoodBalance: PoolBalance   // NEW
    public let unshielded: Zatoshi
    // …
}
```

- **Ironwood is Orchard note-version V3** — same circuit, same keys, received at the account's
  **existing Orchard receiver**. There is **no new address/receiver** to generate or display.
- `ironwoodBalance` is `.zero` for **every** wallet until NU6.3 activates on-network *and* a
  lightwalletd serves Ironwood compact blocks. Everything here is therefore **additive and dormant**:
  no user-visible change until Ironwood funds actually exist.
- The SDK is referenced as a **local** SwiftPM package (`XCLocalSwiftPackageReference "../zcash-swift-wallet-sdk"`),
  already on the branch that carries the field — **no version/pin bump is required**.
- The Orchard→Ironwood **migration API** was already adopted in commit `ea0df7b4`. This spec covers
  the **balance field only**.

## 2. Goals

1. **Fold Ironwood into every shielded/spendable total the app computes**, so balances are correct
   post-NU6.3. Additive — no behavior change while Ironwood is zero.
2. **Surface an explicit "Ironwood" line** in the Balances breakdown, shown **only when the account
   holds Ironwood (> 0)** — invisible today, auto-appears once V3 notes arrive.
3. **Centralize shielded-pool summation** in one helper so the next pool addition is a one-line change,
   removing the `sapling + orchard` pattern currently duplicated across 5 sites.
4. **Add tests** proving Ironwood is included, and **resolve the two pre-existing "deferred" aggregation
   notes** in `BalancesTests` / `WalletBalancesTests`.

## 3. Non-goals

- **Spending** Ironwood notes (building transactions from received V3 notes) — separate, later work.
- **New address/receiver** — Ironwood uses the Orchard receiver; nothing to add.
- **Migration source balances** stay **Orchard-only** — `MigrationSDK*`, `MigrationEntry*` read
  `orchardBalance` as the migration *source* and are intentionally untouched.
- **SDK changes** — the local checkout already has the field; no SDK edits.
- **Full per-pool breakdown** (separate Sapling / Orchard rows) — only an Ironwood breakout line is added.

## 4. Design

### 4.1 Shared helper — `AccountBalance+Shielded.swift` (new, `secant/Sources/Utils/`)

A single extension on the SDK's public `AccountBalance` centralizes "which pools are shielded":

```swift
import ZcashLightClientKit

extension AccountBalance {
    /// Spendable balance across all shielded pools (Sapling + Orchard + Ironwood).
    var shieldedSpendableValue: Zatoshi {
        saplingBalance.spendableValue + orchardBalance.spendableValue + ironwoodBalance.spendableValue
    }

    /// Total shielded balance including pending, across all shielded pools.
    var shieldedTotalIncludingPending: Zatoshi {
        saplingBalance.total() + orchardBalance.total() + ironwoodBalance.total()
    }

    /// Change awaiting confirmation, across all shielded pools.
    var shieldedChangePending: Zatoshi {
        saplingBalance.changePendingConfirmation
            + orchardBalance.changePendingConfirmation
            + ironwoodBalance.changePendingConfirmation
    }

    /// Value pending spendability, across all shielded pools.
    var shieldedValuePendingSpendability: Zatoshi {
        saplingBalance.valuePendingSpendability
            + orchardBalance.valuePendingSpendability
            + ironwoodBalance.valuePendingSpendability
    }
}
```

`Zatoshi + Zatoshi` and `PoolBalance.total()` are already used by the existing code, so this is a pure
refactor of expressions the app already computes — with Ironwood added.

### 4.2 Fold-in at the 5 aggregation sites (4 files)

Each site is rewritten to use the helper (which now includes Ironwood). Optional-chained sites keep
their `?? .zero`.

| # | Site | Before | After |
|---|------|--------|-------|
| 1 | `SmartBannerStore.swift:366` | `accountBalance.saplingBalance.spendableValue + accountBalance.orchardBalance.spendableValue` | `accountBalance.shieldedSpendableValue` |
| 2 | `SmartBannerStore.swift:539–543` ("any funds?" gate) | `orchard + sapling + unshielded == 0` | `accountBalance.shieldedTotalIncludingPending.amount + accountBalance.unshielded.amount == 0` |
| 3 | `WalletBalancesStore.swift:190–191` | `sapling.spendableValue + orchard.spendableValue` / `sapling.total() + orchard.total()` | `accountBalance?.shieldedSpendableValue ?? .zero` / `accountBalance?.shieldedTotalIncludingPending ?? .zero` |
| 4 | `RootInitialization.swift:118–119` (Flexa) | `sapling.spendableValue + orchard.spendableValue` / `sapling.total() + orchard.total()` | `accountBalance.shieldedSpendableValue` / `accountBalance.shieldedTotalIncludingPending` |
| 5 | `BalancesStore.swift:174–181` | `changePending` / `valuePendingSpendability` / `spendableValue` / `total()` each summed over sapling+orchard | `shieldedChangePending` / `shieldedValuePendingSpendability` / `shieldedSpendableValue` / `shieldedTotalIncludingPending` |

Site #2 (SmartBanner priority-8 currency-conversion gate) now correctly treats a wallet holding **only**
Ironwood as non-empty.

### 4.3 Explicit "Ironwood" line — Balances breakdown

The breakdown currently shows one combined **Spendable Balance** row (shield icon + `shieldedBalance`)
and a conditional **Pending** row; it does **not** split pools. We add a single Ironwood breakout row.

**State** (`Balances.State`, `BalancesStore.swift`):
```swift
var ironwoodBalance: Zatoshi = .zero
var hasIronwoodBalance: Bool { ironwoodBalance.amount > 0 }
```

**Reducer** (`updateBalance(_:)`): alongside the existing assignments,
```swift
state.ironwoodBalance = accountBalance?.ironwoodBalance.total() ?? .zero
```
(Per-pool value — reads `ironwoodBalance` directly, not the cross-pool helper.)

**View** (`BalancesView.balancesBlock()`): after the Spendable Balance row, a conditional row shown
only when `store.hasIronwoodBalance`, mirroring the Spendable row's layout (shield icon — Ironwood is
shielded — + "Ironwood" label + `ZatoshiText(store.ironwoodBalance, .expanded, tokenName)`).

**Localization** (`Localizable.xcstrings`): new key `balances.ironwoodBalance` = **"Ironwood"**
(follows the `balances.*` convention; generates `.balancesIronwoodBalance`).

**Semantics chosen (open to review):**
- **Value** = Ironwood pool **total** (`.total()`, i.e. spendable + both pendings) — a "holdings" figure.
- **Visibility** = gated on **total > 0**. Because Ironwood is zero everywhere until NU6.3, the row is
  **invisible today** and appears automatically once a wallet holds V3 notes. No confusing "Ironwood 0"
  row ships now.
- The handoff's "show an Ironwood line *next to Orchard*" is adapted to a **standalone breakout** because
  this app has no Orchard line; a full per-pool breakdown is out of scope (§3).

### 4.4 Tests (TDD)

Fixtures construct `AccountBalance` / `PoolBalance` via the SDK's `internal` memberwise inits, reachable
through the `@testable @preconcurrency import ZcashLightClientKit` already present in these suites.

1. **`AccountBalanceShieldedTests.swift` (new)** — unit-test the four helpers with **distinct nonzero**
   Sapling / Orchard / Ironwood pools; assert each helper equals the three-pool sum (proves Ironwood is
   included in spendable, total, change-pending, and pending-spendability).
2. **`BalancesTests.swift`** — add the non-nil aggregation path (currently deferred): drive a `TestStore`
   with `.updateBalance(AccountBalance(… nonzero ironwood …))`; assert `shieldedBalance`,
   `shieldedWithPendingBalance`, `changePending`, `pendingTransactions` include Ironwood, plus
   `ironwoodBalance == ironwood.total()` and `hasIronwoodBalance == true`. Remove the "deferred" note.
3. **`WalletBalancesTests.swift`** — add the non-nil aggregation path: drive a `TestStore` with
   `.balanceUpdated(AccountBalance(…))`; assert `shieldedBalance` / `shieldedWithPendingBalance` include
   Ironwood. Remove the "deferred" note.

All new/changed tests use **Swift Testing** (`@Suite`/`@Test`/`#expect`), matching the existing suites.

## 5. Risks / caveats

- **`@testable` init access** — high confidence the internal memberwise inits are exposed (the suites
  already `@testable`-import the SDK). Fallback if not: keep the aggregation path deferred and record it
  in the final report rather than modifying the SDK for a fixture.
- **Ironwood line value semantics** (total vs. spendable) and **placement/label** are UX calls; total +
  gated-on-`> 0` is the proposed default and is trivially adjustable.
- **Dormant end-to-end** — nothing surfaces Ironwood until upstream (lightwalletd + NU6.3 activation)
  catches up; this cannot be exercised on a live wallet yet, only via fixtures.

## 6. Verification

- **Build (CLI first):** `xcodebuild -skipMacroValidation` build of `secant-testnet`. Fall back to the
  Xcode MCP only on CLI failure.
- **Tests (CLI first):** `zodlTests` via the `zodl-internal` scheme (Swift Testing). Fall back to the
  Xcode MCP only on CLI failure.
- **Manual (documented, not executable now):** because Ironwood is zero pre-NU6.3, the explicit row and
  fold-in deltas cannot be seen on a real wallet; the fixture tests stand in for that.

## 7. Files touched

**New**
- `secant/Sources/Utils/AccountBalance+Shielded.swift`
- `zodlTests/BalancesTests/AccountBalanceShieldedTests.swift`

**Modified**
- `secant/Sources/Features/SmartBanner/SmartBannerStore.swift` (2 sites)
- `secant/Sources/Features/WalletBalances/WalletBalancesStore.swift`
- `secant/Sources/Features/Root/RootInitialization.swift`
- `secant/Sources/Features/BalanceBreakdown/BalancesStore.swift` (fold-in + new state)
- `secant/Sources/Features/BalanceBreakdown/BalancesView.swift` (new row)
- `secant/Resources/Localizable.xcstrings` (new "Ironwood" string)
- `zodlTests/BalancesTests/BalancesTests.swift` (resolve deferred note)
- `zodlTests/WalletBalancesTests/WalletBalancesTests.swift` (resolve deferred note)
