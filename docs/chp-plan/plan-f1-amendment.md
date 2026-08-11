# F1 amendment — software delegation-signing passthrough

Four splice-ready pieces plus an evidence block. `## TASK 4B` slots into `CHP_PLAN.md` between
Task 4 and Task 5 (it must land **before** the T5 FFI rebuild so the new symbol ships in the
slices). `## STEP 8.14 REPLACEMENT` replaces the current step 8.14 verbatim. `## T5 GATE
AMENDMENT` is a one-line edit to step 5.2. `## INTERFACES ADDENDUM` appends to
`docs/chp-plan/plan-sdk-lane.md` → `## INTERFACES-FOR-APP`.

---

## TASK 4B

### Task 4B: S4b — software delegation-signing passthrough [F1 resolution]

*Code blocks by: Opus (F1 amendment delegate). Rust and Swift are written-from-reading against
`zcash_voting 2.0.0-rc.5`'s cached source and the SDK worktree pinned at `7e4f03e7`; the Rust
compiles at this task's own steps 4B.4/4B.5, the Swift compiles and the test executes at plan
Task 6.*

This task resolves the STOP finding that Task 8's step 8.14 used to raise (`## CORRECTIONS`
item 4, app lane): the software (non-Keystone) delegation path had no signature source under
the 2.0 API. It does have one — `zcash_voting` prescribes it. The crate stopped deriving
account keys and signing on the caller's behalf, and in the same release added
`delegate::signing_request`, which hands the wallet the account index, network, seed
fingerprint, PCZT sighash and spend-auth randomizer for one bundle and expects the wallet to
derive its own Orchard SpendAuth key, randomize it with the randomizer, sign the sighash, and
hand back the detached signature. That recipe is stated in the crate's own doc comment
(`src/delegate.rs:405-410`) and README ("Secret boundaries", `README.md:235-241`), and is
implemented, shipped and unit-tested in the crate authors' own reference wallet, Vizor
(`chainapsis/vizor-wallet`, `rust/src/wallet/voting/delegation.rs:318-349`). This task
transcribes that implementation behind one FFI symbol.

Shape: the S4 passthrough pattern (Task 3) plus ~20 lines of crypto that are transcribed, not
designed. Everything the recipe needs — `orchard`, `pasta_curves`, `ff`, `zip32`, `rand`,
`zcash_keys` — is already a direct dependency of `rust/Cargo.toml`, so no dependency changes.
The FFI generates its C header with cbindgen (`rust/build.rs`), so there is **no header file to
edit**.

**Files:**
- Create: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting/signing.rs`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/rust/src/voting.rs` (module list)
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`
- Modify: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/CHANGELOG.md`
- Test: `~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk/Tests/OfflineTests/VotingSignDelegationRequestTests.swift`

**Interfaces:**
- Consumes: `zcash_voting::delegate::signing_request` (rc.5 `delegate.rs:874`) and its result
  `delegate::DelegationSigningRequest` (`delegate.rs:412-426`); `delegate::DelegationKeys::with_voting_hotkey`
  (`delegate.rs:84-100`), reconstructed exactly as `zcashlc_voting_build_and_prove_delegation`
  already does; `zcash_keys::keys::UnifiedSpendingKey`, `orchard::keys::SpendAuthorizingKey`,
  `pasta_curves::pallas::Scalar`, `zip32::fingerprint::SeedFingerprint` — all existing direct
  dependencies.
- Produces: C symbol `zcashlc_voting_sign_delegation_request`; Swift
  `VotingRustBackend.signDelegationRequest(roundId:bundleIndex:keys:seed:)` returning the new
  `VotingDelegationSignature`. Plan Task 8 (step 8.14) consumes it; the exact signature is in
  `## INTERFACES-FOR-APP`.

**Security note for the executing delegate:** `seed` is wallet root seed material and this is
the only voting FFI entry point that takes it. Handle it exactly as the existing seed-taking
voting FFI does (`zcashlc_voting_generate_delegation_inputs`, `rust/src/voting/util.rs:33-86`):
borrow it through `bytes_from_ptr`, never copy it into an owned buffer, never log it, never
persist it, never pass it to `zcash_voting`. There is deliberately no zeroization step, because
there is deliberately no copy to zeroize — the Swift caller owns the allocation and its
lifetime, which is the same contract every other voting FFI byte input has. Do not add
`println!`/`dbg!`/`log::` calls to this module, even temporarily while debugging.

---

- [ ] **Step 4B.1: Create the signing FFI module.** Create `rust/src/voting/signing.rs` with
exactly this content:

```rust
use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ff::PrimeField;
use ffi_helpers::panic::catch_panic;
use pasta_curves::pallas;
use serde::Serialize;
use zcash_voting as voting;
use zip32::AccountId;

use crate::unwrap_exc_or_null;

use super::constants::SEED_FINGERPRINT_LEN;
use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr, usk_from_seed};

/// The detached SpendAuth signature this wallet produced for one delegation
/// bundle, with the sighash it covers.
///
/// Not a mirror of any `zcash_voting` wire type: the crate has no type for a
/// bare `(signature, sighash)` pair, because it never sees the signing step.
/// This is the FFI's own two-field return envelope, so it lives here rather
/// than in `json.rs`.
#[derive(Serialize)]
struct JsonDelegationSignature {
    sig: Vec<u8>,
    sighash: Vec<u8>,
}

/// Sign one delegation bundle's PCZT sighash with the account's own Orchard
/// SpendAuth key.
///
/// This implements `zcash_voting`'s own prescribed software-wallet recipe; it
/// is not an SDK invention. The crate stopped deriving account keys and signing
/// on the caller's behalf in 2.0 and documents the replacement on
/// `delegate::DelegationSigningRequest` (rc.5 `src/delegate.rs:405-410`): a
/// software wallet uses `account_index`, `network`, `sighash` and `alpha` to
/// derive its account SpendAuth key locally, randomizes it, signs `sighash`,
/// and passes the resulting signature back. The crate README states the same
/// under "Secret boundaries" (`README.md:235-241`). The derive → randomize →
/// sign body below is transcribed from the crate authors' own reference wallet,
/// Vizor (`chainapsis/vizor-wallet`, `rust/src/wallet/voting/delegation.rs:318-349`),
/// which ships it with a signature-verifying round-trip test.
///
/// Two calls make one delegation submission: this one produces the signature,
/// then `zcashlc_voting_get_delegation_submission_with_signature` consumes it.
/// The sighash returned here is not decorative — the crate checks it against
/// the sighash it stored at setup and refuses the submission if they disagree.
/// The Keystone flow differs only in where the signature comes from.
///
/// `fvk_bytes`, `hotkey_stored_secret`, `seed_fingerprint`, `account_index` and
/// `round_name` are the same delegation-key inputs
/// `zcashlc_voting_build_and_prove_delegation` takes, because the crate loads
/// the signing request through the same `DelegationKeys` value that built the
/// PCZT.
///
/// # Key material
///
/// `seed` is wallet root seed material — the only voting FFI entry point that
/// takes it. It is borrowed for the duration of the call through
/// `bytes_from_ptr` and never copied into an owned buffer, so there is nothing
/// here to zeroize; the caller owns the allocation and its lifetime, exactly as
/// for every other voting FFI byte input. It is never logged, never persisted
/// and never handed to `zcash_voting`: only the locally derived randomized key
/// touches it, and only the 64-byte detached signature leaves this function.
///
/// Returns JSON-encoded `{"sig": [..64], "sighash": [..32]}` as
/// `*mut FfiBoxedSlice`, or null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For every `(ptr, len)` byte argument (`round_id`, `fvk_bytes`,
///   `hotkey_stored_secret`, `seed_fingerprint`, `round_name`, `seed`): if
///   `len > 0` then `ptr` must be non-null and valid for reads for `len` bytes;
///   if `len == 0`, `ptr` is ignored.
/// - `seed` must remain valid and unmutated for the duration of the call. The
///   callee neither retains nor frees it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_sign_delegation_request(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    fvk_bytes: *const u8,
    fvk_bytes_len: usize,
    hotkey_stored_secret: *const u8,
    hotkey_stored_secret_len: usize,
    seed_fingerprint: *const u8,
    seed_fingerprint_len: usize,
    account_index: u32,
    round_name: *const u8,
    round_name_len: usize,
    seed: *const u8,
    seed_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let fvk = unsafe { bytes_from_ptr(fvk_bytes, fvk_bytes_len) }?;
        let hotkey_secret =
            unsafe { bytes_from_ptr(hotkey_stored_secret, hotkey_stored_secret_len) }?;
        let seed_fp_bytes = unsafe { bytes_from_ptr(seed_fingerprint, seed_fingerprint_len) }?;
        let seed_fp_32: [u8; SEED_FINGERPRINT_LEN] = seed_fp_bytes.try_into().map_err(|_| {
            anyhow!(
                "seed_fingerprint must be {} bytes, got {}",
                SEED_FINGERPRINT_LEN,
                seed_fp_bytes.len()
            )
        })?;
        let round_name_str = unsafe { str_from_ptr(round_name, round_name_len) }?;
        let seed_bytes = unsafe { bytes_from_ptr(seed, seed_len) }?;

        let hotkey = voting::VotingHotkey::from_stored_secret(hotkey_secret, handle.network)
            .map_err(|e| anyhow!("failed to reconstruct voting hotkey: {}", e))?;
        let keys = voting::delegate::DelegationKeys::with_voting_hotkey(
            fvk.to_vec(),
            &hotkey,
            seed_fp_32,
            account_index,
            round_name_str,
        )
        .map_err(|e| anyhow!("failed to build delegation keys: {}", e))?;

        let request =
            voting::delegate::signing_request(&handle.db, &round_id_str, bundle_index, &keys)
                .map_err(|e| anyhow!("signing_request failed: {}", e))?;

        // Bind the request to this exact wallet seed before deriving any keys.
        let seed_fp = zip32::fingerprint::SeedFingerprint::from_seed(seed_bytes)
            .ok_or_else(|| anyhow!("seed length is not valid for ZIP-32"))?;
        if seed_fp.to_bytes() != request.seed_fingerprint {
            return Err(anyhow!(
                "wallet seed fingerprint does not match the delegation signing request"
            ));
        }

        // The request's network is the round's stored network: the crate
        // validated `keys.network` (which came from `handle.network` through
        // the hotkey) against it before answering. Asserting it here is what
        // makes deriving through the SDK's own `usk_from_seed(handle.network_id,
        // ..)` provably equivalent to deriving from `request.network` directly,
        // and it fails closed if a later release sources that field elsewhere.
        if request.network != handle.network {
            return Err(anyhow!(
                "delegation signing request network does not match the open voting database"
            ));
        }

        let account = AccountId::try_from(request.account_index).map_err(|_| {
            anyhow!(
                "account_index must be < 2^31, got {}",
                request.account_index
            )
        })?;
        let usk = usk_from_seed(handle.network_id, seed_bytes, account)
            .map_err(|e| anyhow!("failed to derive sender UnifiedSpendingKey: {}", e))?;
        let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());

        // The alpha randomizer must decode as a canonical Pallas scalar.
        let alpha = Option::<pallas::Scalar>::from(pallas::Scalar::from_repr(request.alpha))
            .ok_or_else(|| anyhow!("delegation alpha is not a canonical Pallas scalar"))?;

        // Sign the request's own sighash with the randomized spend auth key.
        let rsk = ask.randomize(&alpha);
        let sig = rsk.sign(rand::rngs::OsRng, &request.sighash);
        let sig_bytes: [u8; 64] = (&sig).into();

        json_to_boxed_slice(&JsonDelegationSignature {
            sig: sig_bytes.to_vec(),
            sighash: request.sighash.to_vec(),
        })
    });
    unwrap_exc_or_null(res)
}
```

- [ ] **Step 4B.2: Register the module.** In `rust/src/voting.rs`, replace:

```rust
pub mod share_tracking;
#[cfg(test)]
```

with:

```rust
pub mod share_tracking;
pub mod signing;
#[cfg(test)]
```

(This is the post-Task-3 module list, which already begins with `pub mod confirmation;`. If
`pub mod share_tracking;` is not present, Task 3 did not land — stop and check the SDK
worktree's `git log --oneline -6` before continuing.)

- [ ] **Step 4B.3: No dependency changes — assert it.** The recipe's crates must already be
direct dependencies. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -n '^orchard\|^pasta_curves\|^ff \|^zip32\|^rand ' Cargo.toml; git diff --stat -- Cargo.toml Cargo.lock
```

