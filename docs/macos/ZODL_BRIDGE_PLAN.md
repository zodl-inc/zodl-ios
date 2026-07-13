# Zodl Bridge — B0 implementation plan

> Executes `ZODL_BRIDGE_SPEC.md` (v2 + BR-7). Inline execution, task-by-task, local
> commits only (push embargo). Tasks #170 (Phase A) / #171 (Phase B).
>
> **STATUS 2026-07-09: Phase A COMPLETE (headless E2E PASS) · Phase B BUILT under
> Lukas's autonomous GO** — B1 listener, B2 intake (Flexa-precedent submission,
> MOB-1348 single-payment rule), B3 review card via `.zashiSheet` + `Bridge.xcstrings`
> en+es (separate catalog — deliberately avoids Lukas's dirty `Localizable.xcstrings`;
> merge candidate once his WIP lands), B4 Tier-1 verifier (https-only, ALL redirects
> blocked, ≤4 KB, raw-or-JSON body, subdomain-of-tab domain rule + www-normalization).
> Both schemes BUILD SUCCEEDED. B5 partial: unit tests written
> (`zodlTests/BridgeTests/`) but the shared sim-test lane has a pre-existing
> SwiftProtobuf link failure (bridge-unrelated) and the mac scheme lacks a test
> action — first run lands with the normal test lane. [needs-user]: live-fire
> checklist (bridge/README.md) + CipherPay E2E. Safari (B2-phase) remains post-WIP.

**Goal:** "Pay with ZEC" click in a Chromium browser → pinned chain → Zodl macOS review
interstitial → SendConfirmation → Touch ID → broadcast. One-way; pay-only; fully local.

**Recon that shaped this plan:** `secant/` is a `PBXFileSystemSynchronizedRootGroup` ⇒ new
Swift files need NO pbxproj edits (both targets pick them up; use `#if os(macOS)` gates).
Remaining WIP gate = `Localizable.xcstrings` only (Lukas's dirty file; strings are a
gated micro-task). zodlmac bundle id is not in pbxproj → helper wake target is an
install-script parameter.

## Global constraints
- Spec invariants 1–4 (request-never-authorize · no scheme anywhere · one-way · fully
  local). BR-7 tiers; origin ALWAYS from browser-attested `sender`, never page-supplied.
- No push of `slipstream-macos`. Never touch Lukas's WIP files (pbxproj, zodl-internal
  scheme, Localizable.xcstrings, MacSplitView.swift, WalletConfig.swift).
- New UI strings: en+es via the catalog (gated task B3) — no hardcoded strings.
- Commit per task: `[#1755] bridge: <task> — <what>`.

