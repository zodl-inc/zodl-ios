//
//  MigrationManagerInterface.swift
//  Zashi
//
//  App-owned logic for the Orchard -> Ironwood migration (MOB-1466): persistence and the
//  banner-variant / re-entry-route derivations.
//
//  2026-08-07: the app-owned half of the sync<->send privacy gate (MOB-1496 W3's `sendGate` /
//  `MigrationSendGate`) is GONE. It held a migration send for a fixed window after the last
//  completed sync — the mirror image of the SDK's post-broadcast buffer, and the same identifiable
//  pattern: a fixed delay between a sync and a broadcast is a correlation signature, not a defense
//  against one. Both directions are now behavior-based; see `MigrationSyncGate`'s type doc in the
//  SDK for the ruling. What survives is the SDK's own present-tense hold (a submission actually in
//  flight) and this app's stop-sync-before-broadcast sequencing, neither of which is a timer. The SDK only exposes raw state (`MigrationState`,
//  `MigrationProgress`, …) — this client is the single place that turns that state plus app-side
//  flags into what the UI actually shows.
//
//  MOB-1497 (T5) — DELETED (audit 2026-08-03, #16): the per-account "pending background Tor
//  prompt" latch is gone; nothing could arm it and nothing presented its sheet.
//

import Foundation
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture

extension DependencyValues {
    var migrationManager: MigrationManagerClient {
        get { self[MigrationManagerClient.self] }
        set { self[MigrationManagerClient.self] = newValue }
    }
}

@DependencyClient
struct MigrationManagerClient: Sendable {
    // Derivations (pure given SDK members + persistence; unit-tested as tables)
    var bannerVariant: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationBannerVariant? = { _ in nil }
    // MOB-1496: async — the SDK's per-account migration reads are now `async throws`.
    var reentryRoute: @Sendable () async -> MigrationReentryRoute = { .entry }
    // MOB-1483: "Ironwood (NU6.3) activated on the current network" — gates `bannerVariant`,
    // `reentryRoute`, and `reconcile()`. `= { false }` is a required macro default (non-Void,
    // non-throwing return), NOT a test fallback — see the `recordCommittedSchedule` note below.
    var isIronwoodActivated: @Sendable () -> Bool = { false }
    var orchardBalanceToMigrate: @Sendable (_ accountUUID: AccountUUID?) async -> Zatoshi = { _ in .zero }
    // Progress UI (MOB-1496: relocated from SDKSynchronizerClient — app-side derivations over the
    // SDK's per-account state, not raw SDK calls). `nil` accountUUID resolves the selected account
    // internally, same convention as `bannerVariant` above.
    var migrationSummary: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationSummary = { _ in MigrationSummary.zero }
    var migrationTransfers: @Sendable (_ accountUUID: AccountUUID?) async -> [MigrationTransferRow] = { _ in [] }
    // Persisted committed schedule (MOB-1496 W2): the SDK retains no proposal list once a schedule
    // is committed — these persist the app's own record of it, which `migrationSummary`/
    // `migrationTransfers` above derive from. `nil` accountUUID resolves the selected account
    // internally, same convention as the other members here.
    // swift-dependencies gotcha: these no-op defaults do NOT let a test skip mocking. The client has
    // no `testValue`, so the first uncustomized `@Dependency(\.migrationManager)` access in a test
    // fails "has no test implementation" (whole-client, any member/arity — not per-endpoint).
    // Customizing ANY one member unlocks the client for that test; un-overridden members then fall
    // through to their LIVE impl, not these no-ops.
    var recordCommittedSchedule: @Sendable (_ accountUUID: AccountUUID?, _ schedule: MigrationSchedule) async -> Void = { _, _ in }
    var recordTransferBroadcast: @Sendable (_ accountUUID: AccountUUID?, _ result: MigrationTransferResult) async -> Void = { _, _ in }
    // Dust resolution (MOB-1487; MOB-1496: the lock is the SDK's real `lockMigrationResidual`
    // now, no longer app persistence). MOB-1509: per-account (`nil` resolves the selected
    // account) — two parallel migrations must not share one lock verdict.
    var lockMigrationDust: @Sendable (_ accountUUID: AccountUUID?) async throws -> Void
    // MOB-1496: async now — derived from a live SDK balance read (the account's Orchard
    // `PoolBalance.lockedValue`) rather than app-persisted storage.
    var isMigrationDustLocked: @Sendable (_ accountUUID: AccountUUID?) async -> Bool = { _ in false }
    // MOB-1496: the locked remainder amount (the account's Orchard `PoolBalance.lockedValue`).
    // The Complete screen's locked confirmation shows this on re-entry — `migrationSummary().dust`
    // re-plans from live spendable notes once the migration state is terminal, so it reads zero
    // after a lock; the locked value is what still reports the remainder.
    var migrationLockedAmount: @Sendable (_ accountUUID: AccountUUID?) async -> Zatoshi = { _ in .zero }
    // MOB-1511 (W2): the multi-round labels' context — CURRENT round (app-persisted completed-run
    // count + 1) and the engine's estimated TOTAL rounds, `nil` when the SDK's estimate has zero
    // runs (see `SDKSynchronizerClient.estimateMigrationRunCount`'s doc).
    var migrationRoundContext: @Sendable (_ accountUUID: AccountUUID?) async -> (round: Int, totalRounds: Int?) = { _ in (1, nil) }
    // D14: how many "Split Balance" rows the PRE-commit plan should show — the engine's estimated
    // preparation-transaction count for the next run (`SDKSynchronizerClient
    // .estimateMigrationPreparationCount`). Falls back to `1` whenever the estimate is unavailable,
    // which is exactly what every plan showed before D14.
    var migrationPreparationCount: @Sendable (_ accountUUID: AccountUUID?) async -> Int = { _ in 1 }
    // D14: the POST-commit "Split Balance" rows, derived from the run's real `.preparation`-kind
    // transaction statuses (`MigrationDerivations.preparationRows`) so each one carries its own
    // state and ETA. `nil` when no preparation statuses are readable — the caller then falls back
    // to the single synthesized row, preserving pre-D14 behavior.
    var migrationPreparationRows: @Sendable (_ accountUUID: AccountUUID?) async -> [MigrationTransferRow]? = { _ in nil }
    /// A14: the "Prepare Your Balance" sheet's real per-step ladder — each preparation's own state
    /// and, when it is dependency-blocked, the DISPLAY numbers of the steps it waits on. `nil` when
    /// the run reports no preparation statuses, which keeps the interim placeholder in play rather
    /// than emptying a sheet the user already opened.
    var migrationPrepareBalanceRows: @Sendable (_ accountUUID: AccountUUID?) async -> [MigrationPrepareBalanceRow]? = { _ in nil }
    // Per-account migration-state stream (MOB-1496: relocated from SDKSynchronizerClient's
    // `migrationStateStream`) — emits on `reconcile()` and whenever a store reports a completed
    // migration op. `nil` accountUUID resolves the selected account internally.
    /// THE DRIVER — one app-open, one engine step, discharged. See `MigrationStepDriver`.
    ///
    /// This is the ONLY member that decides what a migration app-open does. Called at exactly two
    /// moments per open — `.beforeSync` before the wire is touched, `.afterSync` at the
    /// sync-complete edge — from Root and from nowhere else. Tapping the icon and tapping a
    /// notification reach the identical calls in the identical order; a notification tap adds
    /// navigation and nothing else.
    ///
    /// Never throws and never traps: a migration read failure degrades to a logged verdict rather
    /// than being allowed to brick ordinary wallet syncing.
    var advance: @Sendable (_ phase: MigrationOpenPhase) async -> MigrationStepVerdict = { _ in .notApplicable }

