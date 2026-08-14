# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zodl (formerly Zashi) is an iOS Zcash wallet built with SwiftUI and The Composable Architecture (TCA). It uses the Zcash Swift SDK (`ZcashLightClientKit`) for blockchain operations.

## Build & Development

**Prerequisites:** Install SwiftGen (`brew install swiftgen`) and SwiftLint (v0.50.3 specifically - use the official .pkg installer). Both run automatically during Xcode builds.

**Build targets / schemes:**
- `zodl-internal` - internal/development build (mainnet/ZEC); its scheme also runs the `zodlTests` test target
- `zodl-testnet` - testnet build (TAZ token)
- `zodl-production` - production / App Store build (mainnet/ZEC), built via the `zodl-AppStore` scheme
- `zodlTests` - test target (run via the `zodl-internal` scheme)
- Conditional compilation via `SECANT_MAINNET` / `SECANT_TESTNET` (plus `SECANT_DISTRIB` on the App Store config). These flags keep the legacy `SECANT_` prefix even though the targets are now named `zodl-*`.

**Build:** Open `secant.xcodeproj` in Xcode and build the desired scheme (CI builds with `xcodebuild -project secant.xcodeproj`).

**Tests:** Run the `zodlTests` target in Xcode (scheme `zodl-internal`). All tests use **Swift Testing** (`@Suite` / `@Test` / `#expect` / `#require`) — **write every new test in Swift Testing, never XCTest.** Tests use TCA's `TestStore` with dependency injection (`.noOp`, `withDependencies`, etc.). Swift Testing runs suites in parallel by default, so mark any suite that mutates process-global state (named `UserDefaults` suites, the OSLog store, shared singletons / TCA `@Shared` state) with `@Suite(.serialized)`.

**Linting:** SwiftLint runs as a build phase. Config: `.swiftlint.yml` (app code) and `.swiftlint_tests.yml` (tests, more relaxed). Key enforced rules: no string concatenation (use interpolation), no `NSLog`, no `print`/`debugPrint` in app code, TODOs must reference issue numbers (`TODO: [#123]`).

## Architecture

**TCA (The Composable Architecture)** drives all state management, using modern macros (`@Reducer`, `@ObservableState`, `@Dependency`). Each feature has:
- `<Feature>Store.swift` - State, Action, Reducer, dependencies
- `<Feature>View.swift` - SwiftUI view consuming the store
- `<Feature>Coordinator.swift` (some features) - Navigation glue between screens

**Source layout** (`secant/Sources/`):
- `Features/` - Screen-level features (~40), each in its own directory
- `Features/CoordFlows/` - Multi-screen coordinator flows (Send, Restore, Scan, SwapAndPay, AddKeystoneHWWallet, RequestZec, SignWithKeystone, Transactions, Voting, WalletBackup). Each flow has `<Name>CoordFlowStore.swift`, `<Name>CoordFlowView.swift`, and `<Name>CoordFlowCoordinator.swift`. Most are flat files directly in `CoordFlows/`; Voting lives in its own `VotingCoordFlow/` subdirectory.
- `Dependencies/` - Dependency clients (~49) wrapping SDK, iOS, and custom services
- `UIComponents/` - Reusable UI building blocks (buttons, text fields, badges, etc.)
- `Models/` - Shared data types (TransactionState, StoredWallet, WalletAccount, SwapAsset, Swaps, WalletStatus, etc.)
- `Utils/` - Helpers and extensions
- `Generated/` - SwiftGen output (assets, fonts) - do not edit manually
- `Resources/` - Assets, fonts (Inter, RobotoMono, Zboto, Michroma), Lottie animations, localizations

**Root feature** (`Features/Root/`) is the app coordinator - handles wallet initialization, navigation, and deep linking across 12 files.

**Dependencies** use the `@DependencyClient` macro from `swift-dependencies` on a struct with `@Sendable` closures (Swift 6 concurrency). Layout per client:
- `<Name>Interface.swift` - `@DependencyClient struct <Name>Client { ... }` plus the `DependencyValues` extension
- `<Name>LiveKey.swift` - `liveValue` conformance for production
- `<Name>TestKey.swift` - **only when** the macro-generated default isn't enough; otherwise omit (the macro provides `testValue` automatically). Tests can also override individual closures inline via `withDependencies`.

Closures must be `@Sendable`. Use `@preconcurrency import ZcashLightClientKit` when an SDK type is not yet `Sendable`.

