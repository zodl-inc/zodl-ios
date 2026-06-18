# Zodl macOS Support — Design (Milestone 2)

**Branch:** `slipstream-macos` (off `slipstream`) · **Date:** 2026-06-18 · **Issue:** #1755 (slipstream lineage; a dedicated macOS issue may be wanted before PR) · **Status:** shape approved 2026-06-18, execution starts at M2.1.

## Goal

Ship a **native macOS build of the Zodl wallet running Slipstream by default**, with the legacy `SDKSynchronizer` one flag-flip away. iPadOS follows later, **inheriting the macOS adaptive layout**.

## Context (from reconnaissance)

- **Project:** raw committed `secant.xcodeproj` (NOT Tuist), Xcode 15 synchronized file groups → targets are created/edited in the Xcode UI; adding files doesn't churn the pbxproj.
- **Targets:** 3 iOS app flavors (`zodl-testnet`, `zodl-production`, `zodl-internal`, iOS 16) + `zodlTests`. All `SDKROOT = iphoneos`; no macOS/Catalyst today.
- **UI:** TCA + SwiftUI; `Root.State.Path` (13 routes) over `NavigationStack`; **no size-class / adaptive layout anywhere** (fixed iPhone-portrait) → the macOS layout is greenfield.
- **Platform coupling is centralized:** `Dependencies/` is isolated into live/test/mock keys; UIKit funneled through `UIComponents/UIKitBridge/`. No `UIScreen`/`UIDevice`, no push.
- **Engine flag:** `useSlipstreamSynchronizer` in `SDKSynchronizerLive.swift:60–78` — **zero `#if os()` guards**; both engines are pure-Swift `Synchronizer` impls → macOS fallback works for free.

## Decisions (locked)

- **D1 — Native macOS (SwiftUI/AppKit-backed) destination**, not Mac Catalyst. Runs on the **existing `macos` FFI slice → no FFI/XCFramework work.** Cost: UIKit touch-points need `#if os(iOS)` + AppKit siblings.
- **D2 — Separate macOS app target** (`Zodl-macOS`), not a destination on the iOS targets. **Purely additive → iOS targets stay pristine**, keeping `main → slipstream → slipstream-macos` merges clean (the team edits those targets on `main` constantly). Own native `NSApplication` shell.

## Architecture — platform abstraction

1. **Shared SwiftUI + TCA features compile on macOS as-is** (the bulk of the app).
2. **iOS-only files** (`AppDelegate`, `ScanUIView`, `QRCodeScanView`, `UIShareDialog`, `UIMailDialog`) → wrap contents in `#if os(iOS)` so they compile to nothing on macOS; AppKit siblings arrive in M2.3.
3. **iOS-only Dependency *Live* keys** → `#if os(iOS)` + a macOS sibling: real where trivial (`PasteboardLiveKey` → `NSPasteboard`); no-op/stub for M2.1 (`BackgroundTaskClient`, `FeedbackGenerator`); real impl deferred to M2.3 (share, QR, biometrics).
4. **macOS shell:** SwiftUI `@main App` hosting the shared `RootView`/`Root` store; `NSApplicationDelegateAdaptor` only if needed. `BGTaskScheduler` background-sync **gated out** (a Mac syncs while open; `NSBackgroundActivityScheduler` is the later answer).
5. **Engine selection untouched** → Slipstream default, SDK fallback, both on macOS.

## Staging

| Milestone | Scope | Definition of done |
|---|---|---|
| **M2.1 Bring-up** | Separate target builds + launches + **syncs on Mac**; all 6 blockers gated/stubbed; iPhone-style layout in a window | Live restore on macOS; log shows `ENGINE=SlipstreamSynchronizer` + `engine_build`; **iOS targets still build** |
| **M2.2 Native layout** | `NavigationSplitView`/sidebar, window sizing, menu commands — the adaptive layout **iPad later inherits** | Mac-native navigation; layout adapts across width classes |
| **M2.3 Feature ports** | Port the gated blockers to AppKit | QR, share, pasteboard, biometrics, mail working on macOS |

## Port map (the 6 blockers)

| Blocker | iOS | macOS approach | Milestone |
|---|---|---|---|
| Background sync | `BGTaskScheduler` | gate out (sync-while-open); `NSBackgroundActivityScheduler` later | M2.1 gate |
| Share sheet (~51 sites, 1 bridge) | `UIActivityViewController` | `NSSharingServicePicker` via `UIShareDialog` sibling | M2.3 |
| QR scan | `AVCaptureSession` in `UIView` | same AVFoundation in `NSViewRepresentable`/`NSView` | M2.3 |
| App lifecycle | `@UIApplicationDelegateAdaptor` | macOS `App` (+ `NSApplicationDelegateAdaptor` if needed) | M2.1 |
| Biometrics | `LAContext` (Face/Touch ID) | `LAContext` (Touch ID/password) — mostly strings | M2.3 |
| Pasteboard | `UIPasteboard` | `NSPasteboard` | M2.1 (trivial) |
| Haptics | `UIFeedbackGenerator` | no-op | M2.1 (stub) |

## Risks / open items

- **Membership churn:** synchronized groups add every file to membership; iOS-only files are `#if`-gated (chosen) rather than per-file membership exceptions (fiddly).
- **Local FFI:** native macOS needs no XCFramework change, but the local slipstream FFI's `macos` slice must be present in `LocalPackages` (it is, from the 3-slice build). No `macabi` needed (we did NOT choose Catalyst).
- **Entitlements:** App Sandbox + **Outgoing Network (Client)** required for the engine's gRPC/Tor networking; camera entitlement added in M2.3 for QR.
- **Dedicated issue:** slipstream rode #1755; a macOS PR may want its own. (User decision.)

## Verification gates

- **iOS green at every step** — the `#if` gating must not break the shipping iOS build; build an iOS scheme after each gating pass.
- **macOS:** `xcodebuild -scheme Zodl-macOS -destination 'platform=macOS,arch=arm64' build`, then launch + observe a sync.
- Slipstream byte-identity is an engine property, unaffected by the host.

## Branch / merge discipline

`main → slipstream → slipstream-macos`, **merge-downstream-only**. **Never rebase `slipstream`** (published + under core-team review) — keep current via `git merge` (main→slipstream, then slipstream→slipstream-macos). Commits: `[#1755] slipstream: macOS — <imperative>`.
