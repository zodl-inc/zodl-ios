# Zodl Bridge — mini-spec v2 (browser → native Zodl payments, pay-only, one-way)

**Status:** SPEC v2 — no code until Lukas reviews. **v2 supersedes v1 (`ff18452f`) after
Lukas's channel-threat challenge: the `zcash:` OS scheme is DROPPED from the design;
the extension native-messaging chain is the only web→Zodl channel; the flow is strictly
one-way.** · **Date:** 2026-07-08 · **Repo/branch:** secant-ios-wallet /
`slipstream-macos` (LOCAL commits only — push embargo, branch carries `1a10fc48`).
· **Origin:** SDK repo `docs/slipstream/plans/2026-07-08-browser-wallet-spec.md` §13 Q7.

## 0. One line + the invariants

A page's "Pay with ZEC" click → our extension → our helper → Zodl macOS foreground with a
canonical confirm → Touch ID → broadcast. Merchant verifies payment on-chain (as it must
regardless). **Invariant 1 — request, never authorize:** no keys, no wallet data, no spend
path in the browser. **Invariant 2 — no squattable channel:** Zodl registers NO custom URL
scheme on ANY platform; every hop of the web→Zodl path is identity-pinned. **Invariant 3 —
one-way:** no txid/status returns to the page (v1 scope; helper-level delivery ack only).
**Invariant 4 — fully local (v1, Lukas 2026-07-08):** the extension chain is the
STANDALONE solution — the entire request path is on-machine (extension → helper → Zodl),
no server, no domain, no web infrastructure, no new observer. The https pay-page is NOT
part of v1 (see B1, deferred).

## 1. Recon facts (verified 2026-07-08; unchanged from v1)

