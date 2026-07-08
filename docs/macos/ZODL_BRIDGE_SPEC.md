# Zodl Bridge — mini-spec (browser → native Zodl payments, pay-only v1)

**Status:** SPEC — no code until Lukas reviews (one policy decision BR-3 needs his explicit
call). · **Date:** 2026-07-08 · **Repo/branch:** secant-ios-wallet / `slipstream-macos`
(LOCAL commits only — branch is push-embargoed until the team green-light, it carries
`1a10fc48`). · **Origin:** SDK repo
`docs/slipstream/plans/2026-07-08-browser-wallet-spec.md` §13 Q7 (Lukas: "bridge").

## 0. One line + the invariant

A page says "Pay with ZEC" → Zodl macOS comes to front with a canonical confirm → Touch ID
→ paid. **The bridge can REQUEST, never AUTHORIZE:** no spending keys, no viewing keys, no
wallet state ever exist in the browser; spend authority gains no new path — everything
funnels through Zodl's existing proposal → confirm → Touch ID machinery. Pitch: "Apple Pay
for ZEC." (No PCZT needed: creator = signer = Zodl.)

## 1. Recon facts the spec stands on (verified 2026-07-08, read-only sweep)

| # | Fact | Where |
|---|---|---|
| F1 | **No URL scheme registered on any target** (no `CFBundleURLTypes` anywhere); macOS target = `GENERATE_INFOPLIST_FILE = YES` **plus** a checked-in static `zodlmac-internal/Info.plist` → URL types can be added to the static plist, **no pbxproj edit** (verify merge at build) | Info.plists ×5, pbxproj |
| F2 | `onOpenURL` is wired on the shared RootView (both platforms) → `goToDeeplink` | `RootView.swift:317` |
| F3 | **Inherited security gate:** a deeplink that parses as a ZIP-321 payment URI is deliberately REJECTED → `deeplinkWarning` screen ("we ignore it and let users know") | `RootDestination.swift:62–65`, `DeeplinkWarningView.swift` |
| F4 | ZIP-321 parsing exists: `zcash-swift-payment-uri` 1.0.1 via `URIParserClient.checkRP` (used by the QR flow); SDK side additionally exposes `proposefulfillingPaymentURI` (SlipstreamSynchronizer:682) | `URIParser/*`, `ScanChecker.swift:36–49` |
| F5 | **The reuse seam:** `ScanCoordFlowCoordinator` `.getProposal(paymentRequest)` → `sdkSynchronizer.proposeTransfer` → `.proposalResolved` → `path.append(.requestZecConfirmation(SendConfirmation.State))` — injectable without any QR | `ScanCoordFlowCoordinator.swift:198–351` |
| F6 | macOS target: **no App Sandbox, no App Groups** today (iCloud entitlements only; sandbox posture = the pending F-2/F-3 foundations thread) — IPC must be designed sandbox-*ready* | `zodlmac-internal.entitlements` |
| F7 | **No app-extension targets exist** — Safari Web Extension packaging = a new Xcode target = pbxproj surgery | pbxproj target list |

## 2. Decisions

### BR-1 · v1 scope = pay-only (DECIDED — Lukas's thesis)
Zero wallet data crosses into the browser, ever. No balance glance, no activity, no
addresses (v2+ candidates, each its own decision). The extension carries: intercept a
ZIP-321 payment link, forward it, report status back. Nothing else.

### BR-2 · Phasing (recon-corrected)
- **B0 — URL-scheme foundation (Zodl-only, NO extension, ~½–1 session).** Register
  `zcash:` on the macOS target (static Info.plist edit per F1) + the hardened
  external-request flow (BR-3). Result: "Pay with ZEC" works from ANY browser on macOS
  today — a plain `<a href="zcash:...">` link. **This alone is the demo.** One-way (no
  txid back to the page).