Expected: five lines from the `grep` (`orchard`, `pasta_curves`, `ff`, `zip32`, `rand`), and
**no output at all** from `git diff --stat` — this task adds no dependency and must not touch
either manifest. If a crate is missing from `Cargo.toml`, **stop**: the transcription assumed
it, and adding a dependency is outside this task's scope. If a manifest diff appears, it came
from somewhere else — surface it rather than committing it here.

- [ ] **Step 4B.4: Rust format + compile gates.** Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && cargo fmt && cargo fmt -- --check && set -o pipefail && cargo check 2>&1 | tee /tmp/chp-t4b-cargo.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, only the pre-existing `migration_plan_cache.rs:77` warning. A
`too_many_arguments` complaint cannot appear here (the gates run `cargo check`, not `cargo
clippy`, and no sibling FFI function in this crate carries an allow attribute for it — do not
add one).

- [ ] **Step 4B.5: Header-generation assert.** cbindgen writes the C header during the build, so
the new declaration must already be there. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && grep -c 'zcashlc_voting_sign_delegation_request' target/Headers/zcashlc.h
```

Expected: `1`. If the file does not exist, run `cargo check` once more (the header is a
build-script side effect) and retry. `0` means the symbol did not export — report it and stop.

- [ ] **Step 4B.6: Rust test gate (count must not move).** This task adds no Rust unit tests, so
the voting suite's count must be exactly what Task 3's step 3.6 reported. Run:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && set -o pipefail; cargo test --lib voting 2>&1 | tee /tmp/chp-t4b-cargotest.log | tail -5; echo "REAL_EXIT=$?"
```

Expected: `REAL_EXIT=0`, `test result: ok. 72 passed; 0 failed` — the same 72 Task 3 gated on. A
different count means something other than this task changed the suite; surface it.

- [ ] **Step 4B.7: Add the Swift signature type.** Append to the end of
`Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift` (after the `VotingVoteConfirmation`
block Task 3 added):

```swift

// MARK: - Delegation signature (JSON)

/// A SpendAuth signature this wallet produced for one delegation bundle, with
/// the sighash it covers.
///
/// Both values go straight into
/// ``VotingRustBackend/getDelegationSubmission(roundId:bundleIndex:signature:sighash:)``.
/// The sighash is not informational: `zcash_voting` checks it against the one it
/// stored when the bundle's PCZT was set up and rejects the submission if they
/// disagree, so pass back the value that came out with the signature rather than
/// one recomputed elsewhere.
public struct VotingDelegationSignature: Codable, Sendable, Equatable {
    /// The 64-byte detached RedPallas SpendAuth signature.
    public let signature: [UInt8]
    /// The 32-byte ZIP-244 sighash the signature covers.
    public let sighash: [UInt8]

    enum CodingKeys: String, CodingKey {
        case signature = "sig"
        case sighash
    }
}
```

- [ ] **Step 4B.8: Add the `signDelegationRequest` wrapper.** In
`Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift`, inside the
`// MARK: - Delegation workflow` extension, replace:

```swift
    /// Get the delegation submission payload for an externally produced
    /// signature.
```

with:

