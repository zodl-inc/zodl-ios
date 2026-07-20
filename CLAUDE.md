# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZODL (formerly Zashi) is an iOS Zcash wallet built with SwiftUI and The Composable Architecture (TCA). It uses the Zcash Swift SDK (`ZcashLightClientKit`) for blockchain operations.

## App name

The app's name is always written **ZODL** — all uppercase. Whenever generated text refers to the app by name — UI strings (`Localizable.xcstrings`), code, comments, documentation, commit messages, PR titles/descriptions, etc. — it MUST be `ZODL`, never `Zodl` (nor `zodl`/`ZODl`). This rule is about the app name as a word; it does NOT change fixed technical identifiers such as the `zodl_internal` module, the `zodl-ios` repository, scheme names, or bundle IDs. The former name "Zashi" is unaffected.

## Build & Development

**Prerequisites:** Install SwiftGen (`brew install swiftgen`) and SwiftLint (v0.50.3 specifically - use the official .pkg installer). Both run automatically during Xcode builds.

**Build targets:**
- `secant-testnet` - primary development target (TAZ token, testnet)
- `secant-mainnet` - production target (ZEC, mainnet)
- `secant-distrib` - distribution variant
- Conditional compilation via `SECANT_MAINNET` / `SECANT_TESTNET` flags

**Build:** Open `secant.xcworkspace` in Xcode and build the desired target.

**Tests:** Run the `zodlTests` target in Xcode (scheme `zodl-internal`). All tests use **Swift Testing** (`@Suite` / `@Test` / `#expect` / `#require`) — **write every new test in Swift Testing, never XCTest.** Tests use TCA's `TestStore` with dependency injection (`.noOp`, `withDependencies`, etc.). Swift Testing runs suites in parallel by default, so mark any suite that mutates process-global state (named `UserDefaults` suites, the OSLog store, shared singletons / TCA `@Shared` state) with `@Suite(.serialized)`.

**Linting:** SwiftLint runs as a build phase. Config: `.swiftlint.yml` (app code) and `.swiftlint_tests.yml` (tests, more relaxed). Key enforced rules: no string concatenation (use interpolation), no `NSLog`, no `print`/`debugPrint` in app code, TODOs must reference issue numbers (`TODO: [#123]`).

## Architecture

**TCA (The Composable Architecture)** drives all state management, using modern macros (`@Reducer`, `@ObservableState`, `@Dependency`). Each feature has:
- `<Feature>Store.swift` - State, Action, Reducer, dependencies
- `<Feature>View.swift` - SwiftUI view consuming the store
- `<Feature>Coordinator.swift` (some features) - Navigation glue between screens

**Source layout** (`secant/Sources/`):
- `Features/` - Screen-level features (~40), each in its own directory
- `Features/CoordFlows/` - Multi-screen coordinator flows (Send, Restore, Scan, SwapAndPay, AddKeystoneHWWallet, RequestZec, SignWithKeystone, Transactions, WalletBackup). Each flow has `<Name>CoordFlowStore.swift`, `<Name>CoordFlowView.swift`, and `<Name>CoordFlowCoordinator.swift`.
- `Dependencies/` - Dependency clients (~41) wrapping SDK, iOS, and custom services
- `UIComponents/` - Reusable UI building blocks (buttons, text fields, badges, etc.)
- `Models/` - Shared data types (TransactionState, StoredWallet, WalletAccount, SwapAsset, Swaps, WalletStatus, etc.)
- `Utils/` - Helpers and extensions
- `Generated/` - SwiftGen output (assets, fonts) - do not edit manually
- `Resources/` - Assets, fonts (Inter, RobotoMono, Zboto, Michroma), Lottie animations, localizations

**Root feature** (`Features/Root/`) is the app coordinator - handles wallet initialization, navigation, and deep linking across 13 files.

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

## Key Files

- `SecantApp.swift` - `@main` entry point
- `AppDelegate.swift` - Root store creation, background task scheduling (WiFi sync at 3am)
- `secant/swiftgen.yml` - SwiftGen configuration
- `secant/Resources/PartnerKeys.plist` - Partner API keys (gitignored, do not commit)
- `secant/Resources/Localizable.xcstrings` - Localization strings