- **B1 — Chromium extension + duplex helper (~1–1.5 sessions).** Thin MV3 extension
  (Chrome/Brave/Edge; works in Firefox too — no wasm, no SAB involved) + a small native
  helper registered via native-messaging host manifest. Adds: click-interception with a
  proper in-page "request sent → txid" status, request provenance metadata (origin URL
  shown in Zodl's confirm), and the duplex channel (BR-4). No Xcode target changes.
- **B2 — Safari packaging (post-WIP; ~1 session).** Same extension in-bundle via
  `SFSafariWebExtensionHandler` — requires a new app-extension target (F7) ⇒ **sequenced
  after Lukas's uncommitted pbxproj WIP lands** (hard rule: never touch his WIP).
- **Later:** balance glance (opt-in), iOS Safari extension (the mobile card), store
  distribution.

### BR-3 · THE POLICY DECISION — evolving the inherited ZIP-321 deeplink rejection ⚠ needs Lukas
**Today (F3):** Zashi-inherited code rejects payment-URI deeplinks by design. The honest
rationale: a URL can arrive with weak/no user intent (a page can auto-navigate to
`zcash:` — drive-by wallet-popping), whereas opening the QR scanner is a strong intent
signal. Note the asymmetry is about *intent*, not *data trust* — the QR flow already
accepts attacker-supplied ZIP-321s (a poster QR ≡ a page link) and routes them through
proposal → confirm.

**Proposal: macOS-only evolution — replace "reject with warning" by a hardened review
flow that REBUILDS the intent signal** (iOS keeps today's warning gate, unchanged):
1. Arrival while a request is already pending, or within a cooldown → dropped silently
   (rate limit, drive-by spam defense).
2. Never while locked/onboarding/restoring; app must reach foreground-active first.
3. A **review interstitial** ("Payment request from your browser" + origin when the B1
   channel supplies it) precedes the standard confirm; **default focus = Cancel**; the
   pay path stays the existing SendConfirmation + Touch ID.
4. Everything renders from the engine **Proposal** (F5), never from page-supplied text.
5. New strings en+es (house rule).

Options for the record: (a) the above (RECOMMENDED); (b) keep the gate, allow requests
ONLY via the B1 extension channel (loses the zero-install B0 demo; the extension channel
is not intrinsically higher-intent than a click); (c) change both platforms (bigger
conversation, touches upstream-inherited behavior on iOS — not needed for the bridge).
**B0 cannot ship without this call.**

### BR-4 · Duplex transport (B1): Unix-domain socket, sandbox-ready
Helper (launched by the browser per native-messaging) speaks length-prefixed JSON with the
extension (the protocol the browser dictates) and connects to Zodl on a UDS at an
app-support path chosen so it can move into an App Group container when F-2/F-3 lands.
JSON-lines protocol, versioned:
`{v:1, id, type:"payRequest", uri, origin}` → `{v:1, id, status:"presented"|"declined"|"broadcast", txid?}`.
Zodl listens while running; helper wakes Zodl (`open -b <bundle-id>`) when the socket is
absent, then retries with backoff. Peer checks: same-uid peer credentials on the socket;
schema validation; max sizes; one in-flight request per origin.

### BR-5 · Pinning + threat table (v1)
- Host manifest `allowed_origins` pins OUR extension ID(s) only; helper verifies the
  browser-supplied origin argument and refuses others.
- Threats: compromised page → can only emit a request; user sees canonical proposal +
  origin, declines. Compromised extension → same ceiling (request-only). Malicious other
  extension → not in `allowed_origins`, helper refuses. Local malware → owns the machine
  anyway; still cannot spend without Touch ID (unchanged trust anchor). Request spam →
  BR-3 rate limit + one-in-flight.
- Explicitly REFUSED for v1: injecting "Pay" buttons into arbitrary page content by
  detecting bare addresses (phishing-adjacent surface). v1 handles real ZIP-321 links and
  an explicit extension-popup paste box only.

### BR-6 · Code placement
- Zodl feature (B0): new small `BridgeRequestCoordFlow` (or a direct injection into the
  F5 seam) + review interstitial + Deeplink routing change behind `#if os(macOS)`;
  Info.plist static edit; **no pbxproj**.
- `bridge/extension/` — vanilla MV3 JS (no build system for v1), MIT-licensable
  standalone.
- `bridge/host/` — single small Swift executable (SPM), the native-messaging helper.
- Docs: this file + a threat-model paragraph in `docs/macos/DESIGN_LANGUAGE.md`'s
  security section when B1 ships.

## 3. Flows

**B0:** page link click → macOS routes `zcash:` → Zodl foreground → BR-3 review →
SendConfirmation (proposal-rendered) → Touch ID → broadcast. Page learns nothing (user
watches the merchant's own payment-detected UX, standard crypto-checkout pattern).

**B1:** click → extension background catches navigation to `zcash:`/link → native message
→ helper → UDS → Zodl (same BR-3/confirm path, now with `origin` shown) → status events
stream back (`presented` → `broadcast{txid}` | `declined`) → extension resolves the
page-visible state ("payment sent · txid…"). Timeout → `unknown` (user may still pay
manually; page must not treat timeout as failure).

## 4. Testing & gates
- Fixture: a local demo page (repo `bridge/demo/`) with valid/invalid/oversized ZIP-321
  links + an auto-redirect drive-by case (must be silently dropped per BR-3.1).
- Manual matrix rows: decline path, rate-limit, locked-app arrival, invalid URI, wrong
  origin, helper-without-Zodl (wake), Zodl-quit-mid-request (helper reports `unknown`).
- Unit: URI routing decision table (ZIP-321 vs address vs junk), protocol
  encode/decode, rate limiter.
- Both Zodl schemes build green; en+es strings complete; scenario-matrix style row added
  for the new flow.

## 5. Effort
B0 ≈ ½–1 session · B1 ≈ 1–1.5 sessions · B2 ≈ 1 session (post-WIP). The 1–2 session MVP
promise = B0 (+ B1 if the demo wants txid-back).

## 6. Open questions
1. **BR-3** — the gate evolution: option (a)? (Blocks B0.)
2. B1 extension distribution timing (unpacked dev is fine for demo; store listing later).
3. Naming: "Zodl Bridge" as product name?
4. Does the team memo bundle (D1–D6 + browser-wallet spec) want this spec attached?
   (Recommend yes — same trust-model conversation.)