| # | Fact | Where |
|---|---|---|
| F1 | No URL scheme registered on any target today — **v2: stays that way, permanently, by policy** | Info.plists ×5, pbxproj |
| F2 | `onOpenURL` wired on shared RootView → `goToDeeplink` | `RootView.swift:317` |
| F3 | Inherited gate: ZIP-321-parsing deeplinks are rejected → `deeplinkWarning` — **v2: the gate STAYS, both platforms** (it is correct; v1's BR-3 reversal is withdrawn) | `RootDestination.swift:62–65` |
| F4 | ZIP-321 parser: `zcash-swift-payment-uri` 1.0.1 via `URIParserClient.checkRP`; SDK exposes `proposefulfillingPaymentURI` (SlipstreamSynchronizer:682) | `URIParser/*`, `ScanChecker.swift:36–49` |
| F5 | Reuse seam: `ScanCoordFlowCoordinator` `.getProposal(paymentRequest)` → proposal → `.requestZecConfirmation(SendConfirmation.State)` — injectable without QR | `ScanCoordFlowCoordinator.swift:198–351` |
| F6 | ~~macOS: no App Sandbox~~ **CORRECTED 2026-07-09: the SIGNED app carries `com.apple.security.app-sandbox=true`** (build settings inject it; the bare checked-in file misled the recon). Rendezvous = App Group `RLPRR8CPQG.zodl.bridge` (entitlements-file-only; orthogonal to keychain — no `keychain-access-groups` in play — and to iCloud) | signed-app `codesign -d --entitlements`, live-fire task #172 |
| F7 | No app-extension targets — Safari packaging = new target = pbxproj = post-WIP | pbxproj |

## 2. The channel-trust adjudication (v2's reason to exist)

Lukas's challenge, 2026-07-08: *"no one can stop me from creating a same-looking app and
registering zcash: … when I click pay with ZEC, which app is going to be used? … as long
as we can't establish channels between parties in a provenly secure way, we shouldn't
depend on zcash: scheme."* Adjudication:

| Channel | Receiver provable? | Origin known? | Verdict |
|---|---|---|---|
| `zcash:` OS scheme | **NO** — any app can claim it; multiple-handler resolution is undefined (Apple-documented on iOS; LS-arbitrary on macOS); handler can change silently; "Open in…?" shows a spoofable app *name* | no | **DROPPED. Zodl never registers or handles it, any platform** — the same reasoning as iOS's in-Zodl-camera-only policy, now uniform |
| Extension native messaging | **YES** — browser launches only the helper at the absolute path in the host manifest Zodl installs; helper reachable only by our extension ID (`allowed_origins` / `allowed_extensions`, browser-enforced); web pages cannot use native messaging at all | **yes** — extension supplies the true tab origin | **THE channel** (the only web→Zodl path) |
| `https://pay.<our-domain>/…` | yes — TLS authenticates the page; associated-domain binding is Apple-verified (unsquattable) | yes | Optional **entry point** — **DEFERRED per Lukas (extension chain is standalone; keeps v1 fully local)**; revisit at public distribution. (Universal-link app-open is reliable only from Safari/system opens on macOS — bonus, not mechanism) |
| QR → Zodl iOS in-app camera | yes (no inter-app hop) | n/a | Shipped today; remains the phone path |
| Clipboard paste into Zodl | app is real, but clipboard integrity is not — crypto-clipper malware (rewrites addresses in clipboards) is a known class | no | Listed for completeness; not promoted |

**Threats named and placed:**
- *Scheme squatting / look-alike app:* eliminated — the OS routes nothing (Invariant 2).
  Squatters may still catch raw `zcash:` links in no-extension browsers; we cannot prevent
  third parties squatting, we refuse to participate → merchant guidance says link to the
  https pay-page (fails safe onto our TLS page), while `zcash:` links in page markup still
  work *with* our extension because interception happens inside the browser, before the OS.
- *Relay rewrite (x→y) in transit:* closed on the pinned chain (page → our extension → our
  helper → Zodl; browser enforces both pinnings; UDS hop is same-uid peer-checked).
- *Malicious source (compromised merchant page):* **out of any channel's reach** — ZIP-321
  requests are unsigned (no merchant-signature mechanism exists in the ZIP), so a request
  malicious at origin is indistinguishable in transit. Defense = the confirm sheet (BR-4)
  plus authenticated origin display. Same boundary as a hacked webshop showing a wrong
  bank account.
- *Malicious co-installed extension using "the same channel"* (Lukas's challenge #2,
  2026-07-08): **cannot** — the host manifest's `allowed_origins` pins our extension ID
  and the BROWSER enforces it at connect time; extensions are also process-isolated from
  each other (no API to read/alter another extension's messages or native calls). The
  channel is identity-bound, not a public bus. **The honest escalation it CAN do:**
  rewrite the merchant page's DOM (swap the address inside the payment link) before our
  extension reads it — client-side source compromise, same class as a hacked merchant
  page, unreachable by channel design. And for first-time payments, "user checks the
  address" is weak (no reference; two opaque strings). **Structural answer = BR-7
  provenance tiers (verify by domain, not by address).**
- *Look-alike extension in a store:* cannot reach the helper (ID pinning); residual = fake
  UI phishing, same class as fake wallet apps; mitigated by official-listing links only.
- *Local malware (files/binaries replaced):* machine-owned boundary; Touch ID on the real
  confirm remains the spend gate; noted, not solvable here.
- *Request spam / drive-by:* extension acts only on explicit user click (user gesture);
  helper rate-limits; one in-flight request; Zodl drops arrivals while locked/onboarding/
  restoring.

## 3. Decisions (v2)

- **BR-1 · pay-only (unchanged):** zero wallet data in the browser, ever. Glance = v2+
  decision, separate.
- **BR-2 · channel policy (NEW, supersedes v1 BR-3):** Zodl registers NO custom URL
  scheme on any platform; the F3 deeplink gate stays as-is everywhere; the extension
  native-messaging chain is the ONLY web→Zodl channel. **No policy reversal needed —
  v1's BR-3 question is withdrawn.**
- **BR-3 · one-way (NEW, Lukas's call):** no txid/status to the page. Sharpest argument:
  merchants cannot trust a client-reported txid anyway (hostile clients lie) — they must
  match the payment on-chain per invoice (address/amount/memo), so txid-back adds zero
  merchant security while adding attack surface and a privacy leak (binds the browser
  session to an on-chain tx). Extension shows a helper-level "handed to Zodl" ack only.
  Consequence: the UDS protocol collapses to one-shot fire-and-forget — simpler than v1.
- **BR-4 · confirm hardening (absorbs v1's review flow):** review interstitial before the
  standard SendConfirmation: authenticated **origin line** (from the extension), address-
  book badge for known recipients, "first time paying this address" notice, default focus
  = Cancel, never while locked, rate-limited, everything rendered from the engine
  **Proposal** (F5) — never from page-supplied text. New strings en+es.
- **BR-5 · transport:** browser⇄helper = native messaging (browser-dictated framing);
  helper→Zodl = UDS one-shot `{v:1, id, type:"payRequest", uri, origin}` → local ack;
  same-uid peer check; schema validation; size caps; helper wakes Zodl
  (`open -b <bundle-id>`) if the socket is absent. Socket path chosen App-Group-relocatable
  (F6, sandbox-ready).
- **BR-6 · code placement:** `bridge/extension/` (vanilla MV3 JS), `bridge/host/` (small
  Swift SPM executable), Zodl feature = review interstitial + injection at the F5 seam
  behind `#if os(macOS)`. **v2 bonus: zero Info.plist AND zero pbxproj changes until B2**
  (no scheme registration at all).
- **BR-7 · request provenance tiers (added after the malicious-extension challenge —
  verify by domain, not by address):**
  - **Tier 1 — origin-verified:** the page carries a *pointer* to the payment request on
    the merchant's own domain; **Zodl re-fetches it natively over TLS** (outside the
    browser, beyond any extension's reach) and enforces `fetch domain == tab domain`
    (tab origin comes from OUR extension; no other extension can falsify it; the check
    runs in native code). A DOM-rewriting attacker must point off-domain → mismatch
    caught automatically. Residual = merchant's own server compromised (out of client
    scope). Fetch rules: https only, no cross-origin redirects, size cap, plain-text
    content. Merchant cost: serve the ZIP-321 text at a same-origin URL (static file
    suffices). Confirm sheet shows: "Request verified from shop.example".
  - **Tier 2 — page-embedded (plain `zcash:` links, ecosystem-compatible):**
    unverifiable by construction; the confirm sheet states it: "Request read from page
    content — Zodl cannot verify it wasn't altered in your browser. Verify the address
    with the merchant." + first-seen notice + default-Cancel + rate limit.
  - Markup for Tier 1 is additive (the plain `zcash:` URI stays for other wallets; the
    same-origin pointer rides alongside — exact attribute/format decided in the
    implementation plan). B0 may ship Tier 2 first; Tier 1 is the recommended-merchant
    path and lands before any public distribution.
  - **Real-world calibration (2026-07-08, CipherPay — cipherpay.app, presented to Lukas
    at the summit; whole stack MIT on github.com/atmospherelabs-dev):** their hosted
    checkout's "OPEN IN WALLET" is a genuine `<a href={zcash_uri}>` ZIP-321 anchor
    (`cipherpay-web` CheckoutClient.tsx:395) ⇒ **bridge-compatible as-is, zero changes
    on their side** (today, on desktop, that click is OS roulette or a dead end — the
    bridge is what makes it work). Two design consequences: (1) their checkout lives on
    `www.cipherpay.app` while invoices come from `api.cipherpay.app` ⇒ the Tier-1
    domain comparison must be **registrable domain (eTLD+1), not exact host**;
    (2) the Tier-1 pointer attribute should be **vendor-neutral**
    (`data-zcash-request-src`, not `data-zodl-…`) so it can become an ecosystem
    convention any wallet can verify — a one-attribute PR to their MIT checkout is the
    natural first partner move.
    Docs read (same day): ALL their integrations funnel buyers to the hosted
    `cipherpay.app/pay/{id}` page (Stripe model — no merchant-domain embeds) ⇒ eTLD+1
    holds across their entire surface; `GET /api/invoices/{id}` is public/no-auth and
    returns JSON incl. `zcash_uri` ⇒ a ready-made Tier-1 pointer — **B4 should accept
    both raw ZIP-321 text AND JSON carrying a `zcash_uri` field**. Their status loop
    (poll + SSE `/stream` + webhooks: detected→confirmed→underpaid) does the
    payment-received UX server-side — **independent confirmation that the one-way
    design (BR-3) needs nothing from us for full checkout UX**.

## 4. Phasing (v2)

- **B0 — the pinned channel end-to-end (~1–1.5 sessions):** MV3 extension (Chromium
  family; Firefox variant near-free — no wasm/SAB anywhere) + native-messaging helper +
  UDS one-shot + Zodl review/confirm flow. Demo: click "Pay with ZEC" in Brave → Zodl
  front → Touch ID → paid; merchant page never learns anything (watches chain). THE demo.
- **B1 — public entry point: DEFERRED (Lukas 2026-07-08 — "extension standalone is the
  best option for now").** The extension chain has no dependency on it; merchant story
  simplifies to "standard ZIP-321 `zcash:` links" (the existing ecosystem norm — zero
  merchant-side work; our extension upgrades those clicks wherever installed). What B1
  would add, deliberately deferred to the public-distribution decision: a safe landing
  for no-extension users (today: OS scheme roulette or nothing — ecosystem status quo,
  unchanged by us), a "get Zodl" onboarding funnel, and a QR for phone users on pages
  without one. If/when built: `https://pay.<domain>` static page, params in the URL
  fragment (never sent to the server), cooperating with the extension.
- **B2 — Safari packaging (post-WIP-land, ~1 session):** same extension in-bundle
  (`SFSafariWebExtensionHandler`) — new Xcode target ⇒ strictly after Lukas's pbxproj WIP
  lands.
- **Later, separate decisions:** balance glance; iOS universal-links entry
  (associated-domain, unsquattable — the iOS-correct analog of B1); store distribution;
  Android-world note (intent-filter squatting is worse there — same policy: never scheme).

## 5. Testing & gates

- Fixture: `bridge/demo/` page — valid/invalid/oversized requests, a drive-by
  auto-navigation case (must do nothing without a user click), and a raw `zcash:` link
  (must be intercepted by the extension; with the extension disabled, document the OS
  roulette honestly in the demo README).
- Manual matrix: decline; rate-limit; locked-app arrival; invalid URI; wrong extension ID
  calling the helper (refused); helper-with-Zodl-quit (wake path); origin display
  truthfulness (tab URL vs displayed); **Tier-1 mismatch (pointer to off-domain request →
  refused with warning); Tier-1 redirect-off-origin (refused); Tier-2 labeling present**;
  simulated DOM rewrite in the demo page (Tier 1 catches it, Tier 2 shows the
  unverified label).
- Unit: routing decision table, one-shot protocol encode/decode + size caps, rate limiter.
- Negative gate: `grep` proves no `CFBundleURLTypes`/`zcash:` handler registration exists
  in any target (Invariant 2 is a testable absence).
- Both Zodl schemes build green; en+es complete; scenario-matrix row added.

## 6. Effort
B0 ≈ 1–1.5 sessions · B1 deferred (≈1 when/if called) · B2 ≈ 1 (post-WIP). v1's ½-session
scheme shortcut is gone on purpose — it was speed borrowed from the trust model.

## 6b. iOS port sketch (Lukas's question, 2026-07-09 — the sandbox is NOT the blocker)

Same chain, stronger bindings: Safari Web Extension (same content.js interception,
ships INSIDE Zodl iOS — extension↔app binding is cryptographic, no host manifest) →
`SFSafariWebExtensionHandler` (helper hop deleted) → App Group container + Darwin
notification (the native iOS idiom of tonight's Mac fix) → identical intake/gates/
buffer-and-replay/review-card/engine-proposal code → Face ID. Wake = universal link
(extensions can't launch their containing app; domain-verified, unsquattable — the
adjudication table's own recommendation). In-transit rewrite: impossible for third
parties (no OS scheme hop, every process ours-signed); residuals unchanged (DOM
poisoning → Tier-1 re-fetch works identically; merchant-server compromise → out of
scope). Frictions: Safari-only (iOS Chrome/Brave/Firefox = WebKit shells, no
extensions) + one-time user enable in Settings + NEW app-extension target = pbxproj
= post-WIP, same gate and largely the SAME WORK as macOS-Safari packaging (one
"Safari family" wave covers both).

### 6b-ii · iOS reach tiers (Lukas's mass-market verdict, 2026-07-09)
Extension = enthusiast tier (Safari-only + one-time enable — correct but not mass).
**Mass tier on iOS = universal links** (zero setup, any browser, unsquattable) ⇒ the
DEFERRED B1 pay-page / "Open in Zodl" merchant button is PROMOTED on iOS from optional
sugar to the mass-market key (processor-side one-liner, same class as the Tier-1
attribute — CipherPay = natural first). QR tier covers cross-device only; the
browsing-ON-the-iPhone case is exactly where UL (masses) + extension (enthusiasts)
are the only possible answers. Invariants identical across all tiers.

## 7. Open questions
1. Naming ("Zodl Bridge"?).
2. ~~B1 domain choice + hosting~~ — moot while B1 is deferred; returns with the
   public-distribution decision.
3. Extension store timing (unpacked is fine for demo/dogfood).
4. Attach this spec to the team bundle (D1–D6 + browser-wallet spec)? Recommend yes.
