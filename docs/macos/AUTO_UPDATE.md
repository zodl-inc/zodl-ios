# Zodl macOS — auto-update

_Last updated 2026-09-01. Applies to the `zodlmac-internal` target on `macos-revival`._

Zodl for macOS updates itself without Sparkle and without the App Store: the app checks a
GitHub Releases feed, downloads the new build, verifies it through six independent layers,
swaps itself atomically in `/Applications`, and relaunches. Everything lives in
`zodlmac-shared/Updater.swift`; the app entry point (`zodlmac_internalApp.swift`) triggers a
check 3 seconds after launch and on every foreground resume.

Origin: developed and E2E-verified in [`zodl-inc/poc-macos-dmg`](https://github.com/zodl-inc/poc-macos-dmg)
(run 33478044689: a released 1.0.0 build self-updates to 1.0.1 in CI), then ported here.

## Configuration — everything comes from CI

There are **no hardcoded values** — trust anchors included (a conscious tradeoff, see the
note at the end of this section). The updater reads `UpdaterConfig.plist` from the app
bundle; a default plist with the current production values is checked in for local dev
builds, and the release workflow **regenerates it at build time** from GitHub repo
variables. If the plist is missing or incomplete the updater logs and refuses to update
(fail-closed).

### Parameter reference

| Name | Type | Controls | Default / example |
|---|---|---|---|
| `UPDATE_FEED_REPO` | GitHub repo variable | `owner/repo` of the GitHub Releases feed the updater polls | `zodl-inc/poc-macos-dmg-test` |
| `UPDATE_TEAM_ID` | GitHub repo variable | codesign `TeamIdentifier` the downloaded app must carry | `RLPRR8CPQG` |
| `UPDATE_ED25519_PUBKEY` | GitHub repo variable | base64 DER Ed25519 public key that verifies release checksums | `MCowBQYDK2VwAyEA…` |
| `UPDATE_SPKI_PINS` | GitHub repo variable | comma/newline-separated SPKI SHA-256 pins for all updater hosts | see checked-in plist |
| `APPLE_CERT_SECRET_ID` | GitHub repo variable | AWS SM secret id holding the Developer ID cert + notarization creds | `/infra/apple/developer-id-macos` |
| `UPDATE_SIGNING_KEY_SECRET_ID` | GitHub repo variable | AWS SM secret id holding the Ed25519 private signing key | `/infra/apple/update-signing-key` |
| `AWS_REGION` | GitHub repo variable | region for the SM lookups | `us-east-1` |
| `E2E_BASELINE_VERSION` | GitHub repo variable | version the E2E installs first | `1.0.0` |
| `E2E_TARGET_VERSION` | GitHub repo variable | version the E2E expects the app to self-update to | `1.0.1` |
| `GHA_ROLE_ARN` | GitHub secret | IAM role the workflow assumes via OIDC to read AWS SM | `arn:aws:iam::…:role/…` |
| `SLIPSTREAM_PAT` | GitHub secret | token for the private `slipstream-internal` Rust crate during the FFI build | — |
| `/infra/apple/developer-id-macos` | AWS SM secret | Developer ID `.p12` + password, Apple ID, notarytool password, `team_id` | JSON, keys: `p12_base64`, `p12_password`, `apple_id`, `notarytool_password`, `team_id` |
| `/infra/apple/update-signing-key` | AWS SM secret | Ed25519 private key (PEM, b64) that signs release checksums | JSON, key: `private_key_pem_b64` |
| `baseline_version` / `target_version` / `feed_repo` | `workflow_dispatch` inputs (E2E) | per-run overrides; fall back to the repo variables above | empty → vars → checked-in defaults |

**Where secrets live:** the signing materials are **never stored in the repo or in
GitHub**. The release job assumes an IAM role via OIDC
(`aws-actions/configure-aws-credentials`) and calls `secretsmanager get-secret-value` at
workflow runtime for the Developer ID certificate/notarization credentials and the Ed25519
private key; nothing persists in the repo or in the workflow definition. The only
GitHub-side secrets are `GHA_ROLE_ARN` (a role ARN, not a credential) and `SLIPSTREAM_PAT`.
GitHub **repo variables** (`gh variable set`) carry only public, non-secret parameters:
feed repo, team ID, the Ed25519 *public* key, SPKI pins, SM secret *ids*, region.

**Rotating pins or keys** no longer requires a code release: edit the repo variable
(`gh variable set UPDATE_SPKI_PINS --body "…"`) and the next build bakes it in. The
checked-in `UpdaterConfig.plist` should be kept roughly in sync so local dev builds keep
working.

> **Tradeoff note:** whoever controls the GitHub repo variables controls the updater's
> root of trust (feed, pubkey, pins, team ID) for the *next* build. This is a deliberate
> team decision — we trust GitHub CI; protect variable/settings access accordingly.

## Architecture

```
GitHub Releases (feed repo: UpdateFeedRepo → currently zodl-inc/poc-macos-dmg-test)
  │  releases/latest → tag mac-vX.Y.Z with assets:
  │    Zodl-X.Y.Z.zip           ← notarized .app, the auto-update artifact
  │    Zodl-X.Y.Z.dmg           ← human install (drag to /Applications)
  │    *.sha256, *.sha256.sig.b64  ← checksum + Ed25519 signature
  ▼
Updater.checkAndUpdate()
  1. GET releases/latest (pinned TLS session) → compare tag vs CFBundleShortVersionString
  2. Alert with release notes → user clicks "Install & Relaunch"
  3. Download zip (+ .sha256 + .sha256.sig.b64) over the same pinned session
  4. Verify (see security model) → extract with ditto into a staging dir
  5. Atomic swap: /Applications/Zodl.app → .old, staged → /Applications; rollback on failure
  6. External helper (double-forked, survives app exit) relaunches the new copy
```

The zip path is deliberate: the earlier DMG-mount install path (`hdiutil attach`) is kept
only as a legacy fallback. Mounting requires disk-arbitration rights that broke repeatedly
in CI and under sandboxing; `ditto` extraction into the app's own container does not.

## Security model — six layers

| # | Layer | Defeats |
|---|---|---|
| 1 | **SPKI pinning + OCSP fallback.** The TLS session pins SPKI SHA-256 hashes of every host the updater touches: `api.github.com` (feed), `github.com` (asset URL first hop), `release-assets.githubusercontent.com`/`objects.githubusercontent.com` (asset CDN — Let's Encrypt chain, pinned since 2026-09-01). On pin mismatch, OCSP distinguishes legitimate rotation from interception; pins should then be refreshed. | MITM with a CA-issued cert (corporate proxy, compromised CA) |
| 2 | **Ed25519 signature over the checksum file.** Public key embedded in the app; private key exists only in AWS Secrets Manager (`/infra/apple/update-signing-key`), used by CI at release time via `Scripts/sign-checksum.py`. | Compromised GitHub account/repo publishing a rogue release — attacker cannot sign it |
| 3 | **SHA-256 of the downloaded artifact** must match the signed checksum file. | Corrupted/substituted download, CDN tampering |
| 4 | **`codesign` verification** of the staged app: valid signature and `TeamIdentifier=RLPRR8CPQG`. | Artifact signed by anyone other than ZODL |
| 5 | **Bundle version == release tag.** The staged app's `CFBundleShortVersionString` must equal the tag it claims to be. | Downgrade/replay: re-serving an old (vulnerable) signed build under a newer tag |
| 6 | **Apple notarization** (ticket stapled at build time; Gatekeeper checks on first run). | Known-malware payloads; revocable post-release |

No single compromised system is sufficient: a rogue release needs GitHub *and* the AWS
signing key *and* an Apple Developer ID certificate for team RLPRR8CPQG.

## The sandbox gotcha (read before touching build settings)

`ENABLE_APP_SANDBOX = NO` for `zodlmac-internal` **Debug** and **Release-Testflight**;
`Release-AppStore` keeps `YES` (App Store requires it — and App Store builds must not
self-update anyway; gate the updater off for that config if it ever ships there).

Why: the sandbox flag lives in the **pbxproj build settings**, not in the
`.entitlements` file — Xcode injects `com.apple.security.app-sandbox` at signing time, so
the entitlements file looks clean while the binary is sandboxed. A sandboxed app cannot
mount DMGs (`hdiutil` → ENXIO), read DiskImageMounter volumes (EPERM), or write to
`/Applications`. This silent injection was the root cause of every auto-update failure in
the PoC. If someone flips it back to `YES` on a Developer ID config, the updater will
download and verify correctly and then fail at install — check
`codesign -d --entitlements - Zodl.app` when debugging, not just the `.entitlements` file.

Developer ID distribution does not require the sandbox. The entitlements additions
(`com.apple.security.network.client`, `com.apple.security.automation.apple-events`) are
kept so the updater keeps working if a sandboxed variant ever needs it.

## Publishing a release

1. Bump nothing by hand — the workflow stamps versions from the tag.
2. `git tag mac-vX.Y.Z && git push origin mac-vX.Y.Z` → `.github/workflows/release-zodlmac.yml`:
   clones `zcash-swift-wallet-sdk` pinned to `785c7618` inside the workspace and symlinks it
   as the `../zcash-swift-wallet-sdk` sibling (this is how CI escapes the local-path SDK
   limitation in `BRANCH_AND_BUILD.md`), builds the FFI universal slice from source,
   archives `zodlmac-internal` (Release-Testflight, Developer ID, manual signing),
   notarizes + staples, produces zip/DMG/checksums, signs checksums with
   `Scripts/sign-checksum.py`, publishes the GitHub release. ~45–50 min.
3. Repo secrets required: `GHA_ROLE_ARN` (OIDC role that can read AWS SM
   `/infra/apple/developer-id-macos` and `/infra/apple/update-signing-key`) and
   `SLIPSTREAM_PAT` (private slipstream crate). Both exist on the PoC repo.
4. The release is published to the repo the workflow runs in. The updater reads the feed
   in `Updater.repoAPI` — if they differ, mirror the four assets to the feed repo (copy
   `gh release create` with the same tag) or change the constant.

## Running the E2E

`.github/workflows/e2e-autoupdate.yml` (`workflow_dispatch`), macOS runner: installs the
released 1.0.0 DMG, launches the app, waits for the update alert, clicks
"Install & Relaunch" via `osascript`, and **hard-asserts** that the relaunched process
reports the new version (`exit 1` otherwise — it previously soft-passed on ⚠️ echoes,
which hid real failures). Updater logs go to the unified log via `NSLog("[Updater] …")`:

```bash
log stream --predicate 'process CONTAINS "Zodl" AND eventMessage CONTAINS "[Updater]"' --style compact
```

## Refreshing the TLS pins

When GitHub rotates certs the updater logs
`⚠️ OCSP: SPKI pin mismatch but cert still valid — allowing (update pinnedSPKIHashes)`.
Regenerate hashes the way `spkiSHA256` computes them — SHA-256 over
`SecKeyCopyExternalRepresentation` (X9.63 uncompressed point for EC keys), **not** the
classic DER-SPKI HPKP hash — for each of `api.github.com`, `github.com`, and
`release-assets.githubusercontent.com`, then update the `UPDATE_SPKI_PINS` repo variable
(keep the previous values for the rotation window) and mirror them into the checked-in
`zodlmac-shared/UpdaterConfig.plist` for dev builds. No code release required — the next
CI build bakes the new pins in.
