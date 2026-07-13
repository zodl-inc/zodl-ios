# Zodl macOS Support — Design (Milestone 2)

**Branch:** `slipstream-macos` (off `slipstream`) · **Date:** 2026-06-18 · **Issue:** #1755 · **Status:** approach **pivoted 2026-06-18** to *"Designed for iPad on Mac"* after the Keystone slice constraint (below).

## Goal

Run the Zodl wallet on macOS with **Slipstream by default** and the legacy `SDKSynchronizer` one flag-flip away, **including Keystone hardware-wallet support**. iPadOS shares the same build.

## The decision — and why it changed

We evaluated three "recompiled-for-Mac" strategies (native macOS, Mac Catalyst) plus running the iOS binary. One hard binary-dependency fact eliminated the recompiled options:

> **KeystoneSDK's `URRegistryFFI.xcframework` ships only `ios-arm64` + `ios-arm64_x86_64-simulator` — no `macos`, no `maccatalyst` slice.**

| Strategy | Needs | Result |
|---|---|---|
| Native macOS | a `macos` slice of every binary dep | ❌ build fails: "no library for this platform" (Keystone) |
| Mac Catalyst | a `maccatalyst` (`macabi`) slice | ❌ same failure — Catalyst is **not** a way out |
| **Designed for iPad on Mac** | only the **`ios-arm64`** slice | ✅ Keystone links; slipstream `libzcashlc` `ios-arm64` links too |

**Rule learned:** any *recompiled* Mac binary (native or Catalyst) requires **every** binary dependency to ship that platform's slice. Keystone doesn't. The only Mac path that includes Keystone today is running the **unmodified iOS binary**.

## Chosen approach — "Designed for iPad on Mac"

- **No separate target, no UIKit porting, no FFI work.** Enable **iPad** + **Mac (Designed for iPad)** destinations on the existing `zodl-internal` iOS target; the same `ios-arm64` binary runs on Apple Silicon Macs.
- Slipstream (default) + SDK fallback both work unchanged — the engine flag is platform-agnostic.
- **Constraints:** Apple Silicon Macs only; runs as the iPad app in a resizable window (system-provided Mac menu/chrome, not custom-native).
- **iPad inheritance is automatic:** Mac == iPad == one layout. This *is* the original "iPad inherits the macOS layout" goal, unified.

## What the real remaining work is

Porting is gone. The actual gap: the app is **fixed iPhone-portrait**, so in a large iPad/Mac window it looks cramped. The substantive milestone is **adaptive layout** (size classes / `NavigationSplitView`) that looks right on iPhone, iPad, and Mac from one codebase.

## Milestones (revised)

| Milestone | Scope | Done when |
|---|---|---|
| **M-A Enable** | iPad + Mac(Designed for iPad) destinations on `zodl-internal`; build + run on Mac | Live restore on Mac; `ENGINE=SlipstreamSynchronizer` + `engine_build` in log; Keystone pairing reachable |
| **M-B Adaptive layout** | size-class / split-view layout for large windows (iPhone/iPad/Mac from one layout) | Looks native-good across iPad + Mac window sizes |

## Setup (M-A)

1. `zodl-internal` target → **General → Supported Destinations** → add **iPad** and **Mac (Designed for iPad)** (sets `TARGETED_DEVICE_FAMILY = "1,2"`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = YES`).
2. Run destination → **My Mac (Designed for iPad)** → Build & Run.
3. Verify Keystone + slipstream sync on Mac. **No code changes expected.**

## Future option — true native Mac (only if ever prioritized)

Native macOS / Catalyst becomes possible only once Keystone provides a `macos`/`maccatalyst` slice. `URRegistryFFI` is open-source Rust (Keystone's `ur-registry-ffi`); building it for `aarch64-apple-darwin`, repackaging the xcframework, and overriding the SPM dependency would unlock native — at the cost of a Rust-FFI side-project + maintenance on every Keystone update, plus resurrecting the UIKit porting. Out of scope; documented as the known unlock.

## Branch / merge discipline

`main → slipstream → slipstream-macos`, merge-downstream-only. **Never rebase `slipstream`** (published + under review). Enabling destinations touches only `zodl-internal`'s build settings — a small, low-conflict change. Commits: `[#1755] slipstream: macOS — <imperative>`.
