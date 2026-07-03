//
//  MigrationCoordFlowStore.swift
//  Zashi
//
//  Coordinator for the Orchard -> Ironwood migration flow (MOB-1466). Chains the visual-only
//  migration screens (MOB-1460...1464) into a live, state-driven flow: re-entry routing, mode/
//  network-privacy persistence, permission-step sequencing, and the scheduled/manual/immediate
//  chaining table. `MigrationEntry` is the flow's root screen (mirroring `SendCoordFlow`'s
//  `sendFormState`); every other screen lives in `path`. Everything here runs against the inert
//  SDK stubs — it goes live when the real SDK (MOB-1455) fills them in.
//
//  MOB-1468 (Keystone) adds `keystoneSign`/`scan` path elements and `pendingKeystoneSigning`: the
//  three signing sources (NoteSplit/TransferPlan/ReviewTransfer) delegate `.keystoneSignRequested`
//  instead of signing locally, the coordinator routes through a QR sign/scan round-trip, then
//  resumes whichever chain the source represents. See `MigrationCoordFlowCoordinator.swift`'s
//  Keystone rows for the routing table.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationCoordFlow {
    /// MOB-1468 (Keystone): which signing source is awaiting/mid QR round-trip, so
    /// `scan(.foundPCZTBatch)` knows which chain to resume once the signed PCZTs come back.
    enum KeystoneSigningContext: Equatable {
        case noteSplit
        /// Fresh + re-created plans (`requiresSigning == true`) — the rescheduled variant never
        /// re-signs, so it never reaches this context.
        case planCommit
        case immediateReview
    }

    @Reducer(state: .equatable)
    enum Path {
        case backgroundDelivery(MigrationBackgroundDelivery)
        case complete(MigrationComplete)
        case keystoneSign(MigrationKeystoneSign)
        case networkPrivacy(MigrationNetworkPrivacy)
        case noteSplit(MigrationNoteSplit)
        case notifications(MigrationNotifications)
        case recovery(MigrationRecovery)
        case reviewTransfer(MigrationReviewTransfer)
        case scan(Scan)
        case scheduled(MigrationScheduled)
        case sending(MigrationSending)
        case status(MigrationStatus)
        case transferPlan(MigrationTransferPlan)
    }

    @ObservableState
    struct State: Equatable {
        var path = StackState<Path.State>()
        var entryState = MigrationEntry.State()
        /// Persisted via `manager.setMigrationMode` once chosen; held here too so later hops in
        /// the same run (e.g. immediate's Tor-skip) don't need to re-read the dependency.
        var mode: MigrationMode?
        /// Held here once confirmed on the Network Privacy screen (or defaulted when S5 is
        /// skipped) so Sending's coordinator-configured state can inject it.
        var networkPrivacyOptions = NetworkPrivacyOptions(useTor: false, submissionEndpoint: nil)
        /// MOB-1468 (Keystone): set when a `.keystoneSignRequested` delegate pushes `keystoneSign`,
        /// cleared once the QR round-trip resolves (either resumed via `foundPCZTBatch` or backed
        /// out via `.rejected`).
        var pendingKeystoneSigning: KeystoneSigningContext?

        init() { }
    }

    /// Result of the async permission-step helper (`nextPermissionStepPathState()`): the screen
    /// to push (`nil` once every permission step is satisfied and the flow can proceed straight to
    /// the plan/review screen the caller already knows to push), plus whether Network Privacy (S5)
    /// was skipped because the app-wide Tor setup flag is already on — in which case the
    /// coordinator force-sets `networkPrivacyOptions.useTor = true` before proceeding.
    struct PermissionStepResult: Equatable {
        var pathState: Path.State?
        var forcedUseTor = false
    }

    enum Action {
        case entry(MigrationEntry.Action)
        case flowFinished
        case onAppear
        case path(StackActionOf<Path>)
        /// Internal: the async re-entry/permission-step helper resolved the next screen to push
        /// (or `nil` when nothing needs appending — the `.entry` re-entry route).
        case pushNextPermissionStep(PermissionStepResult)
        /// Internal: a fresh `MigrationStatus.State` (already hydrated) to push — used by Sending's
        /// manual-first-transfer close (no `.status` beneath yet). A dedicated case (rather than
        /// reusing `pushHydratedPathState`) so its `isFlowRoot: false` (mid-flow push) stays
        /// visibly distinct in the reducer from the re-entry root's `isFlowRoot: true` status push.
        case pushHydratedStatus(MigrationStatus.State)
        /// Internal: a fresh `Path.State` (already hydrated) to push — used by Status `.sendNow`'s
        /// overdue-batch Sending screen, Status `.reschedule`'s rescheduled plan, and Recovery
        /// `.recreate`'s re-created plan.
        case pushHydratedPathState(Path.State)
        /// Internal: sendNow's Sending screen finished (`.closed`) — refresh the `.status` element
        /// beneath with freshly-read rows and pop back to it.
        case sendNowCompleted(rows: [MigrationTransferRow])
        /// Internal: MOB-1468 Keystone `scan(.foundPCZTBatch)` finished submitting (noteSplit) or
        /// storing (planCommit/immediateReview) the signed PCZTs — pops `scan`+`keystoneSign` and
        /// resumes the chain `context` represents. `result` carries the noteSplit broadcast outcome
        /// (mirrors the software `.splitResult` handling) and `signedPczt` the PCZT that was
        /// submitted (so the mutated `noteSplit` element can hold it for `retryTapped`); both `nil`
        /// for the other two contexts, whose `storeSignedMigrationTransactions` call returns `Void`.
        case keystoneSigningSubmitted(context: KeystoneSigningContext, result: TransferResult?, signedPczt: Pczt?)
        /// Internal: MOB-1468 `keystoneSign(.delegate(.rejected))`'s pop, deferred to a follow-up
        /// self-action for the same reason `sendNowCompleted` defers its pop — popping the
        /// `keystoneSign` element inline in the `.path(.element(...))` case would race
        /// `.forEach(\.path, action:)`'s delivery of that same action to the (then-missing) element.
        case keystoneSignRejected
        /// Internal: an empty scanned batch abandons the signing session — pops BOTH the `scan`
        /// and `keystoneSign` elements back to the initiating screen (deferred like
        /// `keystoneSignRejected`, since `scan` is the acting element) and clears the context.
        case keystoneScanAbandoned
    }

    @Dependency(\.migrationBGScheduler) var migrationBGScheduler
    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userNotifications) var userNotifications
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        coordinatorReduce()

        Scope(state: \.entryState, action: \.entry) {
            MigrationEntry()
        }

        Reduce { _, _ in .none }
            .forEach(\.path, action: \.path)
    }
}