```swift
    /// Sign one delegation bundle's PCZT sighash with this account's own Orchard
    /// SpendAuth key.
    ///
    /// `zcash_voting` 2.0 stopped deriving account keys and signing for its
    /// callers, and prescribes this replacement for software wallets: load the
    /// bundle's signing request (account index, network, seed fingerprint,
    /// sighash and spend-auth randomizer), derive the account SpendAuth key from
    /// the wallet seed, randomize it with the randomizer, and sign the sighash.
    /// All of that happens in Rust — the seed goes in, only the detached
    /// signature comes back out.
    ///
    /// This is the software counterpart of the Keystone flow: there, the device
    /// produces the signature and the app extracts it from the signed PCZT; here
    /// the wallet produces it itself. Both then call the same
    /// ``getDelegationSubmission(roundId:bundleIndex:signature:sighash:)``,
    /// which is the only remaining path into a submission payload.
    ///
    /// - Parameters:
    ///   - keys: the same ``VotingDelegationKeyInputs`` used to build and prove
    ///     this bundle. The crate loads the signing request through them, so a
    ///     different account index, hotkey secret or seed fingerprint fails
    ///     instead of silently signing for the wrong account.
    ///   - seed: the wallet's root seed, at least 32 bytes. It is borrowed for
    ///     the duration of this call, is never persisted or logged, and must be
    ///     the seed whose fingerprint is in `keys` — a mismatch throws rather
    ///     than producing a signature the chain would reject.
    /// - Returns: the detached 64-byte SpendAuth signature and the 32-byte
    ///   ZIP-244 sighash it covers. Pass both to `getDelegationSubmission`
    ///   unchanged.
    /// - Throws: ``VotingRustBackendError/databaseNotOpen`` if no database is
    ///   open; ``VotingRustBackendError/invalidData`` if `seed` or the seed
    ///   fingerprint is the wrong length; ``VotingRustBackendError/rustError``
    ///   if the bundle has no stored signing request yet (its PCZT setup has not
    ///   run), or the seed does not match the request.
    public func signDelegationRequest(
        roundId: String,
        bundleIndex: UInt32,
        keys: VotingDelegationKeyInputs,
        seed: [UInt8]
    ) throws -> VotingDelegationSignature {
        guard keys.seedFingerprint.count == votingSeedFingerprintByteCount else {
            throw VotingRustBackendError.invalidData(
                "seedFingerprint must be exactly \(votingSeedFingerprintByteCount) bytes"
            )
        }
        guard seed.count >= votingMinSeedByteCount else {
            throw VotingRustBackendError.invalidData(
                "seed must be at least \(votingMinSeedByteCount) bytes"
            )
        }

        let roundIdBytes = [UInt8](roundId.utf8)
        let roundNameBytes = [UInt8](keys.roundName.utf8)

        let ptr: UnsafeMutablePointer<FfiBoxedSlice> = try withHandle { dbh in
            let ptr: UnsafeMutablePointer<FfiBoxedSlice>? = roundIdBytes.withUnsafeBufferPointer { ridBuf in
                keys.fvk.withUnsafeBufferPointer { fvkBuf in
                    keys.hotkeyStoredSecret.withUnsafeBufferPointer { secretBuf in
                        keys.seedFingerprint.withUnsafeBufferPointer { fpBuf in
                            roundNameBytes.withUnsafeBufferPointer { nameBuf in
                                seed.withUnsafeBufferPointer { seedBuf in
                                    zcashlc_voting_sign_delegation_request(
                                        dbh,
                                        ridBuf.baseAddress,
                                        UInt(ridBuf.count),
                                        bundleIndex,
                                        fvkBuf.baseAddress,
                                        UInt(fvkBuf.count),
                                        secretBuf.baseAddress,
                                        UInt(secretBuf.count),
                                        fpBuf.baseAddress,
                                        UInt(fpBuf.count),
                                        keys.accountIndex,
                                        nameBuf.baseAddress,
                                        UInt(nameBuf.count),
                                        seedBuf.baseAddress,
                                        UInt(seedBuf.count)
                                    )
                                }
                            }
                        }
                    }
                }
            }
            guard let ptr else {
                throw VotingRustBackendError.rustError(
                    lastErrorMessage(fallback: "`sign_delegation_request` failed")
                )
            }
            return ptr
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        return try decodeJSON(from: ptr)
    }

    /// Get the delegation submission payload for an externally produced
    /// signature.
```

The two methods are now adjacent and in call order — sign, then submit.

- [ ] **Step 4B.9: Add the offline test file.** Create
`Tests/OfflineTests/VotingSignDelegationRequestTests.swift` with exactly this content. It
follows the existing suite's DB-fixture pattern (`VotingRustBackendTests.swift`, and Task 3's
two files): a canonical 64-hex round id, a temp-path database opened per test and cleaned up in
`tearDown`, and assertions on the error surfaces an offline test can reach. The success path is
not testable offline — a signature requires a bundle whose PCZT setup ran against a real round,
so it belongs to the testnet E2E round.

```swift
//
//  VotingSignDelegationRequestTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

/// Builds a round identifier that satisfies the Rust round-parameter validation,
/// which requires 64 lowercase hex characters encoding a canonical Pallas field
/// element. `tag` occupies the low byte so each caller gets a distinct round.
private func signHexRoundId(_ tag: UInt8) -> String {
    String(format: "%02x", tag) + String(repeating: "00", count: 31)
}

private let signWalletId = "test-wallet"
private let signNetworkId: UInt32 = 1
/// A well-formed round identifier that is never initialized, so the crate has no
/// stored signing request to answer with.
private let signMissingRoundId = signHexRoundId(0xfc)
/// Orchard FVK length. The value is never used as a key here: the crate reads
/// only the account index, seed fingerprint and network out of the delegation
/// keys when loading a signing request.
private let signFvk = [UInt8](repeating: 0, count: 96)
private let signSeedFingerprint = [UInt8](repeating: 7, count: 32)
private let signSeed = [UInt8](repeating: 9, count: 32)
private let signRoundName = "chp-offline"

final class VotingSignDelegationRequestTests: XCTestCase {
    private var dbPath: String?

    override func tearDown() {
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        dbPath = nil
        super.tearDown()
    }

    func test_signDelegationRequest_shortSeed_throwsInvalidData() throws {
        let backend = VotingRustBackend()

        XCTAssertThrowsError(
            try backend.signDelegationRequest(
                roundId: signMissingRoundId,
                bundleIndex: 0,
                keys: try makeKeys(),
                seed: [UInt8](repeating: 9, count: 31)
            )
        ) { error in
            guard case VotingRustBackendError.invalidData(let message) = error else {
                XCTFail("expected .invalidData, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("seed must be at least"),
                "unexpected message: \(message)"
            )
        }
    }

    func test_signDelegationRequest_beforeOpen_throwsDatabaseNotOpen() throws {
        let backend = VotingRustBackend()

        XCTAssertThrowsError(
            try backend.signDelegationRequest(
                roundId: signMissingRoundId,
                bundleIndex: 0,
                keys: try makeKeys(),
                seed: signSeed
            )
        ) { error in
            guard case VotingRustBackendError.databaseNotOpen = error else {
                XCTFail("expected .databaseNotOpen, got \(error.localizedDescription)")
                return
            }
        }
    }

    func test_signDelegationRequest_afterOpen_missingRound_throwsRustError() throws {
        let backend = try makeOpenBackend()
        defer { backend.close() }

        XCTAssertThrowsError(
            try backend.signDelegationRequest(
                roundId: signMissingRoundId,
                bundleIndex: 0,
                keys: try makeKeys(),
                seed: signSeed
            )
        ) { error in
            guard case VotingRustBackendError.rustError(let message) = error else {
                XCTFail("expected .rustError, got \(error.localizedDescription)")
                return
            }
            XCTAssertTrue(
                message.contains("signing_request failed"),
                "unexpected message: \(message)"
            )
        }
    }

    // MARK: - Helpers

    /// A hotkey secret has to be real: the FFI reconstructs a `VotingHotkey`
    /// from it before it can build the delegation keys the signing request is
    /// loaded through. `generateHotkey` is static and needs no database.
    private func makeKeys() throws -> VotingDelegationKeyInputs {
        let hotkey = try VotingRustBackend.generateHotkey(networkId: signNetworkId)
        return VotingDelegationKeyInputs(
            fvk: signFvk,
            hotkeyStoredSecret: hotkey.storedSecret,
            seedFingerprint: signSeedFingerprint,
            accountIndex: 0,
            roundName: signRoundName
        )
    }

    private func makeTempDbPath() -> String {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let path = "\(NSTemporaryDirectory())VotingSignDelegationRequestTests-\(unique).sqlite"
        dbPath = path
        return path
    }

    private func makeOpenBackend() throws -> VotingRustBackend {
        let backend = VotingRustBackend()
        try backend.open(path: makeTempDbPath(), networkId: signNetworkId)
        try backend.setWalletId(signWalletId)
        return backend
    }
}
```

