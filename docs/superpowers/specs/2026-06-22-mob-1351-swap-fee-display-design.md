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

The backend actually charges `zashiFeeBps = 67` (sent at `Near1Click.swift:357`). So the **total** the user reviews understates the fee (0.5% vs 0.67%), and it's even internally inconsistent with the app's own standalone fee line. `SwapAndPayInterface.swift:25` (`zashiFeeBps = 67`) is the real source of truth; there is no localized "0.5%" string — the mismatch is in the hardcoded `0.005` literals.

A **third** `0.005` literal lives outside `SwapAndPayStore.swift`, in `TransactionDetailsStore.swift:707` (`totalSwapToZecFee`), which drives the **Total fees** row on the completed swap-to-ZEC transaction-detail screen (`TransactionDetailsView.swift:580`). It is the same affiliate fee, so it must be fixed too — otherwise the post-swap detail keeps showing 0.5% while the confirmation shows 0.67%, re-creating the mismatch on a different screen.

## 2. Fix — single source of truth

Add a derived coefficient next to the bps constant in `SwapAndPayClient.Constants`:

```swift
/// Affiliate fee in basis points
static let zashiFeeBps = 67
/// Affiliate fee as a decimal coefficient (e.g. 67 bps -> 0.0067). Single source of truth for fee math/display.
static let zashiFeeCoefficient = Decimal(zashiFeeBps) / Decimal(10_000)
```

Then route every fee-coefficient site through it — four in `SwapAndPayStore.swift` plus one in `TransactionDetailsStore.swift`:
- `zashiFeeStr` (1412), `zashiFeeUsdStr` (1428): `Decimal(zashiFeeBps)/Decimal(10_000)` → `SwapAndPayClient.Constants.zashiFeeCoefficient` (behaviour-preserving DRY).
- `totalFees` (1514): `quote.amountIn * 0.005` → `quote.amountIn * SwapAndPayClient.Constants.zashiFeeCoefficient` (**fix**: 0.5% → 0.67%).
- `swapToZecTotalFees` (1746): same (**fix**).
- `totalSwapToZecFee` (`TransactionDetailsStore.swift:707`): `amountIn * 0.005` → `amountIn * SwapAndPayClient.Constants.zashiFeeCoefficient` (**fix**: the post-swap transaction-detail "Total fees" row, in a different feature from the four above).

After this, the displayed total and standalone fee line both equal exactly what is charged (`zashiFeeBps`); changing the bps in one place updates everything.

## 3. Tests (`zodlTests/SwapTests/SwapFeeDisplayTests.swift`, Swift Testing)

- **`totalFees` uses 0.67%, not 0.5%:** build `SwapAndPay.State()` with `quote.amountIn = 100_000_000` (1 ZEC) and `proposal = .testOnlyFakeProposal(totalFee: 10_000)`; assert `state.totalFees == 10_000 + 670_000` (the 0.67% affiliate fee), and explicitly `!= 10_000 + 500_000` (the old 0.5% bug).
- **Source-of-truth lock:** `#expect(SwapAndPayClient.Constants.zashiFeeCoefficient == Decimal(67) / Decimal(10_000))` so a future `zashiFeeBps` change flows through and the `0.005` literal can't creep back.
- **Transaction-detail total uses 0.67%, not 0.5%:** build `TransactionDetails.State(transaction:)` with `swapDetails.amountInFormatted = 10_000` and assert `totalSwapToZecFee` equals the 0.67% value and not the old 0.5%, comparing against the store's own `conversionFormatter` so the assertion is locale-independent.

## 4. Acceptance criteria mapping

- ✅ Displayed fee matches the fee actually charged (`zashiFeeBps`), driven from one source of truth (§2).
- ✅ Audited `SwapAndPayInterface.swift`, `CrossPayConfirmationView.swift`, the confirmation/summary surfaces, and the transaction-detail screen — the hardcoded fee literals were the two `0.005` in `SwapAndPayStore.swift` and a third in `TransactionDetailsStore.swift:707`, all now routed through `zashiFeeCoefficient`; no hardcoded "0.5%" strings exist (§1). The remaining `0.005` in `Decimals.swift:17` is an unrelated rounding tolerance.

## 5. Changelog

Under `[Unreleased]` → "Fixed":
> The swap / CrossPay confirmation and the completed swap transaction details now show the correct
> total service fee (0.67%) instead of an understated 0.5%, matching what is actually charged.

## 6. Manual test plan (for the PR)

1. **CrossPay / Swap total fee.** Start a swap (or CrossPay) and reach the confirmation screen. Note the **total fees** value. **Expected:** it includes the Zashi affiliate fee at **0.67%** of the input amount (≈ `amountIn × 0.0067`), consistent with the standalone "Zashi fee" line. Before the fix the total used 0.5% (a smaller number than the standalone fee line implied).
2. **Swap-to-ZEC total fee.** In the swap-to-ZEC summary, confirm the fee shown reflects 0.67%.
3. **Post-swap transaction detail.** Open a completed swap-to-ZEC from Activity and view its detail. **Expected:** the **Total fees** row shows 0.67% of the input amount, matching the confirmation screen. Before the fix this screen still showed 0.5%.
4. **Cross-check.** The standalone fee line and the total's affiliate-fee portion now agree (both 0.67%).
