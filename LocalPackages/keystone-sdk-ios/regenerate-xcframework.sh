#!/usr/bin/env bash
# Version-matched macOS URRegistryFFI build, take 2 — using sdk-0.2.3's pinned toolchain.
set -euo pipefail            # fail fast — a missing sdk-0.2.3 tag must abort, not silently build wrong FFI
source "$HOME/.cargo/env" 2>/dev/null || true
TC=nightly-2023-12-01            # sdk-0.2.3's pinned toolchain (old ahash needs stdsimd)
RUST=/tmp/keystone-sdk-rust

echo "===== ensure repo @ sdk-0.2.3 ====="
cd "$RUST" || exit 1
git -c advice.detachedHead=false checkout sdk-0.2.3 2>&1 | tail -1
git log -1 --format="rust at: %H %d"
echo "toolchain file: $(cat rust-toolchain* 2>/dev/null)"

echo; echo "===== install $TC + darwin targets ====="
rustup toolchain install "$TC" --profile minimal 2>&1 | tail -3
rustup target add aarch64-apple-darwin x86_64-apple-darwin --toolchain "$TC" 2>&1 | tail -4

echo; echo "===== build macOS slices ($TC) ====="
for T in aarch64-apple-darwin x86_64-apple-darwin; do
  echo "--- $T ---"; cargo "+$TC" build -r -p ur-registry-ffi --target "$T" --no-default-features 2>&1 | tail -3
done
mkdir -p target/macos
lipo target/aarch64-apple-darwin/release/libur_registry_ffi.a \
     target/x86_64-apple-darwin/release/libur_registry_ffi.a \
     -create -output target/macos/libur_registry_ffi.a
echo "macOS lib archs:"; lipo -info target/macos/libur_registry_ffi.a

echo; echo "===== localize _rust_eh_personality (macOS only) ====="
# libzcashlc (statically linked into the macOS app) also defines Rust's `_rust_eh_personality`.
# Two static Rust libs defining it -> ld duplicate-symbol error on macOS (iOS's linker tolerates it).
# Make ours local so libzcashlc's wins; all FFI exports are preserved.
OBJCOPY=$(find "$HOME/.rustup/toolchains" -name llvm-objcopy 2>/dev/null | head -1)
if [ -z "$OBJCOPY" ]; then rustup component add llvm-tools 2>&1 | tail -1; OBJCOPY=$(find "$HOME/.rustup/toolchains" -name llvm-objcopy 2>/dev/null | head -1); fi
LOC=target/macos/loc; rm -rf "$LOC"; mkdir -p "$LOC"
for arch in $(lipo -archs target/macos/libur_registry_ffi.a); do
  lipo target/macos/libur_registry_ffi.a -thin "$arch" -output "$LOC/$arch.a"
  "$OBJCOPY" --localize-symbol=_rust_eh_personality "$LOC/$arch.a" "$LOC/f_$arch.a"
done
lipo "$LOC"/f_*.a -create -output target/macos/libur_registry_ffi.a
echo "localized: $(nm target/macos/libur_registry_ffi.a | grep 'rust_eh_personality$' | awk '{print $2}' | sort | uniq -c | tr '\n' ' ')"

echo; echo "===== download + verify official sdk-0.2.3 iOS xcframework ====="
cd /tmp
curl -fsSL -o URRegistryFFI-official.zip "https://github.com/KeystoneHQ/keystone-sdk-rust/releases/download/sdk-0.2.3/URRegistryFFI.xcframework.zip"
echo "expected sha256: 5cfeb76962d2727824e65ebc4829a0e5e96013d1c71b5c49b8025a1634f8d442"
echo "actual sha256:   $(shasum -a 256 URRegistryFFI-official.zip | awk '{print $1}')"
rm -rf /tmp/official && mkdir -p /tmp/official && (cd /tmp/official && unzip -q ../URRegistryFFI-official.zip)
OFF=$(find /tmp/official -name "URRegistryFFI.xcframework" -maxdepth 3 | head -1)
echo "official: $OFF"; for d in "$OFF"/*/; do echo "[$d]"; ls "$d"; done

echo; echo "===== splice official iOS + matched macOS ====="
DEV_LIB=$(ls "$OFF"/ios-arm64/*.a 2>/dev/null | head -1)
SIM_DIR=$(ls -d "$OFF"/ios-arm64*simulator* 2>/dev/null | head -1)
SIM_LIB=$(ls "$SIM_DIR"/*.a 2>/dev/null | head -1)
DEV_HDR="$OFF/ios-arm64/Headers"
echo "dev:$DEV_LIB  sim:$SIM_LIB  hdr:$DEV_HDR"
rm -rf /tmp/URRegistryFFI.xcframework
xcodebuild -create-xcframework \
  -library "$DEV_LIB" -headers "$DEV_HDR" \
  -library "$SIM_LIB" -headers "$SIM_DIR/Headers" \
  -library "$RUST/target/macos/libur_registry_ffi.a" -headers "$DEV_HDR" \
  -output /tmp/URRegistryFFI.xcframework 2>&1 | tail -6

echo; echo "===== RESULT ====="
ls /tmp/URRegistryFFI.xcframework
plutil -p /tmp/URRegistryFFI.xcframework/Info.plist | grep -E "LibraryIdentifier|SupportedPlatform|Variant"
echo "===== DONE ====="