    /// What this app-open is FOR — see `MigrationVisit`. Ask BEFORE starting sync; `.send` means
    /// this session belongs to a broadcast and must not initiate one.
    ///
    /// Degrades to `.sync` if the reads fail. Fail-open is the right direction here: a migration
    /// read error must not be able to brick ordinary wallet syncing, and the SDK's own reactive
    /// gate is still behind this as a second line of defence.
    ///
    /// NOTE: `advance(.beforeSync)` above is what DISCHARGES the broadcast. This member answers only
    /// the narrower ZIP 318 question "may this session sync?", which Root must ask before `start()`
    /// — the two are deliberately separate calls at the same moment rather than one, because the
    /// sync decision has to be taken and acted on before any step is executed.
    var visitKind: @Sendable () async -> MigrationVisit = { .sync }

    /// THE PROVE SWEEP, run over every migrating account. Call on SYNC visits, once sync reaches
    /// the tip — never on a broadcast visit.
    ///
    /// This is what makes a sync-free SEND visit possible: proving is sync-bound, so if it were
    /// left to broadcast time every send session would have to sync first, which is exactly the
    /// correlation ZIP 318 forbids. Sweeping here means a due transfer is already proven when its
    /// window opens and the send session has nothing to do but submit.
    ///
    /// PER-ACCOUNT AND INSTRUCTION-TAKING (2026-08-07): the SDK's prove executor proves the rows
    /// the crank's own batch names, so this takes that account's batch and a phase-chosen
    /// `maxProofs` budget rather than sweeping the wallet with no payload.
    ///
    /// Returns the pass's `MigrationProveOutcome`: how many transactions were proved (0 is the
    /// normal case — a skipped row does not spend the budget), plus the txids of the PREPARATIONS
    /// among them. Those txids are the driver's handoff: a proved preparation is submitted by the
    /// app, the ordinary way (see `MigrationStepDriver`'s prove arm).
    var runProveSweep: @Sendable (AccountUUID, [MigrationProveTarget], Int) async -> MigrationProveOutcome
        = { _, _, _ in MigrationProveOutcome(totalProved: 0, preparationTxids: []) }

