# MOB-1478 — Update migration UI to revised Figma designs

**Status:** awaiting approval · **Parent:** MOB-1458 · **Branch:** new `michal/MOB-1478-migration-ui-design-update`, forked off the current `michal/MOB-1458-ironwood-support-feature` tip; on completion it is pushed and a PR opens against `michal/MOB-1458-ironwood-support-feature`

## Sources

- Figma file `PR App Designs Q3'26` (`1aeq8gleYh9Yr1l33TwELR`), page **"↳ Updated Designs"** (canvas `3480:3238`) — five sections: Path A (immediate), Path B happy path (ZODL), Path B happy path (Keystone), permission-detail matrix, Error & Recovery. This page supersedes the older "↳ WIP" sections.
- Figma exposes no version-history API; change discovery = the dedicated page + 21 designer sticky notes (all transcribed) + node-id recency (`3508:*` "Confirm Transfer Plan" frames are the newest).
- Implemented baseline: `secant/Sources/Features/Migration/` (13 screens S1–S12 + Keystone sign), `CoordFlows/MigrationCoordFlow*`, SmartBanner migration content, `MigrationNotification.swift`. All migration data flows through the stub SDK gateways (unchanged by this task).
- Method: five per-cluster diff agents compared every assigned frame (screenshots + design context + string catalog) against the implemented SwiftUI. Downloaded frame PNGs live in the session scratchpad (`diff/*`, `stickies/*`) for execution-time reference.

## Headline

The update is **mostly conformance-verbatim** — Scheduled, Recovery, Complete, immediate Review, Sending, permission-screen copy, Keystone sign, and 7 of 8 banner states already match. The real changes:

1. **Tor step becomes a conditional bottom sheet** ("Enable Tor Protection"), shown only when the Tor setup flag is unset; the full-screen Network Privacy step (S5) is removed.
2. **New "How This Works" explainer screen** in the scheduled path (5 bullets: Split / Schedule / Pre-sign once / ZODL handles the rest / If something fails + dust footnote).
3. **Note Split (S2) leaves the forward flow** — splitting starts silently under the final commit CTA ("silent after commit", user-approved decision 2026-07-13). Split progress/failure phases survive only as the banner-tap re-entry surface.
4. **Confirm Transfer Plan** gets shortened copy, an "Amounts are randomized" footer line, and "in ~N hours" captions.
5. **Manual Review restructure** — new "This Transfer" summary block (step badge + Sends now + amount + fiat) above the Amount/Fee card.
6. **Migration Status additions** — "Sent N min ago" granularity, "Sending now" caption, and a **new post-reschedule confirmation state** ("Transfers N–M have been successfully rescheduled…", "Got it").
7. Smaller items: Entry disclaimer restructure + footer exclusivity, permission-screen warning-amber footer/Skip treatment, notifications-variant wiring fix, banner icon fixes, lock-screen notification copy restructure, Keystone scan call-site config.

Screens with **zero changes**: MigrationScheduled, MigrationRecovery (both variants), MigrationComplete (incl. dust), Review (immediate), Sending (both phases except one string), Background Delivery + Notifications copy, Keystone Sign screen body.

## Flow after the change

**Immediate (Path A):**
Entry (Immediate) → Next → *[Tor sheet if flag unset]* → Review Transfer → Confirm → *(silent split if needed)* → Sending → Sent → close.

**Scheduled (Path B, ZODL and Keystone):**
Entry (Privacy) → Next → **How This Works** → Continue → *[Tor sheet if flag unset]* → *[Allow Background Delivery if BG refresh off]* → *[Allow Notifications if undetermined]* → Confirm Transfer Plan → Confirm → *(silent split if needed + sign schedule; Keystone: existing batch QR sign/scan round-trip)* → Migration Scheduled → close. Home banner then reports splitting → progress.

Permissions never block (all branches funnel to Confirm Transfer Plan) — matches today's skip logic plus the `.manual` variant fix (W8).

**Removed from routing:** `.networkPrivacy` Path case (screen deleted), forward `.noteSplit` pushes (re-entry-only now).

---

## Workstreams

### W1 — Migration Entry (S1)

- `migrationEntry.footerNote` → **"Amounts transferred across pools are visible on-chain."**
- Disclaimer becomes a plain inline row (info icon + single paragraph — no title, no amber box): **"Your full balance will be revealed on-chain. Crossing the pool boundary exposes the transaction amount. We recommend selecting Migrate with Privacy instead."** Delete `migrationEntry.disclaimerTitle` usage.
- **Mutual exclusivity:** when Immediate is selected the disclaimer *replaces* the footer note (today they stack). One slot, two contents.
- Selected-Immediate card keeps its WarningYellow 500/600/700 treatment (hex-verified identical to design) and gains the soft outer glow/focus ring from the mock (nearest ZDesign token at execution; shadow fallback).
- Everything else verbatim — no other changes.

