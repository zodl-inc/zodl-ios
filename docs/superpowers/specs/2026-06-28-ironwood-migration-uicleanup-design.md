# Ironwood Migration Prototype — UI Cleanup: Localization + Design-System Conformance

**Date:** 2026-06-28
**Status:** Proposed (awaiting approval)
**Type:** Prototype cleanup (no behavior change) — migration feature UI

## Problem

The migration prototype was built screen-first across rounds 1–6 without going through the app's
localization and design-system conventions. Two kinds of drift accumulated:

1. **Strings** — ~95–125 user-facing strings are hardcoded English literals (`Text("…")`,
   `ZashiButton("…")`) or, worse, English copy built in computed `String` properties and rendered
   **verbatim** via `Text(stringVar)` (never localized at all). The app's convention is explicit
   camelCase keys in `Localizable.xcstrings`, referenced via `Text(localizable: .key)` /
   `String(localizable: .key)` (xcstrings-tool-plugin codegen). Round-5 builds also auto-extracted
   ~12+ English-keyed entries into the catalog, inconsistent with that convention.
2. **Design system** — a cluster of raw SwiftUI primitives bypass the design system: `Color.orange`
   / `.foregroundColor(.orange)` instead of `Design.Utility.*` tokens, `.font(.system(...))` instead
   of `.zFont(...)`, `Image(systemName:)` instead of `.zImage` on brand assets, and one hardcoded
   `.light` color scheme.

**Goal:** bring every shipped migration screen to the app's string + design-system conventions, with
**zero behavior or layout change** (faithful conversions only).

## Conventions (the bar)

- **Strings:** `Text(localizable: .camelCaseKey)` / `String(localizable: .camelCaseKey)`. Parameterized:
  `.key(arg)` where the catalog value uses C format specifiers — `%@` (String), `%lld` (Int),
  positional `%1$…/%2$…` for multi-arg. Reference: the non-migration half of `SmartBannerContent.swift`.
- **Buttons:** `ZashiButton(_ title: String, …)` — title is a localized `String`.
- **Colors:** `Design.*` tokens via `.color(colorScheme)` / `.zForegroundColor(…)`. Warning/amber =
  `Design.Utility.WarningYellow._500.color(colorScheme)`.
- **Fonts:** `.zFont(…)`.
- **Icons:** `Asset.Assets.Icons.*.image.zImage(size:…, color:/style:…)` (or `Asset.Assets.<name>.image`).

## Scope decisions (answered)

- **Debug panel** (`MigrationDebugView`/`MigrationDebugStore`, ~48 strings): **left as-is.** Developer-only
  tool behind a hidden Home long-press; not shipped UI. Not localized, not restyled.
- **SF Symbols:** **convert all** `Image(systemName:)` to the closest brand asset (mapping in Part B).
- **Stale catalog entries:** **remove** the orphaned English-keyed migration entries (Part C).

## Non-goals / deliberate non-changes

- No behavior, navigation, or layout change. Pure convention conversion.
- **Pure number+token interpolations stay** (e.g. `Text("\(amount.decimalString()) \(tokenName)")`) —
  these are data, not translatable copy. Only interpolations containing English words become
  parameterized keys.
- **`.foregroundStyle(.white)` on saturated/brand-colored badges stays** (StepBadge L35/L50, Recovery
  L134) — matches the component's own accepted pattern; the fills are mode-independent, so converting to
  `Design.Text.opposite` would regress dark mode.
- Stores / Models / SDK layer are already clean (copy lives in views) — untouched except the SmartBanner
  computed vars.
- `MigrationFiat` (`$135.22` fallback) and `decimalString()` are number formatting — untouched.

---

## Part A — String localization (canonical key table)

**Reused existing keys (no new catalog entry):** `.generalDone` ("Done"), `.generalConfirm` ("Confirm"),
`.generalNext` ("Next"), `.generalClose` ("Close").

New keys are grouped by file. `(args)` = parameterized; value shows the catalog English with specifiers.

### MigrationEntryView
| Key | English value |
|---|---|
| migrationEntryTitle | Move to Ironwood |
| migrationEntryDescription `(%@)` | Latest Zcash network upgrade requires moving your %@ from the Orchard pool to the new Ironwood pool. Your funds are safe. |
| migrationEntryOrchardBalanceLabel | Orchard balance |
| migrationEntryOptionImmediateTitle | Migrate Immediately |
| migrationEntryOptionImmediateSubtitle | Single transfer · Sends now · No privacy |
| migrationEntryOptionPrivateTitle | Migrate with Privacy |
| migrationEntryOptionPrivateSubtitle | Split transfers over time · Scheduled in background · Maximum privacy |
| migrationEntryDisclaimer | Pool-crossing transfer amounts are visible on-chain. |
| migrationEntryBalanceLoadFailed | Couldn't load your Orchard balance |
| migrationEntryTryAgainButton | Try again |