This file runs at plan Task 6 (`swift test --filter OfflineTests`), after the FFI rebuild in
plan Task 5 puts the new symbol in the library. It cannot run before that.

- [ ] **Step 4B.10: CHANGELOG.** In `CHANGELOG.md`, under `# Unreleased` → `## Added`, append
this bullet at the end of that section (immediately before the `## Changed` heading — after the
bullet Task 4 added):

```markdown
- `VotingRustBackend.signDelegationRequest(roundId:bundleIndex:keys:seed:)` lets a software
  wallet produce the SpendAuth signature a delegation submission needs. `zcash_voting 2.0` no
  longer derives account keys or signs for its callers, which left
  `getDelegationSubmission(roundId:bundleIndex:signature:sighash:)` reachable only by hardware
  signers; this is the crate's own prescribed software path — it loads the bundle's signing
  request, derives the account Orchard SpendAuth key from the wallet seed, randomizes it with
  the request's spend-auth randomizer and signs the stored ZIP-244 sighash, returning the
  detached signature and that sighash as `VotingDelegationSignature`. The seed is borrowed for
  the call and never persisted, logged or handed to `zcash_voting`; the signature is checked
  against the seed fingerprint the bundle was built for, so signing with the wrong seed fails
  instead of producing a rejected transaction. Software and hardware delegation now converge on
  the same submission entry point.
```

- [ ] **Step 4B.11: Commit.**

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && git add rust/src/voting.rs rust/src/voting/signing.rs Sources/ZcashLightClientKit/Rust/Voting/VotingTypes.swift Sources/ZcashLightClientKit/Rust/Voting/VotingRustBackend.swift Tests/OfflineTests/VotingSignDelegationRequestTests.swift CHANGELOG.md && git commit -m "[#1855] Add the software delegation-signing passthrough zcash_voting 2.0 prescribes" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## STEP 8.14 REPLACEMENT

Replaces the current step 8.14 in full. **The STOP finding it raised is resolved** — the F1
recon established that the software signing mechanism is crate-prescribed and
reference-implemented, and plan Task 4B ships it as
`VotingRustBackend.signDelegationRequest(roundId:bundleIndex:keys:seed:)`. `## CORRECTIONS`
item 4's diagnosis stands (the 5-arg seed-based call cannot be satisfied positionally or
semantically); only its conclusion — "no signature source exists" — is superseded. Nothing else
in Task 8 changes.

- [ ] **Step 8.14: Wire the software delegation path to the new signing wrapper.**
`VotingCoordFlowCoordinator.swift` calls `votingCrypto.getDelegationSubmission(roundId,
bundleIndex, senderSeed, networkId, accountIndex)` twice inside `static func
runDelegationPipeline` — once as a "is it already cached?" probe (near `:3557`) and once for
real after proving (near `:3591`). Both become a two-call chain: sign, then submit. Locate them
by the quoted context, not by line number.

First, add the client member. In `VotingCryptoClientInterface.swift`, replace:

```swift
    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash.
```

with:

```swift
    /// Produce this wallet's own SpendAuth signature for one delegation bundle.
    /// The software counterpart of the Keystone QR round-trip: `zcash_voting` 2.0 no longer
    /// derives account keys or signs for its callers, and prescribes exactly this instead —
    /// load the bundle's signing request, derive the account SpendAuth key from the seed,
    /// randomize it with the request's randomizer, sign the request's sighash. All of it
    /// happens inside the SDK; the seed goes in, only the detached signature comes back.
    /// Feed the result straight into `getDelegationSubmission`.
    var signDelegationRequest: @Sendable (
        _ roundId: String,
        _ bundleIndex: UInt32,
        _ senderSeed: [UInt8],
        _ hotkeyStoredSecret: [UInt8],
        _ networkId: UInt32,
        _ accountIndex: UInt32,
        _ roundName: String
    ) async throws -> (signature: Data, sighash: Data)

    /// Reconstruct the chain-ready delegation TX payload from a previously-produced
    /// SpendAuth signature + ZIP-244 sighash.
```

(The anchor is the first two lines of the doc comment step 8.4 wrote; the new member goes
immediately above it. `VotingCryptoClientTestKey.swift` still needs no edit — `@DependencyClient`
synthesizes the unimplemented default, per `## CORRECTIONS` item 2.)

Second, implement it. In `VotingCryptoClientLiveKey.swift`, replace:

```swift
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
```

with:

```swift
            signDelegationRequest: { roundId, bundleIndex, senderSeed, hotkeyStoredSecret, networkId, accountIndex, roundName in
                let backend = try await dbActor.backend()
                // Same derivation the software branch of `buildVotingPczt` uses: the sender's
                // Orchard FVK and ZIP-32 seed fingerprint come from the seed itself, so the
                // delegation keys here are byte-identical to the ones that built the PCZT.
                let inputs = try VotingRustBackend.generateDelegationInputs(
                    senderSeed: senderSeed,
                    hotkeyStoredSecret: hotkeyStoredSecret,
                    networkId: networkId,
                    accountIndex: accountIndex
                )
                let signed = try backend.signDelegationRequest(
                    roundId: roundId,
                    bundleIndex: bundleIndex,
                    keys: VotingDelegationKeyInputs(
                        fvk: inputs.fvkBytes,
                        hotkeyStoredSecret: hotkeyStoredSecret,
                        seedFingerprint: inputs.seedFingerprint,
                        accountIndex: accountIndex,
                        roundName: roundName
                    ),
                    seed: senderSeed
                )
                return (signature: Data(signed.signature), sighash: Data(signed.sighash))
            },
            getDelegationSubmission: { roundId, bundleIndex, signature, sighash in
```

Third, rewire the cached-submission probe. In `VotingCoordFlowCoordinator.swift`, replace:

```swift
            let registration: DelegationRegistration
            if let cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                roundId, bundleIndex, senderSeed, networkId, accountIndex
            ) {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
            } else {
```

with:

```swift
            let registration: DelegationRegistration
            // The cache probe is now two calls: signing succeeds once the bundle's PCZT setup
            // is stored, and the submission only assembles once its proof is too. Either one
            // failing means this bundle is not finished yet, so fall through and build it.
            let cachedSignature = try? await votingCrypto.signDelegationRequest(
                roundId, bundleIndex, senderSeed, hotkeySeed, networkId, accountIndex, roundName
            )
            let cachedRegistration: DelegationRegistration?
            if let cachedSignature {
                cachedRegistration = try? await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, cachedSignature.signature, cachedSignature.sighash
                )
            } else {
                cachedRegistration = nil
            }

            if let cachedRegistration {
                LoggerProxy.debug("Delegation bundle \(bundleIndex + 1)/\(bundleCount) using cached submission")
                registration = cachedRegistration
            } else {
```

Fourth, rewire the post-proving call. In the same function, replace:

```swift
                registration = try await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, senderSeed, networkId, accountIndex
                )
```

with:

```swift
                let signed = try await votingCrypto.signDelegationRequest(
                    roundId, bundleIndex, senderSeed, hotkeySeed, networkId, accountIndex, roundName
                )
                registration = try await votingCrypto.getDelegationSubmission(
                    roundId, bundleIndex, signed.signature, signed.sighash
                )
```

`hotkeySeed` and `roundName` are both `runDelegationPipeline` parameters already in scope at
both sites, so nothing new is threaded through the coordinator. The `hotkeySeed` local keeps
its name and starts carrying the hotkey **stored secret** at Task 10 step 10.14, exactly as it
does for the neighbouring `buildVotingPczt` / `buildAndProveDelegation` calls in this same
function — which is why the new member's parameter is named `hotkeyStoredSecret` from the
start. Task 10 needs no amendment for this member.

`runDelegationPipeline` already carries
`// swiftlint:disable:next function_body_length function_parameter_count`, which covers the
handful of lines this step adds.

**Reporting:** record in the T8 report that the F1 STOP finding is closed by plan Task 4B (SDK
commit `[#1855] Add the software delegation-signing passthrough zcash_voting 2.0 prescribes`),
and that `:3557`/`:3591` are now expected to compile. If Task 4B's commit is not present in the
SDK worktree (`git log --oneline -8` there), **stop** — do not hand-roll signing code in the
app; that would put key derivation in the wrong layer and is forbidden by §0.2.

---

## T5 GATE AMENDMENT

Task 5, step 5.2 — replace the command's `grep -c` pattern so the gate also proves the F1 symbol
shipped in the slices. New command:

```bash
cd ~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk && FW=$(find LocalPackages -name 'libzcashlc' -path '*macos*' | head -1) && lipo -archs "$FW" && nm -gU "$FW" | grep -c 'zcashlc_voting_commit_vote\|zcashlc_voting_confirm_vote_submission\|zcashlc_voting_recover_wire_json\|zcashlc_voting_sign_delegation_request'
```

Expected count is now **exactly 4** (was 3). Fewer → a T3 or T4B symbol didn't export (check
`nm -gU "$FW" | grep zcashlc_voting_` for what is actually there and report); do not proceed.
Repeat the `nm` gate for the ios-sim slice (`-path '*simulator*'`), same expected 4.

---

## INTERFACES ADDENDUM

Append to `docs/chp-plan/plan-sdk-lane.md` → `## INTERFACES-FOR-APP`, after `### New methods on
VotingRustBackend`.

### New type (Task 4B)

```swift
/// A SpendAuth signature this wallet produced for one delegation bundle, with the
/// sighash it covers. Both go into `getDelegationSubmission` unchanged — the crate
/// checks the sighash against the one it stored at PCZT setup.
public struct VotingDelegationSignature: Codable, Sendable, Equatable {
    public let signature: [UInt8]  // "sig", 64 bytes
    public let sighash: [UInt8]    // "sighash", 32 bytes
}
```

### New method on `VotingRustBackend` (Task 4B)

