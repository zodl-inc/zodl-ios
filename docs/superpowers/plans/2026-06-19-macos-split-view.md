# macOS Split-View Layout — Implementation Plan

**Goal:** On macOS, render the `.home` destination as a native two-column split (left control
rail + right content panel), like Mail. iOS stays byte-for-byte unchanged.

**Architecture (Approach A — reuse `store.path`):** `Root`'s `path: Path?` is already a
single-select "which section is open" — iOS animates it as a full-screen slide-over; macOS just
renders it as a right panel. The macOS sidebar drives `path` via the *existing* `Home` actions,
and the right panel renders the *existing* path-destination views. **No new reducer, no new
selection state.** Reset-on-switch and in-panel back arrows come free: each `Home` action does
`state.X = .initial` + `state.path = .Y` (RootCoordinator), and each CoordFlow owns its own
NavigationStack.

**Gating:** a single `#if os(macOS)` swap of the `.home` case body in `RootView.swift`. All
macOS-only code lives in new files; the iOS `.home` ZStack is untouched.

## Reuse map — left rail (new vertical layout, reused pieces)
| Left rail element | Reused from |
|---|---|
| Account switcher ("Zodl ▾") | `HomeView.walletAccountSwitcher()` / `homeState` |
| Balance + spendable | `WalletBalancesView(store: homeState.walletBalances)` |
| Currency card ("Start") | `homeState` + `.home(.currencyConversionSetupTapped)` |
| Sync banner ("Restoring 47%") | `SmartBannerView(store: homeState.smartBanner)` |
| Hide-balance eye | `HomeView.hideBalancesButton()` |

## Sidebar → action → panel (the buttons HomeView already sends)
| Sidebar item | `Home` action sent | resulting `path` → right panel |
|---|---|---|
| Activity (default) | `.seeAllTransactionsTapped` | `.transactionsCoordFlow` → TransactionsCoordFlowView (full TxManager) |
| Receive | `.receiveScreenRequested` | `.receive` → ReceiveView |
| Send | `.sendTapped` | `.sendCoordFlow` → SendCoordFlowView |
| Pay | `.payWithNearTapped` | `.swapAndPayCoordFlow` (isSwapExperience=false, EXACT_OUTPUT) |
| Swap | `.swapWithNearTapped` | `.swapAndPayCoordFlow` (isSwapExperience=true, EXACT_INPUT) |
| More | `.settingsTapped` | `.settings` → SettingsView |

## Files
- **Create** `secant/Sources/Features/Root/MacSplitView.swift` (macOS-only): the split shell, the
  left rail, and `rightPanel(store:)` that switches on `store.path` (mirrors the `.home` case's
  `if path == .X { XView }` chain).
- **Modify** `secant/Sources/Features/Root/RootView.swift`: `#if os(macOS)` the `.home` case →
  `MacSplitView`, `#else` the existing ZStack.

## Phases — each ends green (`xcodebuild` SUCCEEDED) + your visual check + a commit
- **Phase 1 — Shell + Activity.** MacSplitView with a functional sidebar nav list (sends the
  actions above) + right panel rendering the active `path`, defaulting to Activity. Rail
  balance/account are placeholders. Gate the `.home` case. → split renders; Activity on the right;
  tapping items swaps the panel.
- **Phase 2 — Panel completeness + back/reset.** Every section renders in-panel; back arrows work;
  switching resets; selection highlight; sensible `path == nil` default.
- **Phase 3 — Real left rail.** Swap placeholders for `WalletBalancesView`, account switcher,
  currency card, `SmartBannerView` scoped from `homeState`; match the mockup.
- **Phase 4 — Polish.** Empty/edge states, "Restoring 47%" card, two-column width tuning,
  selection persistence.

## Verification
Per phase: `xcodebuild -project secant.xcodeproj -scheme zodlmac-internal -destination
'platform=macOS' build` green; iOS no-regression build at the end. UI correctness = visual check
at each checkpoint (Lukas).
