//
//  MigrationManagerInterface.swift
//  Zashi
//
//  App-owned logic for the Orchard -> Ironwood migration (MOB-1466): persistence, the
//  sync<->send privacy gate's app-owned half (MOB-1496 W3 — see `sendGate` below), and the
//  banner-variant / re-entry-route derivations. The SDK only exposes raw state (`MigrationState`,
//  `MigrationProgress`, …) — this client is the single place that turns that state plus app-side
//  flags into what the UI actually shows.
//
//  MOB-1497 (T5): adds the per-account "pending background Tor prompt" latch
//  (`isPendingBackgroundTorPrompt`/`setPendingBackgroundTorPrompt`) — armed only by the background
//  broadcast lane when a broadcast fails on a Tor-class route, read on foreground by T6.
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
    // Per-account migration-state stream (MOB-1496: relocated from SDKSynchronizerClient's
    // `migrationStateStream`) — emits on `reconcile()` and whenever a store reports a completed
    // migration op. `nil` accountUUID resolves the selected account internally.
    var stateEvents: @Sendable (_ accountUUID: AccountUUID?) -> AnyPublisher<MigrationState, Never> = { _ in Empty().eraseToAnyPublisher() }
    // Persistence (UserDefaults-backed; keys in SharedStateKeys.swift). MOB-1509: mode and manual
    // delivery are per-account (`nil` resolves the selected account) — concurrently migrating
    // accounts choose independently.
    var migrationMode: @Sendable (_ accountUUID: AccountUUID?) -> MigrationMode?
    var setMigrationMode: @Sendable (_ accountUUID: AccountUUID?, _ mode: MigrationMode) -> Void
    var isManualDelivery: @Sendable (_ accountUUID: AccountUUID?) -> Bool = { _ in false }
    var setManualDelivery: @Sendable (_ accountUUID: AccountUUID?, _ isManual: Bool) -> Void
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
    // MOB-1497 (T5): per-account persisted "a BACKGROUND migration broadcast attempt failed on a
    // Tor-class route (R14 `.torFirstRunChoice` / R15 `.torHold`), and the user hasn't yet been shown
    // the resulting prompt" latch. UNLIKE `isMigrationTorHoldActive` above (a non-sticky reflection of
    // the last route that `routeBroadcastFailure` maintains on EVERY lane), this is a STICKY,
    // BACKGROUND-ONLY flag: armed solely by the background broadcast lane
    // (`RootInitialization.executeBroadcastAction`) — foreground broadcast failures have their own
    // on-screen failure UI and must never arm it. Read on app foreground by T6 to present the
    // "Couldn't Connect to Tor" sheet over Home. Cleared on any landed broadcast and at run
    // teardown/completion (alongside the Tor-hold indicator — see `MigrationFailureRoutingStorage
    // .markHadBroadcast`/`.clear`), and explicitly by T6 on user resolution via
    // `setPendingBackgroundTorPrompt` below. The account is always concrete here (the BG lane's winner,
    // T6's per-account read), so — unlike `isMigrationTorHoldActive` — there is NO `nil`-resolves-
    // selected convention. `= { _ in false }` is a required macro default (non-throwing, non-Void
    // return), not a test fallback (see the `recordCommittedSchedule` note above).
    var isPendingBackgroundTorPrompt: @Sendable (_ accountUUID: AccountUUID) -> Bool = { _ in false }
    // MOB-1497 (T5): sets (`isPending: true`, only ever from the background lane's Tor-class chokepoint)
    // or clears (`isPending: false`, T6's user-resolution path) the latch above. `async` for T6's call
    // site even though the underlying write is a synchronous `UserDefaults` store. No explicit default —
    // a Void-returning closure the macro can synthesize one for (mirrors `acknowledgeComplete`/
    // `setManualDelivery`).
    var setPendingBackgroundTorPrompt: @Sendable (_ accountUUID: AccountUUID, _ isPending: Bool) async -> Void
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
    // Sync<->send gate (app direction: a completed sync briefly disables migration sends). MOB-1496
    // (W3): re-keyed off observed sync completions + the SDK's own buffer duration — the OTHER
    // direction (broadcast briefly disables sync) is now enforced by the SDK itself
    // (`SDKSynchronizerClient.isMigrationSyncBlocked`/`migrationSyncBlockedStream`); this client no
    // longer duplicates it.
    var sendGate: @Sendable () async -> MigrationSendGate = { .allowed }
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
    // event that never arrives, stranding sync stopped all session. `migrationSyncGateFeed()` returns
    // the SAME long-lived stream on every call (a fresh `AsyncStream` per subscriber would each get
    // their own continuation and miss each other's pushes) — subscribed exactly once, alongside the
    // SDK's own stream, in `.registerForSynchronizersUpdate`. `refreshMigrationSyncGate()` is a
    // read+yield only: it does NOT acquire `MigrationManagerSerialExecutor` (mutates nothing this
    // class owns) and does NOT touch `transactionGuard` (not a broadcast/server-switch).
    var migrationSyncGateFeed: @Sendable () -> AsyncStream<Bool> = { AsyncStream { _ in } }
    var refreshMigrationSyncGate: @Sendable () async -> Void = { }
    // Reconciliation. MOB-1496: async — re-reads `getMigrationState` for `stateEvents`; call sites in
    // `MigrationSendingStore`/`MigrationNoteSplitStore` (post-broadcast) join the launch/foreground
    // ones. `= { }` is a no-op default, not a test fallback (see the `recordCommittedSchedule` note).
    var reconcile: @Sendable () async -> Void = { }
    // R8-T3 (#9): clears `accountUUID`'s (`nil` resolves the selected account) network snapshot iff
    // its engine state is fresh `.notStarted` with no stored schedule payload — i.e. a confirm lane
    // that took a snapshot (every lane does, on the FIRST `migrationNetworkOptions` read, before any
    // store/broadcast) but was abandoned before ever committing. Otherwise a no-op. Called
    // fire-and-forget from the coordinator's `.flowFinished` handler. `= { _ in }` mirrors
    // `reconcile`'s no-op but is not a test fallback (see the `recordCommittedSchedule` note).
    var clearAbandonedNetworkSnapshot: @Sendable (_ accountUUID: AccountUUID?) async -> Void = { _ in }
    // Debug/testnet-only: clears every persisted migration flag this client owns (mode, manual
    // delivery, network privacy, complete-acknowledged). MOB-1496 (W-A): no longer
    // includes dust-locked — "Lock balance" is now a genuine SDK-side lock, not app-persisted state.
    var resetPersistedFlags: @Sendable () -> Void
}