    /// THE BROADCAST SESSION — the other half of `visitKind() == .send`. Discharges the engine's
    /// `.broadcast` step headlessly, without the user ever navigating into the migration flow.
    ///
    /// With no background lane on iOS, an app-open IS the delivery window: if nothing drives the
    /// broadcast here, a scheduled transfer waits for the user to find the flow, and a schedule the
    /// user already confirmed silently stops advancing. This is what the retired BG task used to do.
    ///
    /// Broadcasts AT MOST ONE transfer per call (ZIP 318: a session carries one broadcast, and the
    /// engine's own contract for `.broadcast` is "broadcast it and end the session") — a second
    /// account with a due transfer waits for the next app-open.
    ///
    /// INSTRUCTION-TAKING (2026-08-07): it takes the account and the crank's own opaque
    /// `MigrationBroadcastInstruction`. There is no un-instructed entry point any more — the
    /// parameterless form used to crank a second time inside itself, which is exactly the
    /// double-read the SDK's single-crank contract removes.
    ///
    /// Returns true iff something was actually broadcast.
    var runBroadcastSession: @Sendable (AccountUUID, MigrationBroadcastInstruction, Bool) async -> Bool = { _, _, _ in false }

    /// The chain-time frame migration ETAs are measured in — see `MigrationChainClock`. Reads the
    /// SDK's estimated tip and measured block rate; degrades to the scanned tip and Zcash's target
    /// spacing. `nil` accountUUID resolves the selected account.
    var migrationChainClock: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationChainClock = { _ in .unknown }

