# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zodl (formerly Zashi) is an iOS Zcash wallet built with SwiftUI and The Composable Architecture (TCA). It uses the Zcash Swift SDK (`ZcashLightClientKit`) for blockchain operations.

## Build & Development

**Prerequisites:** Install SwiftGen (`brew install swiftgen`) and SwiftLint (v0.50.3 specifically - use the official .pkg installer). Both run automatically during Xcode builds.

**Build targets:**
- `secant-testnet` - primary development target (TAZ token, testnet)
- `secant-mainnet` - production target (ZEC, mainnet)
- `secant-distrib` - distribution variant
- Conditional compilation via `SECANT_MAINNET` / `SECANT_TESTNET` flags

**Build:** Open `secant.xcworkspace` in Xcode and build the desired target.

**Tests:** Run `secantTests` target in Xcode. Tests use TCA's test store with dependency injection (`.noOp`, `.mockEmptyDisk`, etc.). Snapshot tests are in `secantTests/SnapshotTests/`.

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