enum MigrationSendGate: Equatable, Sendable {
    case allowed
    // MOB-1496 (W3): `sdkSynchronizer.isSyncing()` == true right now — CTA disabled.
    case syncRequired
    // MOB-1496 (W3): a sync completed < `migrationPrivacySyncBufferDuration()` ago — CTA disabled,
    // `Date` is when the gate clears (sync-completion timestamp + buffer).
    case waitUntil(Date)
}

enum MigrationReentryRoute: Equatable, Sendable {
    case recovery(isExpired: Bool)       // §4.3 row 1 — variant from MigrationAttentionReason (.transferExpired → true, else false)
    case statusResume                    // row 2
    case statusProgress                  // row 3 — also the split phase (MOB-1513 B4: the old row-5 `noteSplitProgress` route is retired with the "Splitting Funds" screen)
    case complete                        // row 4 (unacknowledged)
    case reviewManual(step: Int, total: Int)  // row 6 — manual delivery, next transfer due
    case entry                           // row 7 (notStarted)
}

/// MOB-1497 (R7-T3 — failure routing): the outcome `MigrationManagerClient.routeBroadcastFailure`
/// returns for a classified broadcast failure — which failure-routing surface (R14-R17) a foreground
/// store should present, or (background) that a route was resolved at all (background maps every
/// route to re-arm-only — see `RootInitialization.executeBroadcastAction`). See
/// `MigrationManagerImpl.routeBroadcastFailure`'s doc for the full decision table.
///
/// R7 final review, Important-1 (spec §G): every call ALSO persists whether this route is `.torHold`
/// into the account's Tor-hold indicator (`MigrationFailureRoutingStorage.torHoldActive`) — the
/// "No [snapshot/episode] state change" notes below are about the network snapshot/episode only; the
/// indicator update happens on every route, every lane, unconditionally.
enum MigrationBroadcastFailureRoute: Equatable, Sendable {
    /// R14: Tor was unavailable on the FIRST broadcast attempt of the run (no prior landed
    /// broadcast) — offer the choice to retry (keeping Tor), proceed without it (subject to the R11
    /// warning), or cancel. No snapshot/episode state change.
    case torFirstRunChoice
    /// R15: Tor was unavailable MID-run (at least one broadcast already landed this run) — hold and
    /// retry; never an implicit clearnet opt-out. No snapshot/episode state change; this IS the one
    /// route that sets the Tor-hold indicator (see the enum's own doc above).
    case torHold
    /// R16: the broadcast endpoint was unreachable and a same-provider rotation to an untried
    /// endpoint was just performed — retry re-executes against the newly-rotated endpoint. Presents
    /// the SAME generic failure sheet as `.plainRetry` (the rotation itself is silent).
    case retryRotated
    /// R16's same-server exemption (identity-custom sync server, or the defensive same-server
    /// fallback — testnet or no other built-in provider), or the defensive no-active-snapshot
    /// fallback: nothing to rotate to, so R17 can never fire either. Presents the plain existing
    /// failure sheet, unchanged. No state change, no episode tracking.
    case plainRetry
    /// R17: every shipped endpoint for the broadcast provider has been tried this episode — offer
    /// the consent-gated sync-server fallback. `torEnabled` (the active snapshot's `useTor` —
    /// committed if one exists, else the still-provisional one) selects which R17 warning copy
    /// applies.
    case providerExhausted(torEnabled: Bool)
}