### W2 — Tor bottom sheet (replaces Network Privacy screen)

New shared `MigrationTorSheet` (small reducer + view, presented with the app's `zashiSheet` pattern, following the NoteSplit failure-sheet precedent) hosted by **Entry** (immediate path) and **How This Works** (scheduled path):

- Trigger: host screen's primary CTA tapped AND Tor setup flag unset (`walletStorage.exportTorSetupFlag() != true` — condition unchanged from today). Sheet dismissal by swipe = same as "Got it".
- Content: Tor badge (reuse current `torBadge` composition) · title **"Enable Tor Protection"** · body **"If Tor is available in your region, we recommend enabling it for enhanced privacy during the migration. This step is completely optional. You can also use a trusted VPN if Tor is unavailable in your region."** · toggle card: title **"Enable Tor Protection"** + desc **"Routes your connection through the Tor network for enhanced anonymity and privacy protection."** + `Toggle` (default **off**, keeping today's no-pre-selection bias; the mock's ON state read as illustrative) · single primary button **"Got it"** (reuse `migrationGotIt`).
- "Got it" persists the choice exactly as `MigrationNetworkPrivacyStore` does today (same walletStorage/Tor wiring), then continues navigation to the pending destination.
- **Delete** `Migration/MigrationNetworkPrivacy/` (view+store), its Path case, its tests (rewrite as sheet tests), and its now-unused strings.

### W3 — New "How This Works" screen

New `Migration/MigrationHowItWorks/` (Store + View) + Path case, pushed after Entry for privacy/scheduled mode:

- Title **"How This Works"**
- Intro: **"Moving funds between Zcash pools reveals the amount of each transfer. We split your balance into smaller transfers, spaced over time, so they're harder to correlate."**
- Five `MigrationBulletRow` items (bold lead-in + caption):
  1. `coinsSwap` — **Split** — "Your balance is divided into several smaller-sized amounts."
  2. `calendar` — **Schedule** — "Transfers are spaced out to make them harder to link together."
  3. `checkSquareBroken` *(new asset)* — **Pre-sign once** — "Approve now, with no further prompts."
  4. `faceSmile` *(or new `faceContent` if visually distinct — visual check at execution)* — **ZODL handles the rest** — "Each transfer goes out in its scheduled window while the app runs in the background."
  5. `bellRinging` — **If something fails** — "We'll notify you so you can complete it manually."
- Footer note (info icon + line, same pattern as Entry's footer): **"Choosing this option may require 'dust' be left in the Orchard pool – a small amount 0.0005 ZEC or less that won't be transferred."**
- Primary button **"Continue"** (new key — no generic reusable "Continue" exists, per catalog convention).
- Pure explainer: no timeline, no plan numbers, unparameterized.

### W4 — Silent note split (user decision: "silent after commit")

- Remove `.noteSplit` from forward routing. `MigrationCoordFlowCoordinator`'s `isNoteSplitNeeded()` branch moves under the two commit CTAs:
  - Scheduled: Confirm Transfer Plan's confirm runs split-if-needed (existing `prepareNoteSplit`/`submitNoteSplit` stubs; Keystone: the existing PCZT batch fork already bundles split + schedule into one QR ceremony) before/with `signAndStoreMigrationSchedule`, then pushes Scheduled.
  - Immediate: Review Transfer's confirm runs split-if-needed before executing the transfer, then Sending as today.
- `MigrationNoteSplit` keeps only its `.splitting`/`.confirmed` phases + failure sheet as the **re-entry surface** (`reentryRoute() == .noteSplitProgress`, banner tap during `.splitting`); the `.explainer` phase and its strings are deleted. Screen header comment updated to say re-entry-only. Since re-entry always lands it as flow root and the commit already happened before the split started, the `.confirmed` phase's Continue simply closes the flow (home banner carries the progression from there).
- Banner `.splitting` variant is **retained** (designs don't contradict it; the "Notes Splitting"-labeled home frames render the generic Required state and look like stale duplicates — flagged for design).
- Real-wiring note (out of scope now, recorded for the #2572 integration): with the real SDK, transfers are only proposable after the split tx lands; the silent-split sequencing must tolerate that latency. Stubs hide it today.

### W5 — Confirm Transfer Plan (S6) restyle

- Scheduled/fresh desc → **"Review the plan below — once confirmed, each transfer sends at its scheduled window over the next ~24 hours."** (replaces the long `descScheduled`).
- Manual desc → **"We recommend following the plan below. Split your balance into 5 transfers over ~24 hours. Amounts are randomized for privacy. ZODL will prompt you on app open."** (parameterized N/hours as today; behavior unchanged — confirm still sends the first transfer; nuance flagged in report).
- Recreated desc: **unchanged** (frame matches verbatim).
- New footer line above Confirm (same info-row pattern): **"Amounts are randomized to reduce linkability."**
- Timeline pending captions on the fresh/scheduled variant → **"in ~N hours"** (new key); recreated variant keeps today's "~N hours" (frames differ; followed as drawn, inconsistency flagged).
- Title/button unchanged.

### W6 — Manual Review Transfer (S7) restructure

Adopt variant (B) (`3491:11612`, newest, information-complete — iteration ambiguity flagged):

- Body shortened to: **"This transfer sends part of your Orchard balance to Ironwood as part of your scheduled migration."**
- New **"This Transfer"** block above the detail card: heading **"This Transfer"** + caption **"Once confirmed, this cannot be undone."**, then a mini row — `MigrationStepBadge(.active)` at **24pt** (component gains a size parameter, default 28) + **"Transfer N of M"** / **"Sends now"** + trailing amount + fiat (fiat via the shared exchange-rate state, as `MigrationTransferTimeline` does).
- Amount/Fee `MigrationDetailRow` card stays underneath. Immediate variant untouched.

### W7 — Migration Status (S10) additions

- `MigrationTransferRow` gains minutes-level recency; caption **"Sent N min ago"** (new key) when under an hour, hours text unchanged otherwise.
- New row status distinguishing the actively-broadcasting transfer; caption **"Sending now"** (new key). Stub data updated to exercise both.
- **New presentation `.rescheduleConfirmed(first:last:)`**: title reuses `migrationPlan.titleConfirm` ("Confirm Transfer Plan"), body **"Transfers {first}-{last} have been successfully rescheduled. Keep the app running in the background. If we miss a window, ZODL will prompt you on next open."** (new key), refreshed timeline with real ETAs, back arrow, single **"Got it"** → same exit as today's progress "Got it". Wiring: resume → Reschedule → `isRescheduling` spinner (unchanged) → on success land here instead of flipping back to `.resume`.

### W8 — Permission screens (S3 + S4)

- Copy: unchanged (verbatim matches, both screens, all bullets).
- **Warning treatment**, scoped to these two screens only (not a global `ZashiButton` change): footer info row text+icon → `Design.Utility.WarningYellow._700`; Skip button label `WarningYellow._700` with visible `WarningYellow._300` border on plain background (dark mode uses the tokens' built-in dark mappings).
- **Wiring fix:** `nextPermissionStepResult()` must construct `MigrationNotifications.State(variant: migrationManager.isManualDelivery() ? .manual : .scheduled)` — today the `.manual` copy variant is unreachable (always defaults `.scheduled`). Mirrors the ternary already used in `freshPlanVariant()`.
- `footerManual` copy **kept as-is** (the design frame shows the scheduled footer on the manual variant — judged a duplicate-frame artifact; flagged).

### W9 — Home banner + local notifications

- `.transferReady` icon → existing `Asset.Assets.infoCircle` (design uses info-circle; code wrongly uses alertCircle).
- New outline-style alert-circle asset (`icons/alertCircleOutline`, exported from Figma) for the banner's alert states (`.updatePlan`, `.transferWaiting`, `.transfersExpired`); the existing solid `alertCircle` stays untouched for the failure sheets.
- All banner copy/states otherwise unchanged (7/8 verbatim; `.complete` confirmed via the Home frame in the error section; `.splitting` retained per W4). Keep "~" separator and single-space "Transfers 3-5 expired" (mock inconsistencies flagged).
- `MigrationNotification.swift` copy restructure to the design's consistent split — **title = the specific fact, body = short CTA** (ZODL casing kept):
  - planNeedsUpdate: **"Migration plan needs update"** / **"Open ZODL to review the details."**
  - manualTransferReady(n): **"Transfer {n} — ready to send"** / **"Open ZODL to review the details."**
  - transferWaiting(n): **"Transfer {n} waiting"** / **"Open ZODL to send or re-schedule."**
  - migrationComplete: **"Migration complete"** / **"Open ZODL to review the details."**
  - transferComplete(...): unchanged (no mock exists; flagged).

### W10 — Keystone scan call-site config

In `MigrationCoordFlowCoordinator` where the scan step is built (after `.keystoneSign(.delegate(.getSignature))`):
- `scanState.instructions = ` new key **"Scan Keystone QR code\nto sign the transaction"** (matches the design byte-for-byte; a voting-namespaced key holds identical text but cross-feature reuse is fragile — new neutral key instead).
- `scanState.forceLibraryToHide = true` (design shows a single centered flash control; precedent: `AddKeystoneHWWalletCoordFlowCoordinator` already sets it).
- Keystone Sign screen itself: **no changes** (mirrors `SignWithKeystoneView` 1:1 by design; the frame's nav-arrow/no-title and Inter-address nits read as template artifacts — flagged, parity kept).

### W11 — Strings, assets, tests, bookkeeping

- All new/changed keys land in `Localizable.xcstrings` following the `migration<Screen><Element>` convention; obsolete keys (`migrationNetworkPrivacy.*` except what W2 reuses, `migrationEntry.disclaimerTitle`, `migrationNoteSplit` explainer strings) removed. One "sent" fix: `migrationSending.sentSubtitle` → **"Your ZEC was successfully sent to Ironwood."** (grammar fix the design makes).
- New assets: `checkSquareBroken` (bullet 3), possibly `faceContent`, `alertCircleOutline` — exported from Figma into `Assets.xcassets/icons/`, template-rendered like the MOB-1459 icon batch.
- Tests (Swift Testing only, TDD for new reducers): new suites for `MigrationHowItWorks`, `MigrationTorSheet`, Status `.rescheduleConfirmed`; updates to `MigrationCoordFlowTests` (rewired chains, sheet gating, silent split, scan config, notifications variant), `MigrationEntryTests` (exclusivity), `MigrationReviewTransferTests`, `MigrationStatusTests`, `MigrationTransferPlanTests`, `MigrationBannerVariantTests`/icon mapping, `MigrationNotificationTests` (new copy), `MigrationNoteSplitTests` (re-entry-only shape), `RootMigrationRoutingTests` if touched.
- Gates: full `zodlTests` green on `zodl-internal` + `zodl-testnet` build, both via `xcodebuild -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
- CHANGELOG entry under `[Unreleased]` (`[MOB-1478]`). Linear MOB-1478 description updated with the Updated-Designs page link + this spec's summary, and the PR link attached once it exists.
- **Branch / push / PR:** all work (this spec doc included) lands as logical `[MOB-1478] …` commits on a new branch `michal/MOB-1478-migration-ui-design-update` created from the current local `michal/MOB-1458-ironwood-support-feature` tip. When gates are green: (1) push origin's `michal/MOB-1458-ironwood-support-feature` up to the current local state first — `--force-with-lease`, since origin still holds the pre-rebase base; without this the PR diff would drown in the whole adaptation history — then (2) push the new branch and (3) open a GitHub PR (`gh`) titled `[MOB-1478] Update migration UI to revised Figma designs` with base `michal/MOB-1458-ironwood-support-feature`.

## Execution shape (post-approval, autonomous)

Subagent-driven: leaf-screen workstreams (W1, W5, W6, W7, W8, W9, W10) parallelize; W2+W3+W4 (coordinator-touching) execute as one serialized stream to avoid conflicts; strings/assets first so screens build against them. TDD where a reducer changes. I verify gates and commit after each coherent stream, on the new `michal/MOB-1478-migration-ui-design-update` branch. When everything is green: base-branch push (`--force-with-lease`), branch push, PR to `michal/MOB-1458-ironwood-support-feature`, PR link onto the Linear issue. Non-blocking findings accumulate into the final report.

## Flags for the final report (not blocking, decided or deferred as noted)

Design-file inconsistencies: stale "Notes Splitting" home frames; Entry disclaimer old/new duplicate (`3508:11219` stale); Review manual A/3/B iteration (B chosen); "in ~N hours" vs "~N hours"; "·" vs "~" separator; double space in "Transfers  3-5 expired"; manual-plan closing sentence vs actual first-send behavior; footerManual vs footerScheduled; sticky mislabels on the B8 frames; `3491:9965` labeled dust but showing Home; no `.transferComplete` notification mock; no dark-mode frames; Tor toggle shown ON in mock (kept off); "Zodl" casing in mocks (normalized to ZODL).
Deliberately not done (shared-component blast radius): global tertiary-button border behavior, Scan view frosted icon badges + scrim %, Keystone QR card border/shadow, Keystone nav-title/back-arrow flip, Inter-vs-RobotoMono address font. Real-wiring latency note from W4.