```swift
/// Produce this wallet's own SpendAuth signature for one delegation bundle — the
/// software counterpart of the Keystone signature the app extracts from a signed
/// PCZT. `zcash_voting` 2.0 no longer derives account keys or signs for its
/// callers; this is the crate's own prescribed replacement (it loads the bundle's
/// signing request, derives the account Orchard SpendAuth key from `seed`,
/// randomizes it with the request's spend-auth randomizer, and signs the stored
/// ZIP-244 sighash). Everything happens in Rust: the seed is borrowed for the
/// call, never persisted or logged, and never reaches `zcash_voting`.
///
/// `keys` must be the same `VotingDelegationKeyInputs` that built and proved this
/// bundle. `seed` is the wallet root seed, ≥ 32 bytes, and must be the seed whose
/// fingerprint is in `keys` — a mismatch throws rather than producing a signature
/// the chain would reject.
///
/// Throws `.databaseNotOpen`, `.invalidData` (wrong seed or fingerprint length),
/// or `.rustError` (no stored signing request for the bundle yet — its PCZT setup
/// has not run — or a seed/fingerprint mismatch).
public func signDelegationRequest(
    roundId: String,
    bundleIndex: UInt32,
    keys: VotingDelegationKeyInputs,
    seed: [UInt8]
) throws -> VotingDelegationSignature
```

**Call it immediately before `getDelegationSubmission`, every time.** The software delegation
path is now two calls, not one:

```swift
let signed = try backend.signDelegationRequest(
    roundId: roundId, bundleIndex: bundleIndex, keys: keys, seed: senderSeed
)
let submission = try backend.getDelegationSubmission(
    roundId: roundId,
    bundleIndex: bundleIndex,
    signature: signed.signature,
    sighash: signed.sighash
)
```

The signature is not persisted by the SDK, so a caller that needs a submission twice signs
twice; signing is cheap (one key derivation and one RedPallas signature — no proving) and
deterministic in effect, though not byte-identical, since the signature is randomized. `keys`
for the software path is built from
`VotingRustBackend.generateDelegationInputs(senderSeed:hotkeyStoredSecret:networkId:accountIndex:)`
— `inputs.fvkBytes` and `inputs.seedFingerprint` are exactly the values that entry point
already returns.

---

## EVIDENCE

Crate source read at
`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/zcash_voting-2.0.0-rc.5/`. SDK read
read-only through `git show 7e4f03e7:<path>` in
`~/Dev/Xcode/GitHub/LukasKorba/_chp/zcash-swift-wallet-sdk` (no working-tree reads, no writes).
Vizor fetched from `chainapsis/vizor-wallet@main`.

**The crate API this task wraps**
- `src/delegate.rs:874-881` — `pub fn signing_request(db: &VotingDb, round_id: &str, bundle_index: u32, keys: &DelegationKeys) -> Result<DelegationSigningRequest, VotingError>`. The wrapped call.
- `src/delegate.rs:405-410` — the prescribing doc comment ("A software wallet can use `account_index`, `network`, `sighash`, and `alpha` to derive its account SpendAuth key locally, randomize it, sign `sighash` …"). Quoted in the module doc.
- `src/delegate.rs:412-426` — `DelegationSigningRequest { account_index, network, seed_fingerprint, sighash, alpha }`, the fields the body consumes.
- `src/delegate.rs:84-100` — `DelegationKeys::with_voting_hotkey(fvk_bytes, hotkey, seed_fingerprint, account_index, round_name)`, the only public constructor: it is why this FFI takes fvk + hotkey secret + round name it never otherwise reads.
- `src/storage/operations.rs:519-549` — `get_delegation_signing_request`, which `signing_request` delegates to. Two facts the Rust body relies on: it validates `keys.network` against the round's stored network (`validate_network_matches_round`, `:528`) and returns that stored network, and it echoes `keys.seed_fingerprint`/`keys.account_index` straight back (`:534-535`). The first justifies the `request.network != handle.network` assert; the second is why the seed-fingerprint check is a real seed↔account desync guard rather than a tautology.
- `README.md:235-240` — the same recipe in prose ("Software wallets should derive the account SpendAuth key locally, randomize it with `alpha`, sign the sighash …").

**Vizor lines transcribed** — `rust/src/wallet/voting/delegation.rs`
- `:318-349` — `sign_delegation_request()`. Line by line: `:324-330` fingerprint check → my "Bind the request to this exact wallet seed" block; `:333-334` `AccountId::try_from(request.account_index)`; `:335-338` `UnifiedSpendingKey::from_seed` + `SpendAuthorizingKey::from`; `:339-343` `pallas::Scalar::from_repr(request.alpha)` with the canonical-scalar check; `:344-348` `ask.randomize(&alpha)`, `rsk.sign(rand::rngs::OsRng, &request.sighash)`, `(&sig).into()`. The three explanatory comments in my body are Vizor's own, kept verbatim.
- `:299-307` — the surrounding call order (`signing_request` → sign → feed the signature into the submission builder), which the SDK splits across the FFI boundary as sign-here / submit-there.
- `:543-573` — `sign_delegation_request_happy_path_signs_and_verifies`, the round-trip test that proves the recipe (`VerificationKey::from(&ask.randomize(&alpha)).verify(&sighash, &Signature::from(sig))`). Not transcribed — it needs `orchard`'s `VerificationKey`/`Signature` re-exports and a fixture; our offline coverage is the error surface, per Task 3's precedent.
- `:3` `use ff::PrimeField;`, `:7` `use zip32::{fingerprint::SeedFingerprint, AccountId};` — the imports the recipe needs.