Reuse `.generalNext` for "Next" (L59). Amount+token (L103) left as-is.

### MigrationNoteSplitView
| Key | English value |
|---|---|
| migrationNoteSplitTitle | Split Your Wallet Funds |
| migrationNoteSplitExplainerBody | This sends a transaction to yourself, breaking your balance into smaller notes. Each Ironwood migration transfer then settles independently — no waiting for change. |
| migrationNoteSplitConfirmedTitle | Split Confirmed! |
| migrationNoteSplitSplittingTitle | Splitting Funds… |
| migrationNoteSplitProgressBody `(%@)` | Splitting your balance into transfer-sized notes. This is a send-to-self — your %@ stays in Orchard. |
| migrationNoteSplitDetailTransactionId | Transaction ID |
| migrationNoteSplitDetailAmount | Amount |
| migrationNoteSplitDetailFee | Fee |
| migrationNoteSplitContinueButton | Continue |
| migrationNoteSplitInProgressTitle | Transaction in Progress |
| migrationNoteSplitInProgressBody | Keep your phone on and the app open until this step completes. |

Reuse `.generalConfirm` (L67). **Restructure:** delete `progressTitle` computed var (L108–110); render
`Text(localizable: store.step == .confirmed ? .migrationNoteSplitConfirmedTitle : .migrationNoteSplitSplittingTitle)`
at L85; disabled button L160 reuses `.migrationNoteSplitSplittingTitle`.

### MigrationStatusView
| Key | English value |
|---|---|
| migrationStatusScheduledTitle | Migration Scheduled |
| migrationStatusScheduledSubtitle `(%@)` | Your %@ will be migrated to the Ironwood pool based on the schedule you approved. |
| migrationStatusSummaryTotalToTransfer | Total to transfer |
| migrationStatusSummaryPool | Pool |
| migrationStatusSummaryPoolValue | Orchard → Ironwood |
| migrationStatusSummaryTransfers | Transfers |
| migrationStatusSummaryTransfersValue `(%1$lld,%2$lld)` | %1$lld of %2$lld |
| migrationStatusSummaryDuration | Duration |
| migrationStatusSummaryDurationValue `(%lld)` | ~%lld hours |
| migrationStatusResumeTitle | Resume Migration |
| migrationStatusResumeSubtitleAgo `(%1$lld,%2$lld,%3$lld)` | Transfer %1$lld of %2$lld was scheduled %3$lldh ago but wasn't sent. Reschedule and send now. |
| migrationStatusResumeSubtitle `(%1$lld,%2$lld)` | Transfer %1$lld of %2$lld was scheduled but wasn't sent. Reschedule and send now. |
| migrationStatusSendNowButton | Send now |
| migrationStatusRescheduleButton | Reschedule |
| migrationStatusWindowMissedTitle | Transfer window missed |
| migrationStatusWindowMissedBody | Send now or reschedule to the next window. |
| migrationStatusInProgressTitle | Migration in Progress |
| migrationStatusInProgressSubtitle | Transfers send automatically in the background. Keep ZODL installed. |
| migrationStatusTransferRowTitle `(%lld)` | Transfer %lld |
| migrationStatusProgressCardTitle | Migration Progress |
| migrationStatusProgressCardDetail `(%1$lld,%2$lld,%3$lld)` | %1$lld of %2$lld transfers complete · %3$lld%% complete |
| migrationStatusRowSent | Sent |
| migrationStatusRowReadyNow | Ready now |
| migrationStatusRowOverdueAgo `(%lld)` | Overdue · %lldh ago |
| migrationStatusRowOverdue | Overdue |
| migrationStatusRowReadySoon | Ready soon |
| migrationStatusRowHours `(%lld)` | ~%lld hours |
| migrationStatusRowInvalid | Invalid |
| migrationStatusRowExpired | Expired |

Reuse `.generalDone` (L102, L226). **Restructure:** `resumeSubtitle` (L173–181) → pick between the two
parameterized keys in the view; `statusLabel(_:)` (L306–317) → `switch` returns `String(localizable: .…)`
per case.

