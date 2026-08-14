# Zodl macOS — where the code lives and how to build it

_Last updated 2026-08-14._

## Where the code lives

**Repo: `zodl-inc/zodl-ios`, branch: `macos-revival`.** That branch is the single source of truth for the macOS app. The older locations — `LukasKorba/zodl-ios#slipstream-macos` and `zodl-inc/zodl-ios#ironwood-testnet-demo` — are retired; everything they contained is in `macos-revival`, brought up to date with production `main` (3.9.3, slipstream sync engine, Ironwood/NU6.3).

## How the branch is tracked

- `macos-revival` is a **long-lived platform branch**, deliberately kept out of the regular iOS `main`/release flow. iOS releases never include it; it never merges into `main` wholesale.
- It stays close to iOS by **merging `main` into it** (merge, never rebase — the branch is shared, history stays stable) after each iOS release lands on `main`, or on demand before a mac distribution.
- Merge policy when updating: `main`'s semantics win for shared code; the mac platform layer (`#if os(macOS)` gates, `zodlmac-*` targets, Mac* components) is re-applied on top; iOS behavior in shared files stays byte-identical to `main`.
- Individual mac-hardening fixes that benefit iOS flow back to `main` via normal PRs; the branch itself does not.
- macOS is **versioned independently** of iOS: `zodlmac-*` targets carry their own `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` (currently 3.7.1 (7)); bump per mac distribution, not per iOS release.

## Building on a fresh machine (ops recipe)

Prerequisites: Xcode (the branch currently builds against the macOS 26.5 SDK), Rust toolchain (`rustup` with the standard Apple targets), ~20 GB free disk.

1. **Clone the app and the SDK as siblings** — the app references the SDK by local path (`../zcash-swift-wallet-sdk`), same convention as iOS `main`:

   ```
   parent-dir/
   ├── zodl-ios                 ← zodl-inc/zodl-ios @ macos-revival
   └── zcash-swift-wallet-sdk   ← zcash/zcash-swift-wallet-sdk @ main
   ```

2. **Build the SDK's native library locally** (one-time per SDK update; required because the SDK's published binary can lag its Swift code):

   ```
   cd zcash-swift-wallet-sdk && ./Scripts/init-local-ffi.sh
   ```

   The default builds all architectures including the **universal macOS slice — required before archiving** (arm-only subsets exist for day-to-day dev but must not be used for a distributed build).

3. **Open `zodl-ios/secant.xcodeproj` and pick a mac scheme**:
   - `zodlmac-internal` — mainnet build
   - `zodlmac-testnet` — testnet build (isolated keychain)

4. **Archive**: Product → Archive from the chosen scheme (destination "My Mac"). Distribution channels per the July release work: **Mac App Store/TestFlight** (App Store Connect signing) or **Developer ID DMG** (notarized). First build on a machine may need "Automatically manage signing" / `-allowProvisioningUpdates` to fetch profiles.

Notes:
- KeystoneSDK is **vendored in-repo** (`LocalPackages/keystone-sdk-ios`, mac-compatible URRegistryFFI) — nothing to set up; all targets use it.
- The fastlane mac lanes (`mac-internal`/`mac-dmg` variants, MOB-1482/1484) exist on the branch but are **temporarily not wired into the `release` lane** after the main merge — until that repair pass lands, distribution archives are produced manually via Xcode as above. `docs/release-automation.md` describes the lanes for when they return.
- CI note: like every branch using the local-path SDK, org CI cannot resolve the sibling dependency — local/manual builds are the supported path.

## Maintainers

Lukas Korba (+ Claude-orchestrated maintenance). Update protocol and the full campaign record (merge policy details, follow-ups register) live with the maintainers; this file is the stable public surface.
