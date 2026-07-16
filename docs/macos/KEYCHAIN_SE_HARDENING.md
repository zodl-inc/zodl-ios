# macOS keychain hardening — Secure-Enclave-wrapped seed

**Status:** IMPLEMENTED + on-device tested (macOS). Seed is Secure-Enclave-wrapped, transparent migration
works, prompt counts verified (see "Verified behavior & architecture" below). Source: *MacOS Keychain
Secrets hardening Analysis* (Codex⇄Claude audit). Branch: `slipstream-macos`. macOS-only.

**Decisions taken (Lukas):** transparent migration (not force-reset); SE-wrap **and** the
`.userPresence` gate in v1; seed first (voting hotkey is a fast-follow).

## Why

On macOS, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` means "readable for the entire login
session," and the login-keychain master key lives in `securityd` memory — extractable by root
(the recurring SIP-bypass case). So the seed, today stored as **plaintext JSON** in a
`kSecClassGenericPassword` item (`WalletStorage.baseQuery`, no access control, no Secure Enclave),
is plaintext-equivalent from login to logout. The Secure Enclave fixes this: a key generated
in-enclave on Apple Silicon is non-extractable even under root + SIP-bypass, and it never enters
process memory. We encrypt the seed with that key and store only ciphertext.

Threat model: same-machine attacker, including root + SIP-bypass. Keystone (hardware wallet) is
out of scope — this is the hot-wallet path.

## The core problem the code forces us to solve first: split seed from metadata

The seed is **bundled** with metadata in one JSON blob (`StoredWallet` = `seedPhrase` + `language`
+ `version` + `birthday` + `hasUserPassedPhraseBackupTest`). And several hot paths read that blob
for *metadata only*, plus the existence check reads it too:

| Call site | Needs | Today | Post-SE if we naively wrap the blob |
|---|---|---|---|
| `areKeysPresent()` (Splash, RootStore:599, RootInit:88/628) | existence | `exportWallet()` | **prompt at launch** ✗ |
| `SmartBanner:458` | `hasUserPassedPhraseBackupTest` | `exportWallet()` | **prompt during sync** ✗ |
| `ResyncWallet:60` | `birthday` | `exportWallet()` | **prompt** ✗ |
| `updateBirthday`, `markUserPassedPhraseBackupTest` | write metadata | `exportWallet()`+update | **prompt** ✗ |
| `RootInit:460` `resolveMetadataEncryptionKeys` | seed → derive meta keys | `exportWallet()` | prompt at launch (once) ✗ |
| `RootInit:495` `checkBackupPhraseValidation` ([#1024] guard) | seed-relevance | `exportWallet()` | **prompt EVERY launch** ✗ |

So naive "encrypt the blob" would fire a biometric on existence checks, banner checks, birthday
reads, and every launch. The fix (which the audit's gap #3 also calls for) is to **store the seed
separately from metadata**:

- **`zcashStoredWalletSeed`** — ECIES ciphertext of `{ seedPhrase, language }`. SE-wrapped. Reading
  it triggers the OS auth prompt. *(macOS)*
- **`zcashStoredWalletMeta`** — plaintext `{ version, birthday, hasUserPassedPhraseBackupTest,
  seedFingerprint }`. No prompt, freely read/written.

On iOS the storage is unchanged for v1 (single blob); the audit's iOS recommendation (`.userPresence`
on the existing item) is a separate later track.

## Prompt map (where the biometric actually fires)

After the split, the `.userPresence` prompt fires **only on genuine seed reads** — all of which are
spend- or export-class, where an auth-to-act prompt is correct (and several already call
`localAuthentication` first):

- view recovery phrase (`RecoveryPhraseDisplay`), send (`SendConfirmation`), pay/swap
  (`SwapAndPay`), Flexa send (`RootDestination:123`), shield (`ShieldingProcessor:69` — confirm it's
  user-initiated, not auto), vote tx (`Voting` ×2), and the restore-time relevance guard
  (`resolveRestore`, already has the seed in hand).

Promptless after the split:

- `areKeysPresent()` → presence check on the ciphertext item (`copyMatching`, no `kSecReturnData`,
  no decrypt).
- `SmartBanner`, `ResyncWallet`, `updateBirthday`, `markUserPassedPhraseBackupTest` → new
  `exportWalletMetadata()` (reads `zcashStoredWalletMeta` only).
- `resolveMetadataEncryptionKeys` (RootInit:460) → derive metadata keys **eagerly at import**
  (seed already in memory) and during migration (seed already decrypted), so the lazy launch path
  never re-reads the seed.
- `checkBackupPhraseValidation` (RootInit:495) → compare a **seed fingerprint** stored in plaintext
  meta against the DB's account fingerprint — no decrypt. (Fallback if the SDK exposes no
  fingerprint: defer the defensive backstop to the first genuine seed read.)

## Critical finding: the launch prompt (and why it's avoidable)

`RootInitialization.initializeSDK` passes the seed to `sdkSynchronizer.prepareWith(...)` on **every
launch**, and `resolveMetadataEncryptionKeys` + `checkBackupPhraseValidation` also read the seed at
launch. Naively SE-wrapping the seed would therefore fire **multiple biometric prompts on every app
launch** — unacceptable.

**Resolution:** the SDK's `Synchronizer.prepare(with seed: [UInt8]?, …)` takes an **optional** seed.
Once the wallet's accounts exist in `data.db`, `prepare(with: nil)` works — no seed needed. So:

- The seed is decrypted at launch **only on the first init** (when `data.db` is absent — i.e. right
  after wallet create/restore, when the user just supplied it). That single decrypt is reused for
  `prepare` + address-book/metadata key derivation (consolidate — do NOT call `exportWallet` three
  times = three prompts).
- **Every subsequent launch** prepares with `nil` → zero seed reads → **zero prompts**. The biometric
  then appears only on genuine spend / export.
- `checkBackupPhraseValidation` (the [#1024] launch guard) is **intentionally not run on macOS**. It
  would have to read+decrypt the keychain seed every launch (a biometric), and the restore-time
  preventive guard (`resolveRestore`, which uses the freshly-typed seed — no decrypt) already prevents
  the desync at its source. A per-launch re-check buys nothing there but a prompt. iOS keeps it. (We
  deliberately do NOT add an SDK `seedFingerprint(from:)` FFI primitive: it's non-secret but it's API
  surface against the SDK's account-centric design, for a check we don't need.)

Work this adds to step 2's launch wiring: make the app's `prepareWith` accept `[UInt8]?`; branch
`initializeSDK` on `databaseFiles.areDbFilesPresentFor(...)` (present → `prepare(nil)`, absent →
decrypt once + reuse); leave the launch desync-guard iOS-only (the restore-time preventive guard is
the macOS defense).

## Architecture

**New `SecureEnclaveClient` dependency** (sits alongside `SecItemClient`; mockable for iOS/CI/tests):

```
isAvailable: () -> Bool                       // SecureEnclave.isAvailable
encryptSeed: (Data) throws -> Data            // get-or-create SE key, ECIES encrypt with PUBLIC key (no prompt)
decryptSeed: (Data, _ reason: String) throws -> Data  // SE private key, fresh LAContext → PROMPT
deleteKey:  () throws -> Void                 // SecItemDelete the SE key by tag
```

- SE key: P-256, `kSecAttrTokenIDSecureEnclave`, `kSecAttrIsPermanent`, tag `com.zodl.seedWrappingKey`,
  access control `SecAccessControlCreateWithFlags(nil, …WhenUnlockedThisDeviceOnly,
  [.privateKeyUsage, .userPresence])`.
- ECIES: `kSecKeyAlgorithmECIESEncryptionCofactorVariableIVX963SHA256AESGCM` (ephemeral ECDH + X9.63
  KDF + AES-GCM; handles the small seed payload directly). **Encrypt uses the public key → no
  prompt; only decrypt touches the enclave → prompt.** So all *writes* are free; only seed *reads* cost a prompt.
- `.userPresence` (not `.biometryCurrentSet`): survives Touch ID re-enrolment and **falls back to the
  login password** — essential on Touch-ID-less Macs.

**`WalletStorage`** gains an optional `secureEnclave: SecureEnclaveClient?`. When set (macOS live),
the seed store/load routes through SE + the split; when nil (iOS, tests), today's plaintext path is
unchanged. `WalletStorageClient.live(walletStorage:)` wires the macOS variant; `SecItemClient`
stays as-is.

## Migration (transparent, crash-safe)

Version marker: `zcashStorageVersion` (plain, unprotected `kSecClassGenericPassword`, single Int) —
auth-free so detection never needs a decrypt. On first Beta2 launch, after the app-level gate:

1. Read `zcashStorageVersion`; if ≥ 2, done.
2. Read the old plaintext `zcashStoredWallet` (no auth today). Absent → fresh install, write v2
   directly, mark version, done.
3. Split → write `zcashStoredWalletMeta` (plaintext) and `zcashStoredWalletSeed` (SE ciphertext).
   Does **not** delete the old item yet.
4. **Verify**: decrypt `zcashStoredWalletSeed` — this fires the one migration biometric. If the user
   cancels or it fails, delete the half-written v2 items, keep the old item, retry next launch.
5. Verified → delete old `zcashStoredWallet`, write `zcashStorageVersion = 2`.

Crash between any steps is safe (old item survives until a confirmed, readable replacement exists).
This **supersedes the force-reset plan** — existing macOS testers upgrade invisibly (one prompt);
reset is only the fallback when SE is unavailable or migration fails.

## Hard requirements (from the audit)

- **SE availability gate**: check `SecureEnclave.isAvailable` at wallet creation / migration. If false,
  **hard error — no software fallback** (`WalletStorageError.secureEnclaveUnavailable` from
  `storeWalletSecurely`). This case is **reachable** (see deployment floor below), so we surface a clear
  info screen rather than a raw error — see "Macs without a Secure Enclave" below.
- **`resetZashi()`** must also `deleteKey()` (the SE key) and delete `zcashStoredWalletSeed`,
  `zcashStoredWalletMeta`, and reset `zcashStorageVersion` — not just the old blob. **Done** (verified the
  full Settings → DeleteWallet → `resetZashi()` path; no blanket wipe bypasses it).
- **Signing/entitlements**: SE + biometric needs a code-signed, entitled app. Works in the real macOS
  build; verify in the local dev/debug configuration (the `SecureEnclaveClient` mock covers tests/CI).
- **Deployment floor is `MACOSX_DEPLOYMENT_TARGET = 14.6` (Sonoma), NOT "macOS 26"** (an earlier draft of
  this doc was wrong). The framework's macOS slice is `macos-arm64_x86_64` (universal), so the app runs on
  Intel. Therefore **pre-T2 Intel Macs (no Secure Enclave) are reachable** and the no-SE path is not
  hypothetical. FileVault assumed, not relied upon.

## Scope

- **v1: the seed.** Crown jewel.
- **Voting hotkey — deliberately deferred** (`zcashStoredVotingHotkey_*` — also a seed; same mechanism
  would apply). **Decision (Lukas):** not worth redoing now — a leaked voting hotkey grants *vote* power
  only, never the ability to spend funds. Left as a plaintext keychain item; revisit if/when it matters.
- **Low / not now:** address-book & user-metadata encryption keys are re-derivable from the seed and
  carry their own separate FIXMEs the audit flagged (key-collision, keys-held-in-memory, no
  seed-fingerprint, multi-seed) — track independently.

## Verified behavior & architecture (implemented — read this before changing anything)

These are the load-bearing findings from building + on-device testing the SE path. Several correct
intuitions that look wrong at first glance.

### Why "ciphertext seed + a key in the keychain" is NOT equivalent to a plaintext seed

The recurring worry: *if we don't trust the keychain with the plaintext seed, why trust it with the
ciphertext plus the key that decrypts it?* Because **the decryption key is never stored in any usable
form.** The wrapping key is generated with `kSecAttrTokenIDSecureEnclave`: the private key is created
**inside the Secure Enclave (SEP)** and **never leaves it**. The keychain holds only a token/handle that
*only that same SEP* can use; `SecKeyCopyExternalRepresentation` on the private key fails by design. So
for a root + SIP-bypass attacker:

| | Plaintext seed | SE-wrapped seed |
|---|---|---|
| Dump keychain / securityd memory | **gets the seed → done** | gets ciphertext + a useless handle |
| Decrypt it | — | must ask *that* SEP, which enforces `.userPresence` (live biometric / login pw) per call |
| Move the loot to another machine | works anywhere | handle is dead — no key material in it |
| Offline brute-force | n/a | impossible — no off-enclave key exists |

The seed is plaintext only **transiently in process memory** during an authenticated spend (Rust needs the
bytes) — never persisted. That is categorically stronger than plaintext-at-rest readable login→logout.

### App-level auth and SE auth are complementary, not redundant — keep both

- **SE `.userPresence`** gates *seed decryption* (spend, export phrase).
- **App-level `localAuthentication.authenticate()`** gates *app entry and viewing* — app-lock at launch
  (`SplashView`, `appLaunchBiometric && walletExists`), settings, etc.

A normal launch runs `prepare(nil)` → **no seed decrypt** → SE never fires at launch. The app-lock is what
protects balances / history / addresses (none of which touch the seed). Dropping it "because SE exists"
would open the whole viewing surface with zero auth. So **do not** try to replace the app-level auths with
SE — on either platform.

### The send double-prompt and the auth reuse window

A spend hits **two** biometrics: the app gate (`localAuthentication.authenticate()`, fresh `LAContext`,
reuse=0 → *always* prompts) then the SE seed decrypt. Pre-SE the second was a free plaintext read (1
prompt); SE made it a real prompt (2). Fix: a short **auth reuse window** on the SE context
(`SecureEnclaveLiveKey.seedAuthReuseDuration = 10s`, a shared `LAContext` with
`touchIDAuthenticationAllowableReuseDuration`) lets the SE decrypt ride on the gate's just-passed auth →
back to 1 prompt. **Not a security downgrade:** every distinct spend still hits its own always-prompt app
gate; the window only suppresses the *redundant* second prompt within one action. (The only seed-decrypt
path NOT app-gated is shielding — now a 1-prompt presence check where it used to be silent; benign, it
moves the user's own funds to their own shielded pool.)

### Prompt counts (steady state)

- **Normal launch:** 1 (app-lock only; `prepare(nil)`, zero seed decrypts).
- **Spend (send/swap/vote/Flexa/view-phrase):** 1 (app gate; SE decrypt rides the reuse window).
- **First launch after the plaintext→SE migration:** 1 — the migration verify-decrypt. The app-lock is
  *skipped* that once because `areKeysPresent()` checks the SE item, which doesn't exist until migration
  writes it (splash evaluates before migration runs). Steady state thereafter is the launch row above.

### Reset wipes everything (verified path)

`resetZashi()` deletes `zcashStorageVersion`, `zcashStoredWalletSeed`, `zcashStoredWalletMeta`, the legacy
`zcashStoredWallet`, **and** calls `secureEnclave.deleteKey()`. So the ciphertext is doubly-dead: item
deleted *and* the only key that could decrypt it destroyed. Path: Settings → DeleteWallet →
`RootInitialization` `resetZashi` → `walletStorage.resetZashi()`; no blanket `SecItemDelete` bypasses it.

### Per-device keys — no cross-device sync of the wrapped seed

Each device's SEP generates its **own** non-extractable key, so seed ciphertext encrypted on the Mac can
**only** be decrypted by that Mac. SE keys are inherently non-syncable (they can't leave the enclave), and
our items are `WhenUnlockedThisDeviceOnly` anyway — so **iCloud Keychain cannot enable cross-device
decryption**; only the generating device can decrypt. This is by design: the portable secret is the
**mnemonic** (restore on each device → each re-encrypts to its own enclave), never a synced ciphertext.
iOS does not SE-wrap yet, so there is no SE-based iPhone↔Mac interop regardless.

### Macs without a Secure Enclave (the no-fallback edge)

`storeWalletSecurely` hard-errors `secureEnclaveUnavailable` when `SecureEnclave.isAvailable()` is false —
**no plaintext fallback** (by design). Because the deployment floor is 14.6 + a universal framework, this
is reachable on **pre-T2 Intel Macs**. Handling: `WalletStorage.isSecureStorageAvailable()`
(`secureEnclave?.isAvailable() ?? true`, so iOS / SE-Macs are always `true`) is checked first in
`RootInitialization.initialSetups`; if false it routes to the `OSStatusError` screen with
`secureEnclaveUnavailable = true`, which shows a dedicated "This Mac isn't supported" info message (no
keychain code, no Contact Support) via the `osStatusError.secureEnclave*` strings. **Decision (Lukas):
safe to launch as-is** (no Mac users yet; the gate is the friendly fallback).

## Resolved open items (were "to confirm during build")

1. **Seed fingerprint launch guard — dropped** (no SDK FFI added). The restore-time preventive guard
   already prevents desync; the macOS launch desync-check is intentionally not run (would prompt every
   launch). iOS keeps its (promptless) check.
2. **`ShieldingProcessor` — confirmed user-initiated** (only `shieldFundsTapped` from SmartBanner /
   Balances; never auto/background).
3. **SE + `.userPresence`** — verified working on a signed macOS run (create/restore, spend, migration).
4. **Eager metadata-key derivation** — `resolveMetadataEncryptionKeys` decrypts only when an account is
   missing keys (cached otherwise); fires on account-switch / import / first-init, not on normal launch or
   send.

## Files

`WalletStorage.swift`, `WalletStorageInterface.swift` (add `exportWalletMetadata`,
`migrateToSecureEnclave`), `WalletStorageLiveKey.swift` (macOS divergence), new
`SecureEnclave/SecureEnclaveClient*.swift`, `StoredWallet.swift` (split into seed + meta, add
`seedFingerprint`), `RootInitialization.swift` (:460 eager derive, :495 fingerprint compare, migration
trigger), `SmartBannerStore.swift` / `ResyncWalletStore.swift` (use metadata accessor), `Root/`
(migration action). iOS paths untouched.

## Data Protection keychain relocation (MOB-1485)

The items this document describes originally lived in the **file-based login keychain**, whose
per-item ACLs are bound to the creating app's code signature — so a differently-signed build
(Xcode dev vs Developer ID DMG vs TestFlight) threw a password-only "wants to use your
confidential information" dialog per item at launch. Since MOB-1485, the macOS live storage sets
`WalletStorage.useDataProtectionKeychain`, which adds `kSecUseDataProtectionKeychain` to every
keychain query: items live in the iOS-style Data Protection keychain, authorized silently from
the code signature (Team ID + bundle ID, default access group — `kSecAttrAccessGroup` is
deliberately never set, keeping internal/testnet isolated). The SE wrapping key needed no change:
token-backed keys always lived in the DP domain (which is why it never password-prompted).

Mechanics (`WalletStorage+KeychainRelocation.swift`):

- **THE platform rule (learned from a wallet-destroying regression, verified via `secd`'s log on
  a real Mac):** on macOS, SecItem calls **without** `kSecUseDataProtectionKeychain` are *not*
  scoped to the file keychain — `SecItemCopyMatching` sees, and `SecItemDelete` deletes, Data
  Protection items too. The first cut of this engine scanned and deleted unscoped: every launch
  re-discovered the app's own DP items as "legacy leftovers" and the delete-the-original step
  destroyed the freshly relocated DP copy — the wallet vanished on every relaunch. All
  file-keychain operations therefore go through the `SecItemClient.fileKeychain*` primitives,
  which scope by `SecKeychainItemRef`: only file items are backed by one (the macOS 26 SDK
  removed `SecKeychainCopySearchList`/`SecKeychainCopyDefault`, so `kSecMatchSearchList` scoping
  is no longer constructible), making the ref both the file/DP discriminator for the scan and the
  precision handle for the per-item read (`kSecMatchItemList`) and delete
  (`SecKeychainItemDelete`).
- **Lazy once-per-process gate:** every public accessor calls it first, so any first keychain
  touch (including Splash's `areKeysPresent`) relocates before reading. Trigger is "the file
  keychain still contains our items" (ref-discriminated, so DP items can never re-trigger it) —
  self-healing, no storage-version bump (`zcashStorageVersion` keeps meaning the SE-split format,
  and the v2 migration composes on top: a v1 plaintext blob relocates as-is, then splits inside
  the DP keychain).
- **Crash-safe per item:** read file bytes by ref (the one step an ACL can still gate —
  cross-signature installs see one final prompt round) → write into DP (file bytes win over a
  crashed run's duplicate) → read back and verify → only then delete the file original, by its
  `SecKeychainItemRef`, never by a service-name query.
- **Failure is sticky and loud:** any failure (including a denied prompt, `errSecAuthFailed`)
  makes every throwing accessor throw `KeychainError.unknown(status)`, which
  `walletInitializationState` routes to the OSStatusError screen. A denied relocation can never
  read as "no wallet" — nobody gets sent to onboarding over a still-recoverable wallet.
  Relaunching retries. Dev note: `errSecMissingEntitlement` (−34018) on the DP write means an
  improperly signed/provisioned build.
- **`resetZashi` is the escape hatch:** deliberately ungated (deletes are never ACL-gated), it
  additionally sweeps ZODL leftovers out of the file keychain, and it clears the sticky gate so
  the next access re-derives from reality (without that, Root's post-reset verification read
  would rethrow the stale failure and mis-report a successful wipe). The macOS OSStatusError
  screen exposes it as a confirmed "Reset Zodl" action (`OSStatusError.Action.startOverTapped` →
  Root's `wipeRequest` alert → the standard reset flow), so the hatch is reachable from exactly
  the failed-relocation state it exists for.

Ship notes: once relocated, older (file-keychain era) builds cannot see the wallet — downgrading
means restoring from the mnemonic. `ThisDeviceOnly` is now genuinely enforced (no Migration
Assistant / Time Machine carry-over; the mnemonic is the portable secret). Keychain Access and
the `security` CLI no longer see the items — the `security delete-generic-password` rescue trick
above only applies to pre-relocation installs.