### MigrationRecoveryView
| Key | English value |
|---|---|
| migrationRecoveryTitle | Transfer No Longer Valid |
| migrationRecoverySubtitle `(%lld)` | Transfer %lld was pre-signed for a balance that has since changed. It needs to be re-created for the remaining amount. |
| migrationRecoveryLearnMoreButton | Learn more |
| migrationRecoveryRecreateButton | Re-create Transfer |
| migrationRecoveryStaleCardTitle | Stale transfer detected |
| migrationRecoveryStaleCardBody `(%1$@,%2$@)` | Signed for %1$@ %2$@. Your balance has changed since pre-signing. |
| migrationRecoveryWhatNextTitle | What Happens Next |
| migrationRecoveryWhatNextBullet1 `(%lld)` | A new transfer is created for Transfer %lld |
| migrationRecoveryWhatNextBullet2 | Remaining transfers are re-scheduled |
| migrationRecoveryWhatNextBullet3 | No funds are lost — only the pre-signed key is discarded |
| migrationRecoveryContinuesNote `(%1$lld,%2$lld)` | %1$lld of %2$lld transfers done; migration will continue. |

### MigrationImmediateReviewView
| Key | English value |
|---|---|
| migrationImmediateReviewTitle | Review Transfer |
| migrationImmediateReviewSubtitle | Your full Orchard balance will be transferred to Ironwood in a single on-chain transfer. |
| migrationImmediateReviewYourTransfer | Your Transfer |
| migrationImmediateReviewCannotCancel | Once confirmed, this transfer cannot be cancelled. |
| migrationImmediateReviewTransferOneOfOne | Transfer 1 of 1 |
| migrationImmediateReviewSendImmediately | Send immediately |
| migrationImmediateReviewPrivacyDisclaimerTitle | Privacy Disclaimer |
| migrationImmediateReviewPrivacyDisclaimerBody | Your full balance will be revealed — crossing the pool boundary reveals the transaction amount. We recommend going back and selecting Migrate with Privacy instead. |
| migrationImmediateReviewSending | Sending… |
| migrationImmediateReviewFailedTitle | Transfer failed |
| migrationImmediateReviewFailedBody | Something went wrong. Please try again from the migration screen. |

Reuse `.generalConfirm` (L86), `.generalClose` (L182).

### MigrationTransferPlanView
| Key | English value |
|---|---|
| migrationTransferPlanTitle | Transfer Plan |
| migrationTransferPlanBody `(%1$lld,%2$lld)` | Your balance splits into %1$lld transfers over ~%2$lld hours. Approve once and ZODL handles the rest — just keep the app installed. Amounts are randomized for privacy. |
| migrationTransferPlanDestination | Destination |
| migrationTransferPlanDestinationValue | Ironwood |
| migrationTransferPlanSummary | Summary |
| migrationTransferPlanSummaryValue `(%1$lld,%2$lld)` | %1$lld transfers · ~%2$lld hours |
| migrationTransferPlanSplitHeader | Your balance will be split into |
| migrationTransferPlanTransferNumber `(%lld)` | Transfer %lld |
| migrationTransferPlanReadyNow | Ready now |
| migrationTransferPlanHoursAway `(%lld)` | ~%lld hours |

Reuse `.generalConfirm` (L54). **Restructure:** delete `bodyText` and `timeLabel(_:)` computed members;
render via the parameterized keys directly.

### MigrationNetworkPrivacyView
| Key | English value |
|---|---|
| migrationNetworkPrivacyTitle | Network Privacy |
| migrationNetworkPrivacySubtitle | Enable Tor to broadcast privately through the Tor network. This prevents your IP address from being linked to the transfer. |
| migrationNetworkPrivacyWhatHappensNext | What Happens Next |
| migrationNetworkPrivacyWithTorTitle | With Tor |
| migrationNetworkPrivacyWithTorDetail | IP hidden from the network. |
| migrationNetworkPrivacyWithoutTorTitle | Without Tor or a VPN |
| migrationNetworkPrivacyWithoutTorDetail | Transfers are still de-correlated in time, but your IP is visible to network operators. |
| migrationNetworkPrivacyRouteViaTor | Route via Tor |
| migrationNetworkPrivacyRouteViaTorDetail | Use Tor for transaction submission |
| migrationNetworkPrivacyTorUnavailable | Tor is not available on this network. Consider a trusted VPN, or continue without. |

Reuse `.generalNext` (L78).