    var stateEvents: @Sendable (_ accountUUID: AccountUUID?) -> AnyPublisher<MigrationState, Never> = { _ in Empty().eraseToAnyPublisher() }
    /// R13 Brick 1 — THE published snapshot channel (GROUND_RULES R13): one loader, one immutable
    /// value, every surface. Unlike `stateEvents` (a doorbell carrying only the coarse
    /// `MigrationState`, which every listener answered with its own query at its own time), this
    /// emits the full freshly-derived `MigrationViewSnapshot` whenever a WRITER commits — engine
    /// step done, sync finished, reconcile landed, broadcast edges — deduplicated on value
    /// equality, `nil` until the first derivation. Brick 2 moves every surface onto this and
    /// retires their private pulls; until then it runs beside them (same derivation, same values).
    var migrationSnapshotEvents: @Sendable (_ accountUUID: AccountUUID?) -> AnyPublisher<MigrationViewSnapshot?, Never> = { _ in Empty().eraseToAnyPublisher() }
    /// R13 Brick 2: the channel's last published value, synchronously — the status screen's
    /// first-frame prime (paint THE source before the subscription's first async emission lands).
    /// `nil` until the first build of this launch publishes.
    var currentMigrationSnapshot: @Sendable (_ accountUUID: AccountUUID?) -> MigrationViewSnapshot? = { _ in nil }
    /// R13 Brick 2: consumer-side refresh request — creates the account's channel if needed and
    /// kicks one coalesced rebuild. R3 in channel form: every open re-verifies; also the belt after
    /// a lane finishes (the lane's own pokes already republish — this guards the no-op exits).
    var refreshMigrationSnapshot: @Sendable (_ accountUUID: AccountUUID?) -> Void = { _ in }
    // Persistence (UserDefaults-backed; keys in SharedStateKeys.swift). MOB-1509: mode is
    // per-account (`nil` resolves the selected account) — concurrently migrating accounts choose
    // independently. (`isManualDelivery`/`setManualDelivery` removed 2026-08-07 with the whole
    // manual-tap send surface — Lukas: "send is driven only by .broadcast(id) next_step, never
    // waiting on manual tap"; the flag never had a production setter.)
    var migrationMode: @Sendable (_ accountUUID: AccountUUID?) -> MigrationMode?
    var setMigrationMode: @Sendable (_ accountUUID: AccountUUID?, _ mode: MigrationMode) -> Void
    // MOB-1496 (W4): ensure-or-read the run's atomic network snapshot (Tor + sync provider/endpoint +
    // broadcast provider/endpoint — see `MigrationNetworkSnapshot`) for `accountUUID` (`nil` resolves
    // the selected account, same convention as `migrationSummary`/`migrationTransfers` above), mapped
    // onto the SDK's `MigrationNetworkPrivacyOptions`. Idempotent for the life of a run: the first
    // call creates and persists the snapshot; every later call (from ANY lane, any elapsed time)
    // returns the SAME persisted values, immune to a mid-run auto server switch. NEVER throws — every
    // internal failure degrades to SOME snapshot (see `MigrationManagerImpl.ensureNetworkSnapshot`'s
    // doc). Default is the closed/no-Tor, unset-endpoint value — the macro requires a concrete
    // default for a non-throwing, non-`Void`/non-`Optional`-returning closure; every real call site
    // resolves a live snapshot. Tests never observe this default (see the `recordCommittedSchedule`
    // note).
    //
    // MOB-1497: by the time a broadcast reaches this member, `formNetworkSnapshot` below has almost
    // always already formed the run's (provisional or committed) snapshot at the Tor-choice step —
    // this ensure-or-create path is now mainly the safety net for a lane that reaches a broadcast
    // without ever forming one (see `MigrationManagerImpl.ensureNetworkSnapshot`'s doc).
    var migrationNetworkOptions: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationNetworkPrivacyOptions = { _ in
        MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "", port: 0))
    }
    // MOB-1497: forms (or, idempotently, returns the existing) provisional network snapshot for
    // `accountUUID` (`nil` resolves the selected account, same convention as `migrationNetworkOptions`
    // above) — called from the coordinator at the Tor-choice RESOLUTION points (the Tor sheet's
    // confirm, and the sheet-skipped app-wide-Tor-on shortcut, on both the immediate and scheduled
    // entry chains), never at plan-confirm or any re-entry path (a re-entry that never shows the Tor
    // step must not form — see `MigrationManagerImpl.ensureOrCreateNetworkSnapshot`'s doc for the
    // shared ensure-or-create body this and `migrationNetworkOptions`'s safety net both run through).
    // The formed snapshot is PROVISIONAL (`committedAt == nil`) until `markNetworkSnapshotCommitted`
    // stamps it. `= { _ in }` is a no-op default, not a test fallback (see the
    // `recordCommittedSchedule` note above).
    var formNetworkSnapshot: @Sendable (_ accountUUID: AccountUUID?) async -> Void = { _ in }
    // MOB-1497 (T2): read-only peek at `accountUUID`'s currently persisted network snapshot (`nil`
    // resolves the selected account, same convention as `migrationNetworkOptions` above) — unlike
    // `migrationNetworkOptions`/`formNetworkSnapshot`, this NEVER forms one; `nil` when none is
    // persisted yet. R13 needs the broadcast host ON the choice surface (the Tor sheet) and on the
    // sheet-skipped TransferPlan/ReviewTransfer footers — the coordinator reads this AFTER
    // `formNetworkSnapshot`/the skip branch has already formed one, to thread
    // `broadcastEndpoint.host`/`syncProvider` into that UI without re-deriving custom-server
    // classification itself. `= { _ in nil }` is a no-op default, not a test fallback (see the
    // `recordCommittedSchedule` note above).
    var networkSnapshot: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationNetworkSnapshot? = { _ in nil }
    // MOB-1497 (T2): the Tor sheet's confirm calls this INSTEAD OF `formNetworkSnapshot` — forming
    // now happens at sheet PRESENTATION (R13 needs the endpoint to exist when the sheet appears), so
    // by confirm time the user has already been shown a specific broadcast host; the run must use
    // exactly that host, never a fresh re-roll. Mutates ONLY `useTor` on the existing PROVISIONAL
    // snapshot — `broadcastEndpoint`/`syncEndpoint`/`takenAt` are left byte-for-byte untouched, and
    // nothing is re-formed. Storage-lock protected; a no-op (logged warning) when no provisional
    // snapshot exists for the account, or it's already committed — see
    // `MigrationSnapshotStorage.updateUseTorIfProvisional`. `= { _, _ in }` is a no-op default, not a
    // test fallback.
    var confirmProvisionalTorChoice: @Sendable (_ accountUUID: AccountUUID?, _ useTor: Bool) -> Void = { _, _ in }
    // MOB-1497: stamps `accountUUID`'s network snapshot committed (`nil` resolves the selected
    // account). Production has exactly ONE call site — inside `recordCommittedSchedule` itself,
    // co-located there so the two can never drift out of sync across `recordCommittedSchedule`'s
    // several external write points (software sign+store success, Keystone deferred store success,
    // dust commit) — see `MigrationManagerImpl.recordCommittedSchedule`'s doc. Also exposed as its
    // own member so tests can exercise the stamp directly. `= { _ in }` is a no-op default, not a
    // test fallback.
    var markNetworkSnapshotCommitted: @Sendable (_ accountUUID: AccountUUID?) -> Void = { _ in }
    // MOB-1497: discards `accountUUID`'s network snapshot (`nil` resolves the selected account) ONLY
    // while still PROVISIONAL (`committedAt == nil`) — a no-op against an already-committed snapshot.
    // Called at the migration flow's teardown (`RootCoordinator`'s `migrationCoordFlow` path-clearing
    // sites) so closing the flow without committing discards the provisional pick; a re-entry
    // re-forms and re-rolls. `= { _ in }` is a no-op default, not a test fallback.
    var clearProvisionalNetworkSnapshot: @Sendable (_ accountUUID: AccountUUID?) -> Void = { _ in }
    // MOB-1496 (W4): every persisted network snapshot across `walletAccounts` (+ the selected
    // account, defensively, deduped) — i.e. every account with a currently-active migration run.
    // Drives `AutoServerSelectionLiveKey`'s pinning (auto server selection stays within an active
    // run's sync-provider family) and `ServerSetupStore`'s manual-switch privacy warning.
    var activeNetworkSnapshots: @Sendable () -> [MigrationNetworkSnapshot] = { [] }
    // MOB-1497 (R7-T3 — failure routing, R14-R17): classifies + routes a broadcast failure for
    // `accountUUID` (`nil` resolves the selected account, same convention as `migrationNetworkOptions`
    // above). See `MigrationBroadcastFailureRoute`'s doc for what each outcome means to a caller, and
    // `MigrationManagerImpl.routeBroadcastFailure` for the full R14-R17 decision table. Performs the
    // R16 within-provider rotation itself when it returns `.retryRotated` — the ONE state change this
    // member may make (see `MigrationSnapshotStorage.rotateBroadcastEndpoint`'s doc) — every other
    // route makes no state change. `= { _, _ in .plainRetry }` is a required macro default (the return
    // type is non-throwing/non-Void/non-Optional), not a test fallback (see the
    // `recordCommittedSchedule` note above).
    var routeBroadcastFailure: @Sendable (
        _ accountUUID: AccountUUID?, _ failureClass: MigrationBroadcastFailureClass
    ) async -> MigrationBroadcastFailureRoute = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
    // MOB-1497 (R7 final review, Important-1 — spec §G): per-account read of the persisted Tor-hold
    // indicator `routeBroadcastFailure` maintains (see that member's doc and
    // `MigrationFailureRoutingStorage.torHoldActive`) — true iff the account's MOST RECENT broadcast
    // failure was a mid-run Tor hold (`.torHold`/R15), false for every other outcome, including a
    // landed broadcast or a first-run Tor choice. Consumed by the waiting/stalled surfaces
    // (`MigrationStatusStore`'s resume presentation, `SmartBanner`'s transfer-waiting variant via
    // `bannerVariant` above) so a Tor-caused stall is never silent. `nil` accountUUID resolves the
    // selected account, same convention as `migrationNetworkOptions` above. `= { _ in false }` is a
    // required macro default, not a test fallback (see the `recordCommittedSchedule` note above).
    var isMigrationTorHoldActive: @Sendable (_ accountUUID: AccountUUID?) -> Bool = { _ in false }

    /// GROUND_RULES R3: whether the CURRENT app-open's first engine verdict has been heard. The
    /// smart banner holds `.checkingStatus` (Figma 5679-8225) until this is `true` — the state
    /// ends on the verdict, never on a timer. Defaults `true` for the same reason as above.
    var isMigrationSessionVerdictKnown: @Sendable () -> Bool = { true }

    /// THE SINGLE DERIVATION of the migration view — see `MigrationViewSnapshot`. Every observer
    /// reads this; none of them derives its own.
    var migrationViewSnapshot: @Sendable (_ accountUUID: AccountUUID?) async -> MigrationViewSnapshot = { _ in .empty }
    // (Audit 2026-08-03, #16: the MOB-1497 T5/T6 "pending background Tor prompt" latch that lived
    // here was DELETED — its arm site (`RootInitialization.executeBroadcastAction`) never existed
    // in this codebase, its reader (`MigrationTorFailureSheet`) is never presented, and so the
    // latch could neither be set nor consumed. The surviving Tor-failure surface is
    // `isMigrationTorHoldActive` above, which `bannerVariant` renders as `.transferWaiting`.)
    // MOB-1497 (R7-T3, R14): the R11-warning-gated, doc-sanctioned exception to R4's run-immutability
    // for "Tor unavailable on the first broadcast of the run" — mutates ONLY `useTor` on `accountUUID`'s
    // (`nil` resolves the selected account) ACTIVE network snapshot (committed if one exists, else the
    // still-provisional one — R7-review fix, Important-1: the note-split lane's R14 choice can fire
    // against a still-provisional snapshot); endpoint/provider/takenAt/committedAt are left
    // byte-for-byte untouched. Only ever called with `useTor: false` in the shipped app (the user's
    // "proceed without Tor" choice after the R11 warning), but the parameter stays a `Bool` rather than
    // a fire-and-forget "turn it off" — see `MigrationSnapshotStorage`'s new mutation method for the
    // no-op-when-no-snapshot-at-all shape.
    // `= { _, _ in }` is a no-op default, not a test fallback.
    var overrideTorForRun: @Sendable (_ accountUUID: AccountUUID?, _ useTor: Bool) -> Void = { _, _ in }
    /// F#9 (MOB-1497 T5 completion): consumes the pending first-run Tor prompt WITHOUT changing
    /// the Tor choice — the "Cancel"/dismiss resolution of the Status screen's headless-routed
    /// `.torFirstRunChoice` sheet. The latch re-arms on the next failed attempt, so dismissal is
    /// never permanent silence. ("Proceed without Tor" is `overrideTorForRun(_, false)` above,
    /// which consumes the prompt itself.) Republishes the snapshot so every surface drops the
    /// prompt in the same pass.
    var resolveMigrationTorPrompt: @Sendable (_ accountUUID: AccountUUID?) async -> Void = { _ in }
    // MOB-1497 (R7-T3, R17): the consent-gated, doc-sanctioned sync-server fallback once every shipped
    // endpoint for the broadcast provider is unreachable — sets `accountUUID`'s (`nil` resolves the
    // selected account) ACTIVE network snapshot's (committed-else-provisional — same R7-review fix as
    // `overrideTorForRun` above) `broadcastEndpoint`/`broadcastProvider` to its OWN
    // `syncEndpoint`/`syncProvider`, and resets the R16 episode set (a fresh episode starts once the
    // user has consented to the fallback). Afterwards the snapshot is same-server by construction, so a
    // LATER endpoint-class failure takes `routeBroadcastFailure`'s same-server exemption naturally.
    // `= { _ in }` is a no-op default, not a test fallback.
    var overrideBroadcastEndpointToSyncServer: @Sendable (_ accountUUID: AccountUUID?) async -> Void = { _ in }
    // MOB-1497 (R9-T3, C1 fix): identity-custom classification for the account's CURRENTLY
    // CONFIGURED sync endpoint — the exact same classification `MigrationManagerImpl
    // .createNetworkSnapshot` computes internally when building a fresh snapshot, but with NO
    // snapshot storage read/write and no forming, so a caller can decide whether to persist + form
    // (non-custom) or detour straight to the sheet (custom) BEFORE either happens. This exists
    // because detecting via `formNetworkSnapshot` + a peek (the way the Tor sheet's own
    // presentation-time detection works) is unsafe for the flag-on skip branches:
    // `setNetworkPrivacyOptions` below must run BEFORE `formNetworkSnapshot` for the non-custom
    // outcome (see that member's doc — a later persist does not correct an already-formed
    // snapshot's baked-in `useTor`), so detection here must never form. `= { false }` (not custom)
    // is a DELIBERATE safe default (unlike most `= { ... }` defaults in this file, which exist only
    // because the macro requires a literal and production always overrides via `live()`) — an
    // unstubbed test or preview reads "not custom", matching the coordinator's own
    // `isIdentityCustom(nil)` nil-snapshot default and every existing non-custom flag-on test's
    // expectations without needing to know this member exists.
    var isSyncServerIdentityCustom: @Sendable () -> Bool = { false }
    // Persists the pre-run Tor choice the migration entry/Tor sheet writes. Consumed by
    // `ensureNetworkSnapshot`/`formNetworkSnapshot` when a run's snapshot is first taken — a later
    // call does NOT alter an already-active run's snapshot (see `MigrationNetworkSnapshot.useTor`'s
    // doc). MOB-1497 (R1): the READ side of this choice (`MigrationGateStorage
    // .isTorEnabledForMigration`) now defaults to `true`, not `false`, when never written.
    var setNetworkPrivacyOptions: @Sendable (_ useTor: Bool) -> Void
    // R8-T3 (S2): per-account now — a wallet-wide flag suppressed a SECOND account's own
    // completion banner/re-entry the moment the FIRST account acknowledged, made that account's
    // own `acknowledgeComplete` unreachable, and left its snapshot immortal. `nil` resolves the
    // selected account, same convention as `bannerVariant`/`migrationSummary` above.
    var isCompleteAcknowledged: @Sendable (_ accountUUID: AccountUUID?) -> Bool = { _ in false }
    // R8-T3 (V18): async now — reads `accountUUID`'s engine state fresh and NO-OPs (schedule +
    // snapshot INTACT, flag unset) unless it is exactly `.complete`. Pre-fix this was unconditional
    // and destructive: a close reached while the engine was still genuinely `.inProgress` wiped the
    // still-live run's own records.
    var acknowledgeComplete: @Sendable (_ accountUUID: AccountUUID?) async -> Void
    // MOB-1496: `MigrationState.complete` is now PER-RUN ("the stored run is fully mined"), never
    // "nothing left to migrate" — the final engine caps how much a single run covers (a per-run
    // cap, or funds arriving mid-run), so a `.complete` account may still have more to migrate.
    // Sync read of a persisted, per-account flag (`nil` resolves the selected account, same
    // convention as `isCompleteAcknowledged` above): `true` only when a completed evaluation found
    // a genuinely non-empty fresh plan; unevaluated (`nil`, internally) or a genuinely empty plan
    // both read as `false` here — this member never distinguishes the two. No public "evaluate"
    // member exists — the evaluation itself (a fresh, plan-cache-overwriting
    // `proposeMigrationTransfers`) is internal to `reconcile()`, and runs AT MOST ONCE per
    // completion transition (see `MigrationManagerImpl.evaluateMigrationRemainder`'s doc for why:
    // `proposeMigrationTransfers` overwrites the SDK's plan cache, and a later commit must match
    // the LATEST propose — evaluating on every reconcile could invalidate a plan the user is
    // mid-review of, turning its commit into a `migrationPlanStale` error). MOB-1513 (H3 guard):
    // that hazard is now actually guarded — see `setMigrationFlowPresented` below.
    var isMigrationRemainderPending: @Sendable (_ accountUUID: AccountUUID?) -> Bool = { _ in false }
    // MOB-1513 (H3 guard): "a propose-consuming migration screen is on screen for this account"
    // signal. `reconcile()`'s once-per-completion-transition remainder evaluation (see
    // `isMigrationRemainderPending`'s doc just above, and `MigrationManagerImpl
    // .evaluateMigrationRemainder`'s doc) SKIPS an account while this is `true`, rather than
    // overwriting the SDK's plan cache out from under a plan the user is mid-review of — e.g. the
    // "Migrate Anyway" residual flow, whose visibility is driven by `migrationSummary`'s own
    // independent residual read, not by `isMigrationRemainderPending`. A skip is never lost, only
    // delayed: the account stays in the once-per-transition gate's un-evaluated (`nil`) state, so a
    // LATER `reconcile()` pass — there are many call sites — retries once the flag clears.
    //
    // Set `true` by `MigrationCoordFlowCoordinator.onAppear` at genuine flow start
    // (`state.path.isEmpty`); set `false` by every production close/replace site for
    // `Root.State.Path.migrationCoordFlow` — see `MigrationManagerImpl
    // .presentedFlowAccountUUIDs`'s doc for the full, verified site list. In-memory only (never
    // persisted — a flow being on screen doesn't survive relaunch, and shouldn't). A `nil`
    // accountUUID is a no-op either direction: there is no account to key the signal to, and the
    // caller (a coordinator/Root close site) already resolved the concrete UUID it means before
    // calling — this member never itself falls back to the selected account, since doing so could
    // silently arm/disarm the WRONG account's signal during an in-flight account switch. `= { _, _
    // in }` is a no-op default, not a test fallback (see the `recordCommittedSchedule` note above)
    // — this is called from `MigrationCoordFlowCoordinator.onAppear`, reached by nearly every
    // coordinator test in the suite, and from several Root-level teardown sites.
    var setMigrationFlowPresented: @Sendable (_ accountUUID: AccountUUID?, _ isPresented: Bool) -> Void = { _, _ in }
    // MOB-1496 (W3): written once per completed sync from Root's existing sync-completion edge
    // (`RootInitialization.swift`'s `.synchronizerStateChanged`, the same place `reconcile()` fires
    // on the false->true transition into `.upToDate`) — NOT on every tick. `= { }` mirrors
    // `reconcile`'s no-op but is not a test fallback (see the `recordCommittedSchedule` note).
    var recordSyncCompleted: @Sendable () -> Void = { }
    // MOB-1496 (R8-T4, #3): app-side companion to the SDK's own `migrationSyncBlockedStream` — a
    // broadcast-failure call site that ran `stopSyncBeforeMigrationBroadcast()` without ever
    // reaching a successful broadcast calls `refreshMigrationSyncGate()` to manually re-push the
    // CURRENT gate value through this independent feed. The SDK's own stream only transitions on a
    // SUCCESSFUL broadcast and dedupes via `removeDuplicates()`, so a pre-broadcast throw or a
    // `.networkError`/`.invalidNote`/`.expired` result — which never flips the SDK's gate — would
    // otherwise leave `RootInitialization.swift`'s `.migrationSyncGateChanged` handler waiting for an
    // event that never arrives, stranding sync stopped all session. `migrationSyncGateFeed()` builds
    // a FRESH `AsyncStream` per call, retaining only the LATEST continuation (audit 2026-08-03, #9 —
    // this doc used to claim one long-lived shared stream, which the implementation never was): the
    // single subscriber is `.registerForSynchronizersUpdate`, whose `cancelInFlight` re-subscription
    // tears the old stream down before the new one registers. A nudge landing in that window is a
    // silent no-op against the dead continuation — which is why every fresh subscription SEEDS
    // itself with a live gate read at install, subsuming whatever a dropped nudge would have said.
    // `refreshMigrationSyncGate()` is a read+yield only: it does NOT acquire
    // `MigrationManagerSerialExecutor` (mutates nothing this class owns) and does NOT touch
    // `transactionGuard` (not a broadcast/server-switch).
    var migrationSyncGateFeed: @Sendable () -> AsyncStream<Bool> = { AsyncStream { _ in } }
    var refreshMigrationSyncGate: @Sendable () async -> Void = { }
    // Reconciliation. MOB-1496: async — re-reads `getMigrationState` for `stateEvents`; call sites in
    // `MigrationSendingStore`/`MigrationNoteSplitStore` (post-broadcast) join the launch/foreground
    // ones. `= { }` is a no-op default, not a test fallback (see the `recordCommittedSchedule` note).
    /// P4: arms exactly ONE generic poke for `accountUUID`, at the EARLIEST of four candidates —
    /// the engine's own sync/prove wake-ups, the earliest still-unsent row's window (preparation
    /// and transfer rows both), a near-term attention blocker, and the engine's own advance
    /// outlook (one step of lookahead from the same read that drove the session) — and cancels
    /// the account's poke once none of the four resolves to a date. Called on every driver pass
    /// (`.beforeSync`/`.afterSync`, and a substantive `.tick`) plus COMMIT and reconcile.
    ///
    /// The copy names neither an account nor a specific action: by the time the user opens, state
    /// may have moved, so naming one would be a promise the app might not keep.
    ///
    /// Re-arming is idempotent by construction: the id is stable per account, so a re-arm REPLACES
    /// the account's own prior pending request rather than stacking a second one.
    var armNextWindowNotifications: @Sendable (_ accountUUID: AccountUUID?) async -> Void = { _ in }
    /// MOB-1466 (Lukas, 2026-08-07): record that the user cancelled this account's run from
    /// Advanced Settings -> Restart Migration, so the state derivation reads the terminal run as
    /// "no run" and the banner re-offers migration for the remaining Orchard, instead of "Update
    /// migration plan".
    ///
    /// THE ONLY CALLER IS THE RESTART'S OWN CONFIRM. That is the false-positive guard: "we really
    /// only want to show migration required when I used restart migration in the advanced
    /// settings". A completed migration is protected by construction — see `MigrationState.derive`,
    /// where the all-mined case returns `.complete` without consulting this at all.
    var markRunCancelledByUser: @Sendable (_ accountUUID: AccountUUID?) async -> Void = { _ in }
    var reconcile: @Sendable () async -> Void = { }
    // R8-T3 (#9): clears `accountUUID`'s (`nil` resolves the selected account) network snapshot iff
    // its engine state is fresh `.notStarted` with no stored schedule payload — i.e. a confirm lane
    // that took a snapshot (every lane does, on the FIRST `migrationNetworkOptions` read, before any
    // store/broadcast) but was abandoned before ever committing. Otherwise a no-op. Called
    // fire-and-forget from the coordinator's `.flowFinished` handler. `= { _ in }` mirrors
    // `reconcile`'s no-op but is not a test fallback (see the `recordCommittedSchedule` note).
    var clearAbandonedNetworkSnapshot: @Sendable (_ accountUUID: AccountUUID?) async -> Void = { _ in }
    // Test-only utility: clears every persisted migration flag this client owns (mode, network
    // privacy, complete-acknowledged). Its former UI caller (the migration
    // simulator debug panel) was removed by MOB-1458; today it's exercised solely by
    // `MigrationManagerTests`/`MigrationFailureRoutingTests`. MOB-1496 (W-A): no longer includes
    // dust-locked — "Lock balance" is now a genuine SDK-side lock, not app-persisted state.
    /// MOB-1466 (N3): the WALLET-RESET wipe — cancels every scheduled migration notification
    /// and removes every persisted migration key. Distinct from `resetPersistedFlags` below,
    /// which is the narrow test-only flags reset. See `MigrationManagerImpl.wipeAllMigrationState`.
    var wipeAllMigrationState: @Sendable () async -> Void = { }
    var resetPersistedFlags: @Sendable () -> Void
}

enum MigrationReentryRoute: Equatable, Sendable {
    case recovery(isExpired: Bool)       // §4.3 row 1 — variant from MigrationAttentionReason (.transferExpired → true, else false)
    case statusResume                    // row 2
    case statusProgress                  // row 3 — also the split phase (MOB-1513 B4: the old row-5 `noteSplitProgress` route is retired with the "Splitting Funds" screen)
    case complete                        // row 4 (unacknowledged)
    // (row 6 `reviewManual` removed 2026-08-07 with the manual-delivery lane.)
    case entry                           // row 7 (notStarted)
}

// PHASE 2 RELOCATION: `MigrationBroadcastFailureRoute` was declared HERE in #1930. It now lives in
// `Models/Migration/MigrationBroadcastFailure.swift` alongside `MigrationBroadcastFailureClass` and
// the classifier that produces it — moved when Phase 2 needed the failure sheet without the manager.
// Deleted here rather than in the model file: a route is a model, not a dependency-client detail.