**SDK convention files matched** (all at `7e4f03e7`)
- `rust/src/voting/util.rs:33-86` (`zcashlc_voting_generate_delegation_inputs`) — the only existing seed-taking voting FFI. Matched: `seed: *const u8, seed_len: usize` pair, `bytes_from_ptr` borrow with no copy and no zeroization, `AccountId::try_from(...)` with the "account_index must be < 2^31, got {}" message (`:55-56`), `zip32::fingerprint::SeedFingerprint::from_seed(...)` fully qualified rather than imported (`:73`), `usk_from_seed(...)` for derivation (`:59`).
- `rust/src/voting/helpers.rs:92-110` — `usk_from_seed(network_id, seed, account)`, reused as-is; it carries the `MIN_SEED_LEN` (32) guard from `constants.rs:5`.
- `rust/src/voting/helpers.rs:16-56` — `bytes_from_ptr` / `str_from_ptr` / `json_to_boxed_slice`, the boundary helpers; their `# Safety` wording is the model for mine.
- `rust/src/voting/delegation.rs:215-224` and `:567-576` — the `VotingHotkey::from_stored_secret` → `DelegationKeys::with_voting_hotkey` reconstruction, copied verbatim including both error messages.
- `rust/src/voting/delegation.rs:609-657` (`zcashlc_voting_get_delegation_submission_with_signature`) — the downstream consumer, and the `AssertUnwindSafe(db)` + `catch_panic` + `unwrap_exc_or_null` frame every function in this module uses.
- `rust/src/voting/db.rs:15-20` — `VotingDatabaseHandle { db, tree_sync, network, network_id }`, both fields `pub(super)`, so a sibling module reads them directly.
- `rust/src/voting/constants.rs:5,11` — `MIN_SEED_LEN`, `SEED_FINGERPRINT_LEN`.
- `rust/src/voting/json.rs:140-147` — the `Vec<u8>`-as-JSON-array serialization convention `JsonDelegationSignature` follows.
- `CHP_PLAN.md:1205-1279` (Task 3, `confirmation.rs`) — the new-module template: imports, doc-comment shape, `# Safety` bullet list, `json_to_boxed_slice` return.
- `Sources/.../VotingRustBackend.swift:1447-1493` (`getDelegationSubmission`) and `:1362-1413` (`buildPczt`) — the Swift wrapper's `withHandle` / nested `withUnsafeBufferPointer` / `guard let ptr` / `defer { zcashlc_free_boxed_slice(ptr) }` / `decodeJSON` shape, and the `keys.seedFingerprint.count` guard.
- `Sources/.../VotingRustBackend.swift:491-521` (`generateDelegationInputs`) — the `seed.count >= votingMinSeedByteCount` guard and its message.
- `Sources/.../VotingConstants.swift:9-10` — `votingMinSeedByteCount`, `votingSeedFingerprintByteCount`.
- `Sources/.../VotingTypes.swift:415-443` (`VotingKeystoneSignatureRecord`) — the `Codable, Sendable, Equatable` + `CodingKeys` shape `VotingDelegationSignature` follows; `:458-478` (`VotingDelegationKeyInputs`) — the `keys:` bundle the wrapper takes.

**Deviations from Vizor, and why**
1. **Derivation goes through the SDK's `usk_from_seed(handle.network_id, ..)` instead of Vizor's `UnifiedSpendingKey::from_seed(&request.network, ..)`** (`delegation.rs` `:335` in Vizor). Reason: `usk_from_seed` is the SDK's single seed→USK path — it enforces `MIN_SEED_LEN` and routes through `crate::parse_network`, so a custom (modified-mainnet) chain resolves its consensus parameters the same way every other `zcashlc_*` entry point does. Safety of the substitution is asserted explicitly rather than assumed: `request.network != handle.network` returns an error. The two are provably equal today — `keys.network` comes from `handle.network` via the hotkey, `get_delegation_signing_request` validates it against the stored round network and returns that same value (`operations.rs:526-528`) — and `voting::Network` and `NetworkParams` agree on `network_type()` for all three ids (`voting/db.rs:47-58` maps the custom slot from the registered base network), so the derived key is identical either way. The assert exists to fail closed if a later rc sources that field differently.
2. **`SpendAuthorizingKey::from(usk.orchard())` instead of `let sk = *usk.orchard(); SpendAuthorizingKey::from(&sk)`** (Vizor `:337-338`). Same `From<&SpendingKey>` impl, one fewer stack copy of the Orchard spending key. Not really a deviation: Vizor's own test uses this exact form (`:553`).
3. **`zip32::fingerprint::SeedFingerprint` fully qualified, `zip32::AccountId` imported** (Vizor imports both, `:7`). Matches `rust/src/voting/util.rs:55,73`.
4. **`anyhow::Error` with `map_err(|e| anyhow!("… failed: {}", e))` instead of Vizor's `String` errors.** Required: `catch_panic`/`unwrap_exc_or_null` and every sibling in this module are `anyhow`-based, and the Swift wrapper reads the message back through `zcashlc_last_error_*`.
5. **Returns JSON `{sig, sighash}` across the FFI instead of Vizor's in-process `([u8; 64], [u8; 32])` tuple.** Required by the C boundary; matches `json_to_boxed_slice` + `decodeJSON`, the convention every other voting FFI result uses.
6. **No `PreparedSigner::signature(...)` call here** (Vizor `:304`). Our submission step already builds the signer internally via `DelegationSigner::signature_from_bytes` inside `zcashlc_voting_get_delegation_submission_with_signature`, so constructing one on this side would be dead work.

**Refuted / corrected from the recon** — nothing material. Two refinements:
- The recon proposed passing `seed_fingerprint` as an FFI parameter *and* keeping Vizor's fingerprint check, without noting that the crate merely echoes the caller's own fingerprint back (`operations.rs:544`). Verified: the check is still meaningful (it catches an app-side seed↔fingerprint desync, the ZINIT0006 class) but it is **not** a crate-side binding to what the PCZT was built with. The doc comments say what it does and does not prove.
- The recon suggested the Swift wrapper take eight flat parameters. Corrected to `keys: VotingDelegationKeyInputs` + `seed:` — that bundle already exists (`VotingTypes.swift:458-478`), is what `buildPczt`/`buildAndProveDelegation` take, and is `Undescribable` so the hotkey secret cannot leak through logging or reflection. Same information, one existing type instead of a new flat list.
- The recon's estimate (~90-110 Rust, ~45-60 Swift, ~10-line result type) held: the Rust module is 177 lines as written, 99 of them code (the rest doc comments and blanks); the Swift wrapper is 97 lines, 58 of them code; the result type is 12 lines of code. Counted from the code blocks above, not estimated.