## Shared constants (mirrored helper ↔ Zodl; single source per codebase)
- Native-messaging host name: `com.zodl.bridge`
- UDS socket: `~/Library/Group Containers/RLPRR8CPQG.zodl.bridge/bridge.sock`
  (**App Group** — live-fire 2026-07-09 found the app IS sandboxed: container home
  overflowed `sun_path` 123>103 AND diverged from the helper's real-home view)
- Protocol: JSON line `{v:1, id, type:"payRequest", uri, origin, requestSrc?}` →
  ack line `{"status":"received"|"rejected", "reason"?}` (local ack only; NO wallet data)
- Caps: native message ≤ 8 KB · uri ≤ 2 KB · requestSrc ≤ 1 KB, https-only

## Phase A — the chain outside Zodl (buildable now; task #170)

### A1 · `bridge/host/` — Swift SPM package (TDD)
Targets: `BridgeCore` (library) + `zodl-bridge-host` (executable) + `mock-zodl`
(executable, dev-only listener) + `BridgeCoreTests`.
- `NativeMessaging.swift` — Chrome stdio framing: 4-byte LE length + JSON; read cap 8 KB;
  EOF/truncation → nil. Tests: round-trip, oversize rejected, truncated rejected.
- `BridgeMessage.swift` — Codable schema + `validate()` decision table (v==1,
  type=="payRequest", `zcash:` prefix, length caps, origin = https URL or `"popup:"`,
  requestSrc optional https). Tests: accept/reject table (≥8 rows).
- `Allowlist.swift` — caller check: argv origin `chrome-extension://<id>/` against
  allowed IDs (from `bridge-config.json` next to the binary; install script writes it).
  Tests: match, mismatch, malformed.
- `UDSClient.swift` — BSD socket connect → write JSON line → read ack line (1 s timeout)
  → close. Tests: against an in-test listener on a temp socket path; timeout path.
- `Wake.swift` — socket absent ⇒ `/usr/bin/open -b <bundleID>` (from config; absent ⇒
  skip+log) then retry ≤10 × 500 ms. Tests: injectable runner, retry counting.
- `main.swift` — glue: argv → read one message → allowlist → validate → UDS (wake if
  needed) → ack to stdout → exit. Piped E2E test: stdin bytes in, ack bytes out, mock UDS.
- Verify: `cd bridge/host && swift test` green. Commit.

### A2 · `bridge/extension/` — MV3, vanilla JS, no build system
- `manifest.json` — MV3; stable dev `key` (generated once, checked in — dev identity
  only); `permissions: ["nativeMessaging"]`; content script `<all_urls>` (click listener
  ONLY, zero DOM mutation — spec BR-5 stance holds); action popup.
- `content.js` — capture-phase click → `a[href^="zcash:"]` via `closest()` →
  `preventDefault` → `runtime.sendMessage({uri, requestSrc: a.dataset.zodlRequestSrc})`.
  Nothing else. No reads beyond the clicked anchor.
- `background.js` — validates `sender`; **origin taken from `sender.origin`/`sender.tab`
  (browser-attested), never from the payload**; per-origin throttle (one in flight + 5 s
  cooldown); `sendNativeMessage("com.zodl.bridge", msg)`; result → badge + notification.
- `popup.html/js` — paste box → same path with origin `"popup:"` (labeled manual).
- Verify: `chrome://extensions` load-unpacked shows no manifest errors ([needs-user] or
  Phase-A E2E checklist). Commit.

### A3 · `bridge/host/install-dev.sh` + ID derivation
- `swift build -c release`; install binary to `~/Library/Application Support/Zodl/bridge/`;
  derive the extension ID from the manifest `key` (python3 hashlib, a–p alphabet); write
  `com.zodl.bridge.json` host manifests (absolute path + `allowed_origins`) for Chrome,
  Brave, Edge, Chromium dirs; write `bridge-config.json` (allowed IDs + optional
  `--bundle-id` for wake). `--uninstall` reverses. Idempotent.
- Firefox = follow-up (different manifest key + gecko id), noted not built.
- Verify: script runs clean twice (idempotence); manifests valid JSON. Commit.

### A4 · `bridge/demo/` — fixture page + serve script
`index.html`: valid mainnet + testnet ZIP-321 links; oversized URI; junk scheme;
iframe-embedded link (origin must report the FRAME origin); **drive-by case**
(`location.href = "zcash:…"` on load — must produce NOTHING: no click, no message);
Tier-1 sample (`data-zodl-request-src="./invoice.txt"` + the invoice file).
`serve.sh` = `python3 -m http.server 8873`. Commit.

### A5 · Headless E2E + docs
- `swift test` (A1) + piped-stdin E2E + **mock chain**: `mock-zodl` listening on the real
  socket path ← `zodl-bridge-host` fed a valid framed message on stdin → mock prints the
  JSON, host acks. Proves helper↔UDS↔listener end-to-end with zero GUI.
- `bridge/README.md`: 3-minute browser-in-the-loop checklist for Lukas (load unpacked →
  run install-dev.sh → serve demo → click → mock-zodl prints the request). Commit.
- **Phase A exit gate:** tests green + mock chain transcript in the README + [needs-user]
  browser checklist ready.

## Phase B — Zodl integration (task #171; code unblocked, strings micro-gated)

- **B1** · `secant/Sources/Dependencies/BridgeServer/` (synced group ⇒ no pbxproj):
  UDS listener (BSD + DispatchSource; unlink-then-bind; `getpeereid` same-uid check;
  JSON-line read with caps; immediate local ack), TCA dependency; started from the
  macOS app path only (`#if os(macOS)`), stopped on terminate. Unit tests in zodlTests.
- **B2** · Routing: listener event → `uriParser.checkRP` → gates (rate limit ≥5 s,
  one-in-flight, never while locked/onboarding/restoring) → route into the F5 seam
  (`getProposal`-equivalent on a small `BridgeRequestCoordFlow`) → `requestZecConfirmation`.
  Decline/timeout paths. Tests: gate decision table.
- **B3** · Review interstitial UI + **strings en+es — GATED [needs-user]: land/stash the
  Localizable.xcstrings WIP first** (2 min). Origin line, Tier badge, default-Cancel.
- **B4** · Tier 1 (BR-7): native fetch of `requestSrc` (https-only, no cross-origin
  redirects, ≤4 KB, text) → parsed via `checkRP` → **enforce fetch-domain == tab-domain**
  → "verified from <domain>" badge; Tier 2 label otherwise. Tests: mismatch, redirect,
  oversize.
- **B5** · Exit gates: both Zodl schemes build; helper wake bundle-id wired (from
  `xcodebuild -showBuildSettings`); spec §5 manual matrix walked; scenario-matrix row
  added; STATE/docs updated.

## Phase C — later (separate decisions)
Safari in-bundle target (post-WIP pbxproj work) · Firefox manifest variant · store
packaging · B1 pay-page (deferred, public-distribution trigger).

## Effort
Phase A ≈ 1 session (this one) · Phase B ≈ 1 session + the strings micro-gate ·
browser-in-loop verification = 3 minutes of Lukas's hands.
