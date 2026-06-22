# MOB-1351 — Swap fee display mismatch (UI shows 0.5%, backend charges 0.67%)

- **Linear:** [MOB-1351](https://linear.app/zodl/issue/MOB-1351) (sub-issue of MOB-1276; dossier iOS-Z9)
- **Priority:** High
- **Branch:** `michal/MOB-1276/MOB-1351-swap-fee-display-mismatch`
- **Base / PR target:** `michal/MOB-1276/MOB-1388-swap-security-hardening` (stacked on the open MOB-1388 PR #1834 per the agreed swap-ticket strategy; retarget to `main` after #1834 merges)
- **Date:** 2026-06-22

## 1. Root cause (confirmed at HEAD of the MOB-1388 branch)

The Zashi affiliate fee is computed **two different ways** in `SwapAndPayStore.swift`:

| Property | Coefficient | Result | Drives |
|---|---|---|---|
| `zashiFeeStr` (1412), `zashiFeeUsdStr` (1428) | `Decimal(zashiFeeBps) / 10_000` = **0.67%** ✓ | correct | the standalone "Zashi fee" line |
| `totalFees` (1514), `swapToZecTotalFees` (1746) | hardcoded `* 0.005` = **0.5%** ✗ | wrong | `totalFeesStr` / `totalUSDFees` / `totalFeesUsdStr` / swap-to-ZEC total — **the totals shown on the CrossPay/Swap confirmation** (`CrossPayConfirmationView.swift:144`, `SwapComponents.swift:408`) |

The backend actually charges `zashiFeeBps = 67` (sent at `Near1Click.swift:357`). So the **total** the user reviews understates the fee (0.5% vs 0.67%), and it's even internally inconsistent with the app's own standalone fee line. `SwapAndPayInterface.swift:25` (`zashiFeeBps = 67`) is the real source of truth; there is no localized "0.5%" string — the mismatch is purely these two `0.005` literals.

## 2. Fix — single source of truth

Add a derived coefficient next to the bps constant in `SwapAndPayClient.Constants`:

```swift
/// Affiliate fee in basis points
static let zashiFeeBps = 67
/// Affiliate fee as a decimal coefficient (e.g. 67 bps -> 0.0067). Single source of truth for fee math/display.
static let zashiFeeCoefficient = Decimal(zashiFeeBps) / Decimal(10_000)
```

Then route all four fee-coefficient sites through it:
- `zashiFeeStr` (1412), `zashiFeeUsdStr` (1428): `Decimal(zashiFeeBps)/Decimal(10_000)` → `SwapAndPayClient.Constants.zashiFeeCoefficient` (behaviour-preserving DRY).
- `totalFees` (1514): `quote.amountIn * 0.005` → `quote.amountIn * SwapAndPayClient.Constants.zashiFeeCoefficient` (**fix**: 0.5% → 0.67%).
- `swapToZecTotalFees` (1746): same (**fix**).

After this, the displayed total and standalone fee line both equal exactly what is charged (`zashiFeeBps`); changing the bps in one place updates everything.

## 3. Tests (`zodlTests/SwapTests/SwapFeeDisplayTests.swift`, Swift Testing)

- **`totalFees` uses 0.67%, not 0.5%:** build `SwapAndPay.State()` with `quote.amountIn = 100_000_000` (1 ZEC) and `proposal = .testOnlyFakeProposal(totalFee: 10_000)`; assert `state.totalFees == 10_000 + 670_000` (the 0.67% affiliate fee), and explicitly `!= 10_000 + 500_000` (the old 0.5% bug).
- **Source-of-truth lock:** `#expect(SwapAndPayClient.Constants.zashiFeeCoefficient == Decimal(67) / Decimal(10_000))` so a future `zashiFeeBps` change flows through and the `0.005` literal can't creep back.

## 4. Acceptance criteria mapping

- ✅ Displayed fee matches the fee actually charged (`zashiFeeBps`), driven from one source of truth (§2).
- ✅ Audited `SwapAndPayInterface.swift`, `CrossPayConfirmationView.swift`, and the confirmation/summary surfaces — the only hardcoded fee literals were the two `0.005`; no hardcoded "0.5%" strings exist (§1).

## 5. Changelog

Under `[Unreleased]` → "Fixed":
> The swap / CrossPay confirmation now shows the correct total service fee (0.67%) instead of an
> understated 0.5%, matching what is actually charged.

## 6. Manual test plan (for the PR)

1. **CrossPay / Swap total fee.** Start a swap (or CrossPay) and reach the confirmation screen. Note the **total fees** value. **Expected:** it includes the Zashi affiliate fee at **0.67%** of the input amount (≈ `amountIn × 0.0067`), consistent with the standalone "Zashi fee" line. Before the fix the total used 0.5% (a smaller number than the standalone fee line implied).
2. **Swap-to-ZEC total fee.** In the swap-to-ZEC summary, confirm the fee shown reflects 0.67%.
3. **Cross-check.** The standalone fee line and the total's affiliate-fee portion now agree (both 0.67%).
