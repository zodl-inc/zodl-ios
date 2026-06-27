# macOS keychain hardening — Secure-Enclave-wrapped seed

**Status:** design, approved in principle, NOT yet implemented. Source: *MacOS Keychain Secrets
hardening Analysis* (Codex⇄Claude audit). Branch: `slipstream-macos`. macOS-only first.

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

- **SE availability gate**: check `SecureEnclave.isAvailable` at wallet creation / migration. If false
  (VM, CI, old Intel without SE), **hard error — no software fallback**. Target is Apple Silicon, where
  SE is always present.
- **`resetZashi()`** must also `deleteKey()` (the SE key) and delete `zcashStoredWalletSeed`,
  `zcashStoredWalletMeta`, and reset `zcashStorageVersion` — not just the old blob.
- **Signing/entitlements**: SE + biometric needs a code-signed, entitled app. Works in the real macOS
  build; verify in the local dev/debug configuration (the `SecureEnclaveClient` mock covers tests/CI).
- Deployment floor is already macOS 26 (well above the audit's Sonoma minimum). FileVault assumed, not
  relied upon.

## Scope

- **v1: the seed.** Crown jewel.
- **Fast-follow: voting hotkey** (`zcashStoredVotingHotkey_*` — also a seed; same mechanism; reads at
  `Voting` :1770/2043/2629/2835 become spend-class prompts).
- **Low / not now:** address-book & user-metadata encryption keys are re-derivable from the seed and
  carry their own separate FIXMEs the audit flagged (key-collision, keys-held-in-memory, no
  seed-fingerprint, multi-seed) — track independently.

## Open items to confirm during build

1. SDK exposes a seed fingerprint for the promptless launch guard? (else defer the backstop.)
2. `ShieldingProcessor` is user-initiated, not background/auto (a background shield must not prompt).
3. SE + `.userPresence` behavior in the local dev signing config.
4. Whether to fold the eager metadata-key derivation into `importWallet` cleanly.

## Files

`WalletStorage.swift`, `WalletStorageInterface.swift` (add `exportWalletMetadata`,
`migrateToSecureEnclave`), `WalletStorageLiveKey.swift` (macOS divergence), new
`SecureEnclave/SecureEnclaveClient*.swift`, `StoredWallet.swift` (split into seed + meta, add
`seedFingerprint`), `RootInitialization.swift` (:460 eager derive, :495 fingerprint compare, migration
trigger), `SmartBannerStore.swift` / `ResyncWalletStore.swift` (use metadata accessor), `Root/`
(migration action). iOS paths untouched.
