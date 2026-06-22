# MOB-1353 — Bind swap quote to the selected account (reject on mid-flow switch)

- **Linear:** [MOB-1353](https://linear.app/zodl/issue/MOB-1353) (sub-issue of MOB-1276; iOS parity for Android #19 / MOB-1344)
- **Priority:** Medium
- **Branch:** `michal/MOB-1276/MOB-1353-bind-swap-quote-to-account`
- **Base / PR target:** `michal/MOB-1276/MOB-1388-swap-security-hardening` (PR #1834; retarget to `main` after it merges)
- **Date:** 2026-06-22

## 1. Verification — iOS IS exposed (and MOB-1388 does not cover this)

The swap flow reads the selected account at **three** points, none snapshotted:

1. **`.getQuote`** (`SwapAndPayStore.swift:675`): `refundTo = state.selectedWalletAccount?.privateUnifiedAddress` — the refund address baked into the NEAR quote request comes from the account selected **now**.
2. **`.swapQuoteLoaded`** (`:732`, `:760`): re-reads `state.selectedWalletAccount` and builds the proposal with `proposeTransfer(account.id, …)`.
3. **`.swapRequested`** (`SwapAndPayCoordFlowCoordinator.swift:297`, `:341`): re-reads `state.selectedWalletAccount?.zip32AccountIndex` and derives the **spending key** from it.

If the user switches accounts during the quote → review → biometric window:
- a switch during the quote API call → the quote's **refund address is account A's** while the proposal + spending key bind to **account B** (funds spent from B, any NEAR refund goes to A);
- a switch during review/biometric → the proposal (built for A) is signed with **account B's** spending key (TOCTOU mismatch).

**MOB-1388 (#1834)** added `matchesSigningIntent` (recipient / origin & destination asset ids) — it does **not** bind the wallet account. So this is a distinct, still-open defect. This is the iOS parity of Android #19 ("swap quote not bound to account uuid").

## 2. Fix — snapshot the account at quote request, reject on change

Bind the whole flow to the account selected when the quote is requested. The account `id` is the binding key — the refund address and the `zip32AccountIndex` both derive from it, so verifying the id covers them (a same-session id is also stable across seed, so an explicit `seedFingerprint` check adds nothing in practice).

- **State:** add `var quoteAccountId: AccountUUID?` to `SwapAndPay.State`.
- **`.getQuote`:** snapshot `state.quoteAccountId = state.selectedWalletAccount?.id` (the refund address sent in the same request is this account's).
- **`.swapQuoteLoaded`:** after the swap-to-ZEC early return and before building the proposal, fail closed if the selection changed:
  ```swift
  guard account.id == state.quoteAccountId else {
      return .send(.sendFailed("selected account changed during the swap".toZcashError()))
  }
  ```
- **`.swapRequested`** (coordinator): require the current selection to still match the quote account, and derive the spending key from **that** account:
  ```swift
  guard let account = state.selectedWalletAccount,
        account.id == state.swapAndPayState.quoteAccountId,
        let zip32AccountIndex = account.zip32AccountIndex else {
      return .send(.sendFailed("selected account changed during the swap".toZcashError(), false))
  }
  ```

`quoteAccountId` is re-set on every `.getQuote`, so each new quote re-binds; no stale binding can block a fresh quote.

**Scope note:** swap-to-ZEC (`isSwapToZecExperienceEnabled`) returns early in `.swapQuoteLoaded` and never builds a `proposeTransfer` spend (the user sends funds manually), so the binding guard applies to the swap-from-ZEC / CrossPay spend path — which is where the account-bound `proposeTransfer` + spending key live.

## 3. Tests (`zodlTests/SwapTests/SwapAccountBindingTests.swift`, Swift Testing; added to the Classic-groups project via XcodeWrite)

Drive the `SwapAndPay` reducer (plain `Store` + poll, like the existing swap CoordFlow tests; `@Suite(.serialized)` for `selectedWalletAccount`):

- **Reject on switch:** `state.quoteAccountId = A`, `selectedWalletAccount = B`, send `.swapQuoteLoaded(quote)` → no proposal built (`proposeTransfer` never called) and the quote-unavailable/sendFailed path is taken.
- **Happy path (regression):** `quoteAccountId = A`, `selectedWalletAccount = A`, matching intent → `proposeTransfer` called once → `.proposal` set.

## 4. Acceptance criteria mapping

- ✅ Verify whether iOS re-reads the selected account at proposal/submit rather than a snapshot — **yes, exposed**; documented (§1).
- ✅ Snapshot `(account id, …, refund address, destination address)` at quote request and reject on mid-flow change (§2). (Destination is already bound by #1388's `matchesSigningIntent`; refund address follows from the account id.)
- ✅ Covers the quote → review → biometric → submit window (guards at `.swapQuoteLoaded` and `.swapRequested`).

## 5. Changelog

Under `[Unreleased]` → "Security":
> A cross-chain swap is now refused if you switch wallet accounts after requesting the quote, so the spend, refund address, and signing key always belong to the same account you started the swap from.

## 6. Manual test plan (for the PR)

1. **Switch mid-swap (the fix).** With two accounts, start a swap on account A, get the quote, then switch to account B (account picker) and confirm. **Expected:** the swap is refused (quote-unavailable / failure), nothing is signed or broadcast.
2. **Normal swap (regression).** Start and complete a swap without switching accounts — unchanged behaviour.
3. **Swap-to-ZEC (regression).** The swap-to-ZEC deposit flow still shows the deposit address as before.