**Transaction guard (`Dependencies/TransactionGuard/`)** — the SDK's `switchTo(endpoint:)` tears down and rebuilds the synchronizer, so it must never overlap a transaction broadcast. A shared, non-reentrant FIFO-mutex actor (`@Dependency(\.transactionGuard)`) enforces this **inside the dependency LiveKeys** — feature code never wraps broadcasts; the one feature-level guard use is the manual switch (`switchWaiting`) in `ServerSetupStore`:
- Guarded closures (their `liveValue` acquires the guard internally): `sdkSynchronizer.createProposedTransactions`, `createTransactionFromPCZT`, `getTreeState`, and `votingAPI.submitVoteCommitment`, `submitDelegation`, `delegateShares`. (Voting's `resubmitShare` is deliberately unguarded — an idempotent, recoverable resubmission path.) A new broadcast-sensitive dependency closure must take the same wrap in its own LiveKey — never at call sites, and **never nested** (the guard is non-reentrant and will deadlock).
- Server switches: the manual Save path uses `switchWaiting { }` (waits for in-flight broadcasts, then wins). The automatic refresh is split into `autoServerSelection.findBestServer()` (read-only benchmark, safe anytime) and `applySwitch` (runs under `switchIfIdle { }`, which skips if a broadcast holds the guard). `withTimeout(serverSwitchTimeout)` bounds a switch.
- The automatic apply is additionally gated on live navigation state in Root: `.autoServerCandidateReady` defers while `Root.State.canApplyAutoServerSwitch` is false (sensitive flow on screen, Server Setup visible, or a background task), stashing the candidate in `pendingServerCandidate`; an `onChange` in `Root.body` re-feeds it when the gate clears (15-minute TTL). When adding a `Root.State.Path` case, the exhaustive switch in `isSensitiveFlowActive` forces classifying it as sensitive or not.

**Navigation** uses TCA's `StackState` with a `@Reducer enum Path` (coordinator pattern):
```swift
@Reducer
struct SomeCoordFlow {
    @Reducer
    enum Path {
        case scan(Scan)
        case sendConfirmation(SendConfirmation)
    }
    @ObservableState
    struct State { var path = StackState<Path.State>() }
    enum Action { case path(StackActionOf<Path>) }
}
```

## Code Conventions

- **Type definition order:** nested types -> static properties -> constants -> variables -> computed properties -> init -> instance methods -> extensions for protocol conformances
- **4-space indentation**, 150-char line length warning
- **File length:** 600 lines warning (relaxed in tests)
- **Force unwrapping and implicitly unwrapped optionals** are errors
- **String interpolation** required over concatenation
- **Features vs UI Components:** Features are standalone screens/flows; UI Components are reusable building blocks shared across features
- **Commit messages:** `[#<issue_number>] <descriptive title>`

## Design System

The app ships a complete design system — reusable SwiftUI components (`secant/Sources/UIComponents/`), colors (`Resources/Colors.xcassets`), image/icon assets (`Resources/Assets.xcassets`), and a localized string catalogue (`Resources/Localizable.xcstrings`). **All new UI work MUST reuse this design system as much as possible** rather than introducing bespoke equivalents.

- **Components:** Reuse the existing `UIComponents` (e.g. `ZashiButton`, plus the badges, text fields, toasts, sheets, toggles, toolbars, tooltips, etc. under `UIComponents/`) instead of hand-rolling new controls. Example: `ZashiButton(String(localizable: .generalRequest)) { action() }` — don't build a styled `Button` from scratch.
- **Colors:** Use the generated palette — `Asset.Colors.<name>.color` (including the `Asset.Colors.ZDesign.*` semantic ramp). Never hardcode `Color(red:green:blue:)` or hex literals.
- **Assets / icons:** Use bundled assets via `Asset.Assets.<name>.image` (namespaced, e.g. `Asset.Assets.Icons.*`, `Asset.Assets.Brandmarks.*`). Prefer these over SF Symbols (`Image(systemName:)`).
- **Strings:** Every user-facing string goes into `Localizable.xcstrings` and is referenced with `String(localizable: .someKey)` — the established idiom (~850 call sites; there are no hardcoded display literals in views). Never put display strings directly in code.
- **When the design system can't cover a need** — no suitable component, color, or asset exists — **stop and tell the user** instead of silently creating a one-off. Extend the design system deliberately, with the user's agreement, rather than diverging from it.

> `Asset.*` symbols are SwiftGen-generated into `Sources/Generated/` — do not edit those files; add the asset/color to the `.xcassets` catalogue and let the build regenerate them.

## Changelog

Every implemented task — any feature, fix, or other user-facing change — MUST be recorded in `CHANGELOG.md` as part of the same change. Treat the changelog entry as part of "done": do not consider an implementation complete until its entry exists, and add it automatically without waiting to be asked.

- Add the entry under the `## [Unreleased]` section (create that section if it isn't there), in the matching `### Added` / `### Changed` / `### Fixed` / `### Removed` subsection.
- Prefix every line with the issue identifier in brackets, e.g. `- [MOB-1321] Short, user-facing description of the change.`
- Write from the user's perspective — what changed for them and why it matters — not the implementation detail. The changelog focuses on user-impacting modifications.

## Key Files

- `SecantApp.swift` - `@main` entry point
- `AppDelegate.swift` - Root store creation, background task scheduling (WiFi sync at 3am)
- `secant/swiftgen.yml` - SwiftGen configuration
- `secant/Resources/PartnerKeys.plist` - Partner API keys (gitignored, do not commit)
- `secant/Resources/Localizable.xcstrings` - Localization strings

## macOS design language (LAW — read before any macOS UI work)

Zodl Mac has a defined design language — **define the system first, then only follow the rules.** The home/index is `docs/macos/DESIGN_LANGUAGE.md` (philosophy + every rule + links); read it first for any macOS UI work. All macOS layout / chrome / navigation follows the **4-rule foundation** in `docs/macos/LAYOUT_FOUNDATION.md`: native `NavigationSplitView` (never a manual HStack or view-level AppKit window hacks); a `ToolbarSpacer` on button-less screens (keeps the traffic lights inside the sidebar with no glass bubble); `Group { switch }.id(selection)` navigation (push/pop/switch, no crash); never `.buttonStyle` above the toolbar; an AppKit-pinned fixed sidebar width. `secant/Sources/Features/Root/MacSplitView.swift` is the reference implementation; the sandbox is `~/Downloads/testApp`.

For modal/overlay choices (sheets, alerts, dialogs, popovers, windows, inspectors, file panels), see `docs/macos/MODALS.md` — the native decision guide plus what the wallet uses today. Note: `.zashiSheet` and `.zashiSelectorSheet` are **custom overlay cards** on macOS, not native `.sheet` (deliberate — native sheets can't stack and iOS detents collapse them).
