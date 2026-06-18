# KeystoneSDK — local override (macOS-enabled)

Local copy of upstream `keystone-sdk-ios` **0.8.6** (commit `7dbf7476`), used by the
`slipstream-macos` branch so the native macOS app target (`zodlmac-internal`) can link
Keystone. Upstream ships **iOS-only** `URRegistryFFI` binaries; everything else
(including `Package.swift`'s `.macOS(.v13)` platform) is already macOS-ready.

## What differs from upstream
Only the `URRegistryFFI` binaryTarget: upstream pulls a remote zip (Keystone release
`sdk-0.2.3`, iOS-only); this package uses a local `path:` to a **spliced** xcframework:

| Slice | Source |
|---|---|
| `ios-arm64`, `ios-arm64_x86_64-simulator` | Keystone's **official** `sdk-0.2.3` release (sha256 `5cfeb769…`, verified) — byte-identical to what ships |
| `macos-arm64_x86_64` | Built from `keystone-sdk-rust` @ `sdk-0.2.3` with its pinned `nightly-2023-12-01` toolchain — ABI-matched to 0.8.6's Swift |

The Swift sources under `Sources/` are 0.8.6 verbatim.

## Regenerate `URRegistryFFI.xcframework`
`./regenerate-xcframework.sh` — clones `keystone-sdk-rust` @ `sdk-0.2.3`, builds the
darwin slices with the pinned toolchain, downloads + checksum-verifies the official iOS
zip, and splices. Output lands at `/tmp/URRegistryFFI.xcframework`; copy it here.

## Upstream the macOS slice (follow-up)
The macOS build is ~4 lines in `keystone-sdk-rust`'s `Makefile` (`generate_xcframework`);
a PR there + a macOS-inclusive release would remove the need for this override.
