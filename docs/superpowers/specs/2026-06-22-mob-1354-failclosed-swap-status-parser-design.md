# MOB-1354 — Fail-closed swap status parser; reconcile server-echoed metadata

- **Linear:** [MOB-1354](https://linear.app/zodl/issue/MOB-1354) (sub-issue of MOB-1276; dossier iOS-Z10)
- **Priority:** Low
- **Branch:** `michal/MOB-1276/MOB-1354-failclosed-swap-status-parser`
- **Base / PR target:** `michal/MOB-1276/MOB-1388-swap-security-hardening` (PR #1834; retarget to `main` after it merges)
- **Date:** 2026-06-22

## 1. Findings (confirmed at HEAD of the MOB-1388 branch)

**A. Unknown status silently → `.pending`.** `Near1Click.swift:410-430` maps the server `status` string to `SwapDetails.Status` with `default: .pending` in **both** the swap-to-ZEC and the other branch. An unrecognized/garbage server status is silently treated as pending. `SwapDetails.Status` has no `.unknown` case.

**B. Server-echoed metadata overwrites local state.** The status-poll update in `RootSwaps.swift:111-145` and the mirror in `TransactionDetailsStore.swift:489-507` **blindly overwrite** the locally-stored swap's `fromAsset` / `toAsset` (and `status`) with whatever the server echoes — `if umSwapId.fromAsset != mapped { umSwapId.fromAsset = mapped }`. The from/to assets are fixed when the swap is created (`markTransactionAsSwapFor`), so a malicious/compromised status response can rewrite the displayed assets of an existing swap. (Display deception, not fund loss — hence Low.)

## 2. Fix

### Part A — fail closed on unknown status (testable extraction)
- Add `case unknown` to `SwapDetails.Status` (`SwapDetails.swift`); extend `rawName` (→ new `SwapConstants.unknown = "UNKNOWN"`); `isPending` stays false for it (it's `==`-based).
- Extract the parsing into a pure, testable factory (mirroring `Near1Click.makeValidatedQuote`):
  ```swift
  extension SwapDetails.Status {
      /// Fail-closed mapping of a server status string; unrecognized values map to `.unknown`
      /// rather than silently to `.pending` (MOB-1354 / iOS-Z10).
      static func from(serverStatus: String, isSwapToZec: Bool) -> SwapDetails.Status { … default: .unknown }
  }
  ```
  `Near1Click` calls `SwapDetails.Status.from(serverStatus: statusStr, isSwapToZec: isSwapToZec)`.
- Add the required `.unknown` case to the exhaustive status switch at `TransactionDetailsStore.swift:187` (new localized `swapToZecSwapUnknown`).

### Part B — reconcile, don't blindly overwrite (both consumers)
In `RootSwaps.swift` and `TransactionDetailsStore.swift`:
- **from/to asset:** only **fill** when the local value is empty; never let a status-poll response overwrite an already-recorded asset (the asset is fixed at swap creation). A differing server echo is ignored (reconciled, not applied).
- **status:** skip the update when the parsed status is `.unknown` — keep the last known good status rather than regressing it from a garbage response.

## 3. Tests (`zodlTests/SwapTests/SwapStatusParsingTests.swift`, Swift Testing; added via XcodeWrite — Classic-groups branch)

- Unknown/garbage status string → `.unknown` (both `isSwapToZec` true and false).
- Each known string maps to its expected case (regression), in both directions (e.g. non-swap `PENDING_DEPOSIT` → `.pending`, swap-to-ZEC `PENDING_DEPOSIT` → `.pendingDeposit`).
- `.unknown.isPending == false`.

(Part B is reducer-level state-reconciliation; covered by the manual test plan rather than a new TCA harness for this Low-priority ticket.)

## 4. Acceptance criteria mapping

- ✅ Status parser does not silently coerce unknown → `.pending`; unknown maps to an explicit `.unknown` (Part A).
- ✅ Server-echoed `fromAsset`/`toAsset`/`status` are reconciled against local state rather than blindly overwriting (Part B). Consistent with the quote-field validation #1388 added.

## 5. Changelog

Under `[Unreleased]` → "Security":
> Swap status updates from the provider are now validated: an unrecognized status is no longer treated as "pending", and the provider can no longer rewrite the assets recorded for an existing swap.

## 6. Manual test plan (for the PR)

1. **Unknown status (Part A).** With an HTTPS proxy (Tor off), intercept `GET /v0/status` and set `status` to a made-up value (e.g. `"WAT"`). **Expected:** the swap is **not** shown as "pending"; it surfaces as unknown and the last known status is retained (no regression to pending).
2. **Asset tamper (Part B).** Intercept the same response and change `quoteRequest.originAsset` / `destinationAsset`. **Expected:** the swap's displayed from/to assets are **unchanged** (the locally-recorded assets win); the server echo can't rewrite them.
3. **Normal polling (regression).** Without tampering, a swap progresses pending → processing → success and the details screen updates as before.