### MigrationCompleteView
| Key | English value |
|---|---|
| migrationCompleteTitle | Migration Complete |
| migrationCompleteSubtitle `(%@)` | Your %@ is now in the Ironwood pool. |
| migrationCompleteTotalTransferred | Total transferred |
| migrationCompleteRemainingDust | Remaining dust |
| migrationCompleteTransfers | Transfers |
| migrationCompleteTransfersValue `(%1$lld,%2$lld)` | %1$lld of %2$lld sent |
| migrationCompleteDuration | Duration |
| migrationCompleteDurationInstant | Instant |
| migrationCompleteDurationHours `(%lld)` | ~%lld hours |
| migrationCompleteDustTitle | Dust balance remaining |
| migrationCompleteDustBody `(%1$@,%2$@)` | %1$@ %2$@ stayed in Orchard — below the transfer threshold. It will migrate in a future batch. |

Reuse `.generalDone` (L62).

### MigrationBackgroundDeliveryView
| Key | English value |
|---|---|
| migrationBgDeliveryTitle | Allow Background Delivery |
| migrationBgDeliveryBullet1Title | Transfers send automatically |
| migrationBgDeliveryBullet1Subtitle | Your device wakes up and broadcasts each transfer at its scheduled window. |
| migrationBgDeliveryBullet2Title | No need to open the app for each send |
| migrationBgDeliveryBullet2Subtitle | Once committed, transfers broadcast in the background over the next ~24 hours. |
| migrationBgDeliveryBullet3Title | Sends de-correlated from your activity |
| migrationBgDeliveryBullet3Subtitle | Transfers go out on fixed-ish windows, not tied to when you open ZODL. |
| migrationBgDeliveryDisclaimer | Background delivery is best-effort, not guaranteed. |
| migrationBgDeliverySkip | Skip — I'll open the app |
| migrationBgDeliveryAllow | Allow Background Access |

### SmartBannerContent (migration computed vars → `String(localizable:)`)
| Key | English value |
|---|---|
| smartBannerContentMigrationCompleteTitle | Migration complete |
| smartBannerContentMigrationStalledTitle `(%lld)` | Transfer %lld waiting |
| smartBannerContentMigrationInProgressTitle | Migration in Progress |
| smartBannerContentMigrationAttentionTitle | Action Needed |
| smartBannerContentMigrationRequiredTitle | Migration Required |
| smartBannerContentMigrationCompleteInfoDust | Dust balance stays in Orchard for now |
| smartBannerContentMigrationCompleteInfo | Your funds are now in Ironwood |
| smartBannerContentMigrationStalledInfo | Tap to reschedule or send now |
| smartBannerContentMigrationInProgressInfo | Transfers are sending in the background |
| smartBannerContentMigrationAttentionInfo | A transfer needs your attention |
| smartBannerContentMigrationRequiredInfo | Move your funds to Ironwood |
| smartBannerContentMigrationButtonMore | More |
| smartBannerContentMigrationButtonView | View |
| smartBannerContentMigrationButtonResolve | Resolve |
| smartBannerContentMigrationButtonMigrate | Migrate |

The three computed vars keep their `switch` shape but each branch returns `String(localizable: .…)`
(stalled case: `String(localizable: .smartBannerContentMigrationStalledTitle(transferNumber))`).
`migrationContent()` already uses `Text(var)` / `ZashiButton(var)` — no view change needed.

**New keys total ≈ 125.** Tests reference no migration strings by literal, so no test copy changes.

---

## Part B — Design-system fixes (shipped views only)

### B1. `.orange` → `Design.Utility.WarningYellow`
Faithful hue match (orange→amber token), preserves the approved look. Foreground →
`Design.Utility.WarningYellow._500.color(colorScheme)`; the `Color.orange.opacity(0.12)` fill →
`Design.Utility.WarningYellow._500.color(colorScheme).opacity(0.12)`.
- ImmediateReview L129, L132, L139, L145 (fill), L170
- NetworkPrivacy L69
- StepBadge L47 (`Circle().fill(Color.orange)`)

Views needing `@Environment(\.colorScheme) private var colorScheme` added if absent: **NetworkPrivacy**
(confirmed missing); verify ImmediateReview.

### B2. `.font(.system(...))` → `.zFont(...)` (or fold into `.zImage(size:)`)
- StepBadge L34, L39, L44, L49 → `.zFont(.semiBold/.medium, size: 12/13)` on the number `Text`
- Recovery L133 → `.zFont(.semiBold, size: 10)`
- NetworkPrivacy L92 + BackgroundDelivery L76 → folded into `.zImage(size: 18 / 20, …)` when the icon
  becomes an asset (B3)

