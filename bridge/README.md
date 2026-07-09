# Zodl Bridge

Browser → native Zodl payments. **The extension is a communicator, never a custodian:**
no keys, no wallet data, no spend path in the browser; strictly one-way; every hop
identity-pinned. Spec: `docs/macos/ZODL_BRIDGE_SPEC.md` (v2 + BR-7) · plan:
`docs/macos/ZODL_BRIDGE_PLAN.md`.

```
page click ─▶ extension (content.js → background.js)     [browser process isolation]
        ─▶ zodl-bridge-host (native messaging, argv-pinned caller)   [allowed_origins]
        ─▶ UDS ~/Library/Group Containers/RLPRR8CPQG.zodl.bridge/bridge.sock   [App Group + same-uid peer check]
        ─▶ Zodl review interstitial → SendConfirmation → Touch ID    [Phase B]
```

## Layout
- `extension/` — MV3, vanilla JS. Content script = a click listener for
  `a[href^="zcash:"]`, zero DOM mutation. Background = throttle + native message with
  **browser-attested origin** (`sender.origin`, never page-supplied). Popup = manual
  paste box (origin labeled `popup:`).
- `host/` — SPM package: `BridgeCore` (framing, schema, allowlist, UDS, waker,
  pipeline — 20 unit tests) + `zodl-bridge-host` (one-shot helper) + `mock-zodl`
  (Phase-A stand-in listener).
- `demo/` — fixture shop (`./serve.sh` → http://localhost:8873): Tier-2 link, Tier-1
  pointer sample, junk scheme, oversized URI, drive-by case, iframe case.

## Verify headless (no browser, no Zodl)
```
host/e2e.sh
```
Proves: framed message → helper → UDS → mock listener → ack `received`; foreign
extension ID refused (`caller-not-allowed`) before its input is even read.

## Browser-in-the-loop (ordered; two terminals + one browser)

**Step 1 — install the helper** (Terminal 1):
```
cd bridge/host && ./install-dev.sh
```
Expect: `building helper (release)…` (first build takes a moment) → `installed: …/Zodl/bridge/zodl-bridge-host` → one `manifest → …` line per Chromium browser found.

**Step 2 — start the mock Zodl** (same terminal, leave running — it is the proof surface):
```
swift run mock-zodl
```
Expect: `mock-zodl listening on ~/Library/Group Containers/RLPRR8CPQG.zodl.bridge/bridge.sock`.

**Step 3 — serve the demo shop** (Terminal 2, leave running):
```
bridge/demo/serve.sh
```

**Step 4 — load the extension** (Brave or Chrome): `brave://extensions` →
Developer mode ON → **Load unpacked** → select `bridge/extension/`. Open Details and
verify the ID is exactly `nginegnmdihpegemkajmjjeimigdkjma` — the manifest `key` pins
it; anything else means the host manifests won't match and the browser will refuse the
native connection.

**Step 5 — happy path:** open http://localhost:8873 → click **Pay 0.001 ZEC** (row 1).
Expect: the page does NOT navigate; Terminal 1 prints the `REQUEST:` JSON
(`amount=0.001`, `origin: http://localhost:8873`, `requestSrc: null`); a browser
notification "handed to Zodl" (banners can be muted by Focus — the terminal line is
the truth).

**Step 6 — Tier-1 pointer:** wait 5 s (per-origin cooldown), click **Pay 0.002 ZEC
(verified)** (row 2). Same as step 5 but the printed JSON carries
`requestSrc: "http://localhost:8873/invoice.txt"` (absolutized by the content script;
Zodl fetches + origin-compares it in Phase B4).

**Step 7 — negative rows:** row 3 (BTC link — a literal `bitcoin:` link, the
junk-scheme filter test): NO bridge activity (any external-app dialog is the
browser's own). Row 4 (oversized): notification `invalid:uriTooLong`, nothing in the
terminal. Row 5 (drive-by button): zero bridge activity — any dialog is the OS
roulette Zodl refuses to join (Invariant 2). Row 6 (iframe): like step 5.

**Step 8 — popup manual path:** pin + click the toolbar icon, paste a `zcash:` URI
(right-click a Pay button → Copy Link Address), **Send to Zodl** → terminal prints
`origin: "popup:"`.

**Step 9 — failure mode (optional):** Ctrl-C mock-zodl, click Pay → notification
`zodl-unreachable` (no wake target configured yet; Phase B adds `--bundle-id`).

**Step 10 — cleanup (optional; leave installed if Phase B is next):** Ctrl-C both
terminals; `host/install-dev.sh --uninstall`; remove the unpacked extension.

## Live fire with REAL Zodl (Phase B built — replaces mock-zodl)
Phase B is in the app: UDS listener (starts at launch, macOS only) → Root intake
gates (home-only, one-in-flight, 5 s cooldown, Zodl-account-only) → BR-7 Tier-1
native verification → review card (`.zashiSheet`, engine-Proposal-rendered,
default-Cancel) → the shipped send path (SE-decrypt biometric → derive → submit).

1. `host/install-dev.sh --bundle-id co.electriccoin.secant-testnet`
   (the mac app's ground-truth CFBundleIdentifier — legacy-inherited name; enables
   wake-on-request when Zodl isn't running).
2. Run Zodl macOS (zodlmac-internal) with a ready wallet, land on Home.
3. Load the extension + serve the demo (steps 3–4 of the checklist above), but do
   NOT run mock-zodl — the app owns the socket now (whichever binds last steals it).
   Dual-install note (TestFlight + Xcode builds share the bundle id): wake-from-quit
   would open the bridge-less TestFlight copy — add
   `--app-path <DerivedData>/Build/Products/Debug/Zodl.app` to install-dev.sh so the
   helper wakes the dev build by path (unambiguous) until a TestFlight build ships
   the bridge.
4. **Self-pay setup (demo section 0):** paste your OWN address (Zodl → Receive)
   into the demo's address box — the default link addresses are placeholders that
   real Zodl's parser refuses (you'd see the refusal card, working as designed).
   With your address in, click **Pay 0.001 ZEC** → Zodl front → review card
   (origin + tier label) → Cancel to test the safe path, or **Pay** for the full
   E2E: it's a self-send, the money returns to you minus the fee.
5. Tier-1 row ("verified"): works fully once the request source is same-domain
   https (the localhost demo exercises the plumbing; CipherPay invoices are the
   real thing: `data-zodl-request-src` → their public invoice JSON).

## Status
Phase A complete + headless E2E PASS. Phase B (task #171) BUILT: listener,
intake gates, review card (en+es via `Bridge.xcstrings`), Tier-1 verifier
(https-only, all-redirects-blocked, ≤4 KB, domain rule) — both schemes green.
Unit tests for the domain rule + URI extraction live in `zodlTests/BridgeTests/`
(pending first run: the shared sim-test lane has a pre-existing SwiftProtobuf
link failure unrelated to the bridge; macOS scheme has no test action).
Live-fire VERIFIED (2026-07-09): Chrome/Brave chain + real Pay ceremony + wake-from-quit
+ **Safari via the safari-dev wrapper** (converter harness in `safari-dev/`; App Group
entitlement must be WIRED via CODE_SIGN_ENTITLEMENTS on both targets — an orphan
entitlements file signs sandbox-only and the handler's socket connect is denied).
Safari-dev validates the exact handler→App-Group→Zodl pattern the production
in-Zodl Safari-family target (macOS+iOS) will use.
Remaining: [needs-user] CipherPay mainnet E2E (throwaway UFVK) · Safari-family
production target inside Zodl (post-WIP) · TestFlight build with the bridge.
