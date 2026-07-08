# Zodl Bridge

Browser → native Zodl payments. **The extension is a communicator, never a custodian:**
no keys, no wallet data, no spend path in the browser; strictly one-way; every hop
identity-pinned. Spec: `docs/macos/ZODL_BRIDGE_SPEC.md` (v2 + BR-7) · plan:
`docs/macos/ZODL_BRIDGE_PLAN.md`.

```
page click ─▶ extension (content.js → background.js)     [browser process isolation]
        ─▶ zodl-bridge-host (native messaging, argv-pinned caller)   [allowed_origins]
        ─▶ UDS ~/Library/Application Support/Zodl/bridge.sock        [same-uid peer check]
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

## Browser-in-the-loop (≈3 minutes, requires a human)
1. `host/install-dev.sh` — builds + installs the helper and writes host manifests for
   every Chromium browser found (Chrome/Brave/Edge/Chromium). Add
   `--bundle-id <zodl bundle id>` once Phase B lands to enable wake-on-request.
2. Browser → `chrome://extensions` (or `brave://extensions`) → Developer mode →
   **Load unpacked** → `bridge/extension/`. The ID must read
   `nginegnmdihpegemkajmjjeimigdkjma` (pinned by the manifest `key`).
3. Terminal: `swift run --package-path bridge/host mock-zodl` (stand-in for Zodl).
4. Terminal 2: `demo/serve.sh` → open http://localhost:8873.
5. Click **Pay 0.001 ZEC** → notification "handed to Zodl" + the request printed by
   `mock-zodl`.
6. Negative checks: the BTC link does nothing; the oversized link is rejected; the
   drive-by button produces NO bridge activity (the browser may show its own
   external-protocol dialog — that OS roulette is exactly what Zodl refuses to join,
   spec Invariant 2).
7. `host/install-dev.sh --uninstall` when done.

## Status
Phase A complete (this directory). Phase B (Zodl-side listener + review flow +
Tier-1 verification) is task #171 — see the plan.