### B3. SF Symbol → brand asset (`.zImage`)
| `Image(systemName:)` | → `Asset.Assets.…` | Sites |
|---|---|---|
| info.circle | `infoOutline` | NoteSplit:173, ImmediateReview:138, Status:185, Recovery:100, Complete:140 |
| xmark | `Icons.xClose` | Status:54, Recovery:72 |
| checkmark.seal.fill | `Icons.checkVerifiedFilled` | NoteSplit:124, Status:79 |
| checkmark | `Icons.check` | StepBadge:33 |
| exclamationmark | `Icons.alertCircle` | StepBadge:48 |
| exclamationmark.triangle.fill | `Icons.alertTriangle` | ImmediateReview:166 |
| bolt.fill | `Icons.lightning` | BackgroundDelivery:31 |
| app.badge | `Icons.checkVerified` **(approx — eyeball)** | BackgroundDelivery:37 |
| shuffle | `Icons.swapArrows` | BackgroundDelivery:43 |
| lock.shield | `Icons.shieldTick` | NetworkPrivacy:38 |
| eye | `Icons.eyeOn` | NetworkPrivacy:44 |

Render with `.zImage(size: <existing size>, color: <existing color>)` preserving current size/tint.
`app.badge`→`checkVerified` is the one non-literal mapping (no app/badge brand asset exists); flagged in
the final report for a visual check.

### B4. Hardcoded color scheme
- NetworkPrivacy L93 `Design.Text.primary.color(.light)` → `.color(colorScheme)` (after adding the
  `@Environment`).

### B5. Deliberate non-changes
- `.foregroundStyle(.white)` on saturated badges (StepBadge L35/L50, Recovery L134) — kept (see Non-goals).
- Toolbar close `Button { } label: {}` wrappers — kept as Buttons (house pattern); only their inner
  `Image(systemName:)` is converted per B3.

---

## Part C — Catalog cleanup (remove orphaned English-keyed entries)

After the view conversions, English-keyed auto-extractions become orphaned. **Removal rule (safe):**
remove an English-keyed entry **only if** `grep -rn '"<exact phrase>"' secant/Sources` returns **zero**
remaining literal references (guards against removing a string still used by non-migration code). Confirmed
candidates: "Allow Background Delivery", "Migration Complete", "Migration in Progress", "Migration
Scheduled", "Move to Ironwood", "Network Privacy", "Resume Migration", "Review Transfer", "Split Your
Wallet Funds", "Transfer No Longer Valid", "Transfer Plan", "What Happens Next" — plus any others the
post-conversion grep proves unreferenced. Short generic words ("Done", "Next", …) are left untouched
(shared / reused as `.general*`).

---

## Execution plan

1. **Catalog (single writer, me):** add all ~125 keys to `Localizable.xcstrings` via a Python script that
   matches the file's existing formatting (2-space indent, `" : "` separators, `ensure_ascii=False` to
   preserve `…`/`—`/`→`) so the diff is only the new entries. Validate JSON round-trips.
2. **View edits (parallel subagents, one per file/group):** apply the file's Part A key swaps + Part B
   design-system fixes + the three computed-property restructures, each handed its exact mapping table
   from this spec (no naming drift).
3. **Build** (`xcodebuild … -skipMacroValidation …`, Xcode MCP offline) to generate the xcstrings-tool
   accessors and surface any key/arg/asset mismatches; fix them.
4. **Catalog cleanup (Part C):** run the removal-rule grep, delete proven-orphaned entries, rebuild.
5. **Tests:** migration + SmartBanner suites (`DummyMigrationEngineTests`, `MigrationStateStoreTests`,
   `MigrationBackgroundWorkerTests`, `SmartBannerMigrationCompleteTests`, `SmartBannerSyncThresholdTests`).
   No assertions depend on copy, so they should stay green.
6. **`graphify update .`**, then commit (`[#MOB-1451] …`, Co-Authored-By trailer). `graphify-out/` not
   committed.

## Testing & verification

- **Build green** is the primary gate (key existence, arg types, asset names are all compile-checked by
  xcstrings-tool + Swift).
- **Suites green** (23 existing migration/banner tests).
- **Spot smoke** (optional, if simulator cooperates): launch, open migration flow, confirm copy renders
  (no raw keys shown) and the converted icons/colors look right — especially the `app.badge`→`checkVerified`
  approximation.

## Risks

- **Format-specifier / arg-type mismatch** → build error. Mitigated by the explicit arg columns above;
  build catches any miss.
- **Asset-name typo** → build error; asset names here are taken from the generated catalog, not guessed.
- **Catalog JSON formatting churn** → mitigated by the formatting-preserving script.
- **Visual shift from icon swaps** → authorized ("convert all"); the only approximate mapping
  (`app.badge`) is flagged for an eyeball.
