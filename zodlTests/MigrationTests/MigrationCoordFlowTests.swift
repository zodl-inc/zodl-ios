//
//  MigrationCoordFlowTests.swift
//  zodlTests
//
//  Covers `MigrationCoordFlow` (Features/CoordFlows/MigrationCoordFlow{Store,Coordinator}.swift)
//  for MOB-1466: re-entry routing (`.onAppear`), the chaining table from Entry through Complete
//  for all three modes (immediate/scheduled/manual), the permission-step helper's skip logic,
//  sendNow/reschedule/recovery orchestration, and every flow-root close path's `.flowFinished`
//  emission. Also covers MOB-1468's Keystone signing round-trip: each of the two remaining signing
//  sources' `.keystoneSignRequested` delegate sets `pendingKeystoneSigning` and pushes
//  `keystoneSign`; `keystoneSign(.delegate(.getSignature))` pushes `scan` configured with the
//  migration batch checker; `scan(.foundPCZTBatch)` stores the signed PCZTs, pops `scan`+
//  `keystoneSign`, and resumes the matching chain (plan post-confirm / immediate sending) — verified
//  with order-asserting spies; `.rejected` pops back to the signing source with its state intact and
//  clears the context; the no-partial-storage invariant (reject, or an empty scanned batch, never
//  calls store).
//
//  MOB-1478 reshapes the scheduled entry chain and adds the Tor bottom sheet:
//  - W2/W3: Entry (immediate) originally gated on the same `walletStorage.exportTorSetupFlag()`
//    check the old Network Privacy screen used, before either pushing straight through (flag set)
//    or presenting the coordinator-owned Tor sheet (flag unset) and stashing the pending
//    destination; "Got it" and swipe-dismissal (`torSheetPresentationChanged(false)`) both persist +
//    resume identically. How This Works (scheduled) gates the same way again since MOB-1494
//    (round 4, below).
//  - W4: note splitting no longer gates or appears in forward routing at all — `MigrationNoteSplit`
//    is re-entry-only, and its old Keystone signing context folded into `TransferPlan`'s batch (a
//    signed-PCZT array can now be longer when the split was needed, but the coordinator still treats
//    it as one opaque atomic batch either way).
//  - W7: reschedule lands `.rescheduleCompleted` on the SAME status element instead of pushing a
//    fresh `TransferPlan`.
//  - W8: the Notifications variant now reaches `.manual` when delivery is manual (was previously
//    unreachable).
//  - W10: the Keystone scan push sets `instructions`/`forceLibraryToHide`.
//
//  MOB-1487 (round 3) briefly made the scheduled/private path route Tor unconditionally (no sheet);
//  its lasting piece is the persist-fix: every lane persists `useTor` so background sends read the
//  same value — the immediate flag-on shortcut's persist is covered by
//  `entryChoseImmediateWithTorFlagOnSkipsTorSheetAndPushesReview`.
//
//  MOB-1494 (round 4): the revised canvas re-adds the Tor toggle sheet on the scheduled path — How
//  This Works gates on the same `walletStorage.exportTorSetupFlag()` check as Entry (immediate),
//  stashing `PendingTorDestination.permissionChain` (re-added); the sheet's toggle defaults ON and
//  its body copy splits by path (`usesFullBalanceCopy` on the immediate destination only). Covered
//  by `howItWorksContinuedWithTorFlagOnSkipsSheetPersistsAndProceeds`,
//  `howItWorksContinuedWithTorFlagOffPresentsTorSheetAndStashesPermissionChain`, and
//  `torSheetGotItInScheduledModeResumesPermissionChainAndPushesTransferPlan`.
//
//  `.serialized`: every `MigrationCoordFlow.State()` carries a `MigrationEntry.State` (`entryState`),
//  which reads the process-global `@Shared(.inMemory(.selectedWalletAccount))` on init — matching the
//  precedent in `MigrationEntryTests`, which mutates the same key directly.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct MigrationCoordFlowTests {
    /// MOB-1496: the real per-account SDK surface needs a concrete `AccountUUID` for nearly every
    /// migration call the coordinator makes. Swift Testing instantiates a fresh `struct` per
    /// `@Test`, so this `init()` acts as a per-test setup hook — every test below gets a selected
    /// software account without needing to stash one itself (none of these tests are Keystone-
    /// vendor-specific; that branching is covered in `MigrationTransferPlanTests`/
    /// `MigrationReviewTransferTests` instead).
    init() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.defaultAccount }
    }

    private static let defaultAccount = WalletAccount(
        Account(
            id: AccountUUID(id: [UInt8](repeating: 1, count: 16)),
            name: "Zodl",
            keySource: nil,
            seedFingerprint: nil,
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    )

    /// MOB-1496 (W6): `migrationManager.migrationNetworkOptions(_:)` has no macro default (unlike the
    /// SDK synchronizer's `.noOp`) — any test that reaches the note-split-broadcast or dust-execute
    /// branch must mock it explicitly or trip `unimplemented`. Same fixture shape as
    /// `MigrationTransferPlanTests`/`SimulatedSDKSynchronizerTests`.
    private static let defaultNetworkPrivacyOptions = MigrationNetworkPrivacyOptions(
        useTor: false,
        submissionEndpoint: LightWalletEndpoint(address: "", port: 0)
    )

    /// MOB-1496 (W6): the dust-lane vendor fork (`.complete(.delegate(.migrateAnyway))`) is decided
    /// IN the coordinator, so — unlike the rest of this file's tests (per the doc above) — the dust
    /// lane's Keystone-vendor tests need their own account fixture. Same shape as
    /// `MigrationTransferPlanTests`/`MigrationSendingTests`' `walletAccount(keystone:idByte:)`.
    private func walletAccount(keystone: Bool, idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: keystone ? "Keystone" : "Zodl",
                keySource: keystone ? String(localizable: .accountsKeystone).lowercased() : nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// MOB-1497 (T2): a PROVIDER `MigrationNetworkSnapshot` fixture for `migrationManager
    /// .networkSnapshot` stubs — sync on `.zecRocks`, broadcast on `.stardust` at `host`, matching
    /// T1's cross-provider pairing (R6).
    private static func someProviderNetworkSnapshot(host: String = "eu.zec.stardust.rest") -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: false,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "na.zec.rocks", port: 443, secure: true),
            syncProvider: ServerProvider.zecRocks,
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 443, secure: true),
            broadcastProvider: ServerProvider.stardust,
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// MOB-1497 (T2): an identity-CUSTOM `MigrationNetworkSnapshot` fixture — sync and broadcast on
    /// the SAME custom host (R2/R6: no separation possible), `useTor` forced false (T1's data-side R2).
    private static func someCustomNetworkSnapshot(host: String = "custom.example.org") -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: false,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 9067, secure: true),
            syncProvider: ServerProvider.custom(host: host),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 9067, secure: true),
            broadcastProvider: ServerProvider.custom(host: host),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// R7-T2 fix-wave 1 (Important-1): a same-server NON-custom `MigrationNetworkSnapshot` fixture —
    /// sync AND broadcast on the SAME `.zecRocks` host, matching what
    /// `MigrationManagerLiveKey.createNetworkSnapshot`'s empty-candidates branch actually produces for
    /// testnet (single shipped endpoint) and the defensive no-other-family fallback. NOT
    /// identity-custom (`syncProvider`/`broadcastProvider` are both `.zecRocks`, never `.custom`) yet
    /// still shares one server end to end — the exact matrix cell the pre-fix `isIdentityCustom` gate
    /// missed for R13's disclosure.
    private static func someSameServerProviderNetworkSnapshot(host: String = "testnet.zec.rocks") -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: false,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 443, secure: true),
            syncProvider: ServerProvider.zecRocks,
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 443, secure: true),
            broadcastProvider: ServerProvider.zecRocks,
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Re-entry: .onAppear with empty path

    @MainActor @Test func onAppearWithEntryRouteAppendsNothing() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .entry }
        }

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        #expect(store.state.path.isEmpty)
    }

    @MainActor @Test func onAppearWithStatusProgressRouteAppendsFlowRootStatusScreen() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi.zero,
            dust: Zatoshi.zero,
            transfersSent: 0,
            transfersTotal: 1,
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .statusProgress }
            $0.sdkSynchronizer = .noOp
            // MOB-1496 (W3 review fix C): a non-10-minute value (900s = 15 min) so a field left at
            // its zero default (the "about 0 mins" footer-flash regression) would visibly fail.
            $0.sdkSynchronizer.migrationPrivacySyncBufferDuration = { 900 }
            $0.migrationManager.migrationTransfers = { _ in rows }
            $0.migrationManager.migrationSummary = { _ in summary }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        #expect(store.state.path.count == 1)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status as the only path element")
            return
        }
        #expect(statusState.presentation == MigrationStatus.State.Presentation.progress)
        #expect(statusState.isFlowRoot == true)
        #expect(statusState.rows == IdentifiedArrayOf(uniqueElements: rows))
        #expect(statusState.totalDurationHours == 24)
        #expect(statusState.syncPrivacyBufferMinutes == 15)
    }

    @MainActor @Test func onAppearWithRecoveryNotExpiredRouteAppendsFlowRootRecoveryScreen() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .invalid, hoursFromNow: 0),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(1_000), status: .invalid, hoursFromNow: 0)
        ]
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .recovery(isExpired: false) }
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in rows }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .recovery(recoveryState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .recovery on the path")
            return
        }
        #expect(recoveryState.reason == MigrationRecovery.State.Reason.notesSpent)
        #expect(recoveryState.isFlowRoot == true)
        #expect(recoveryState.firstTransfer == 2)
        #expect(recoveryState.lastTransfer == 3)
    }

    @MainActor @Test func onAppearWithRecoveryExpiredRouteAppendsFlowRootRecoveryScreenWithExpiredReason() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .recovery(isExpired: true) }
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in [] }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .recovery(recoveryState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .recovery on the path")
            return
        }
        #expect(recoveryState.reason == MigrationRecovery.State.Reason.expired)
        #expect(recoveryState.isFlowRoot == true)
    }

    @MainActor @Test func onAppearWithStatusResumeRouteAppendsFlowRootStatusScreenInResumePresentation() async {
        // R8-T5 (#13): `hoursFromNow: 0` here is the REAL value `MigrationDerivations.transferRows`
        // always produces for the first non-sent (= stalled) row — `nonSentPosition × 6`, `0` BY
        // CONSTRUCTION — no longer meaningful for `stalledHoursAgo` (see below); this fixture used to
        // hand-pick `5` here directly, which happened to mask the bug this row's real construction
        // has (the mock bypassed the real derivation entirely).
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi.zero,
            dust: Zatoshi.zero,
            transfersSent: 1,
            transfersTotal: 2,
            estimatedDurationHours: 24
        )
        // R8-T5 review (Important-1): `stalledHoursAgo` now derives from a BLOCK DELTA against the
        // LIVE tip (`latestState().latestBlockHeight`), not `estimateTimestamp` (checkpoint-snapped —
        // see `liveStalledHoursAgo`'s doc). `nextExecutableAfterHeight` below is 100; a tip 240
        // blocks ahead (340) is EXACTLY 5 hours at 75s/block (240 × 75 ÷ 3600 = 5). Red against HEAD
        // (pre-fix): HEAD ignores `latestState` entirely and calls `estimateTimestamp` (no longer
        // mocked here, so it resolves to `.noOp`'s `nil` default), so this assertion would read the
        // fallback `0`, not `5`.
        let tipState: SynchronizerState = {
            var state = SynchronizerState.zero
            state.latestBlockHeight = 340
            return state
        }()
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .statusResume }
            // `latestState` is a non-`@DependencyClient` `let` field (no per-field override) — replace
            // the whole client via `.mocked(...)` (same defaults as `.noOp` for every other field, per
            // `RootMigrationBackgroundTests`' identical precedent), then layer the `var` overrides below.
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(latestState: { tipState })
            // MOB-1496 (W3 review fix C): a non-10-minute value (900s = 15 min) so a field left at
            // its zero default (the "about 0 mins" footer-flash regression, Minor-1) would visibly
            // fail — `.resume` is the only presentation that renders the footer.
            $0.sdkSynchronizer.migrationPrivacySyncBufferDuration = { 900 }
            $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in
                MigrationTransferProposal(id: "1", amount: Zatoshi(1_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            }
            $0.migrationManager.migrationTransfers = { _ in rows }
            $0.migrationManager.migrationSummary = { _ in summary }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status on the path")
            return
        }
        #expect(statusState.presentation == MigrationStatus.State.Presentation.resume)
        #expect(statusState.isFlowRoot == true)
        #expect(statusState.stalledNumber == 2)
        #expect(statusState.stalledHoursAgo == 5)
        // R8-T6: due-ness alone governs the CTA now — row "1" is `.overdue`, so it's enabled
        // regardless of the gate (no longer consulted by this hydration path at all).
        #expect(statusState.isSendNowDisabled == false)
        #expect(statusState.syncPrivacyBufferMinutes == 15)
    }

    /// R8-T5 review (Important-1): a pre-first-sync tip (`latestState().latestBlockHeight == 0`,
    /// `SynchronizerState.zero`'s own default — before the very first server round-trip) is an
    /// UNKNOWN tip, not a low one (same fail-safe-sentinel idiom as
    /// `MigrationManagerLiveKey.isIronwoodActivated()`), so `liveStalledHoursAgo` must guard on it
    /// explicitly and fall back to `0` rather than compute a meaningless block delta against it —
    /// even though a live proposal DID resolve (the probe is still exercised; only the tip is
    /// unknown).
    @MainActor @Test func onAppearWithStatusResumeRouteAndZeroTipHasZeroStalledHoursAgo() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi.zero,
            dust: Zatoshi.zero,
            transfersSent: 1,
            transfersTotal: 2,
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .statusResume }
            // `.noOp`'s `latestState` already defaults to `.zero` (tip 0, pre-first-sync) — exactly
            // the case under test, so no override is needed here.
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in
                MigrationTransferProposal(id: "1", amount: Zatoshi(1_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            }
            $0.migrationManager.migrationTransfers = { _ in rows }
            $0.migrationManager.migrationSummary = { _ in summary }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status on the path")
            return
        }
        #expect(statusState.stalledHoursAgo == 0)
    }

    /// R8-T5 (#13): when there's no stalled (overdue) row at all, `stalledHoursAgo` must stay `0`
    /// without even attempting the live probe — guards the fix's `hasStalledRow` short-circuit.
    @MainActor @Test func onAppearWithStatusResumeRouteAndNoStalledRowHasZeroStalledHoursAgo() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi.zero,
            dust: Zatoshi.zero,
            transfersSent: 1,
            transfersTotal: 2,
            estimatedDurationHours: 24
        )
        let probeCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .statusResume }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.migrationPrivacySyncBufferDuration = { 900 }
            $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in
                probeCalls.withValue { $0 += 1 }
                return MigrationTransferProposal(id: "1", amount: Zatoshi(1_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            }
            $0.migrationManager.migrationTransfers = { _ in rows }
            $0.migrationManager.migrationSummary = { _ in summary }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status on the path")
            return
        }
        #expect(statusState.stalledHoursAgo == 0)
        #expect(probeCalls.withValue { $0 } == 0)
    }

    @MainActor @Test func onAppearWithCompleteRouteAppendsFlowRootCompleteScreen() async {
        let summary = MigrationSummary(
            transferred: Zatoshi(1_245_800_000),
            dust: Zatoshi(31_000),
            transfersSent: 5,
            transfersTotal: 5,
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .complete }
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationSummary = { _ in summary }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .complete(completeState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .complete on the path")
            return
        }
        #expect(completeState.isFlowRoot == true)
        #expect(completeState.totalTransferred == Zatoshi(1_245_800_000))
        #expect(completeState.dust == Zatoshi(31_000))
        #expect(completeState.transfersSent == 5)
        #expect(completeState.transfersTotal == 5)
        #expect(completeState.durationHours == 24)
    }

    // MOB-1487: a previously locked dust remainder re-enters on the locked confirmation instead
    // of re-offering resolution — `completeState(isFlowRoot:)` reads `isMigrationDustLocked()` and
    // pins `dustResolution` to `.locked` (nil otherwise, letting `MigrationComplete.State`'s own
    // init derive offered/none from `dust`).
    @MainActor @Test func onAppearWithCompleteRouteAndLockedDustDerivesLockedDustResolution() async {
        let summary = MigrationSummary(
            transferred: Zatoshi(1_245_800_000),
            dust: Zatoshi(800_000),
            transfersSent: 5,
            transfersTotal: 5,
            estimatedDurationHours: 24
        )
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .complete }
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationSummary = { _ in summary }
            $0.migrationManager.isMigrationDustLocked = { true }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .complete(completeState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .complete on the path")
            return
        }
        #expect(completeState.dustResolution == MigrationComplete.State.DustResolution.locked)
    }

    @MainActor @Test func onAppearWithNoteSplitProgressRouteAppendsFlowRootSplittingScreen() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .noteSplitProgress }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .noteSplit on the path")
            return
        }
        #expect(noteSplitState.phase == MigrationNoteSplit.State.Phase.splitting)
        #expect(noteSplitState.isFlowRoot == true)
    }

    @MainActor @Test func onAppearWithReviewManualRouteAppendsFlowRootManualStepReviewScreen() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(2_000), status: .active, hoursFromNow: 0)
        ]
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .reviewManual(step: 2, total: 5) }
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in rows }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer on the path")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.manualStep(number: 2, total: 5))
        #expect(reviewState.isFlowRoot == true)
        #expect(reviewState.amount == Zatoshi(2_000))
        #expect(reviewState.fee == Zatoshi(100_000))
    }

    // MARK: - Immediate flow (§6.1): Tor sheet gate

    @MainActor @Test func entryChoseImmediateWithTorFlagOnSkipsTorSheetAndPushesReview() async {
        let setMigrationModeCalls = LockIsolated<[MigrationMode]>([])
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let formNetworkSnapshotCalls = LockIsolated<[AccountUUID?]>([])
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { mode in setMigrationModeCalls.withValue { $0.append(mode) } }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { accountUUID in formNetworkSnapshotCalls.withValue { $0.append(accountUUID) } }
            // MOB-1497 (T2): the skip branch now also reads the just-formed snapshot back (via the
            // non-forming peek) to hydrate the pushed Review Transfer's R13 disclosure footer.
            $0.migrationManager.networkSnapshot = { _ in Self.someProviderNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        // MOB-1497 (T2): the skip branch's push is now dispatched from inside the forming/hydration
        // effect (`.pushHydratedPathState`), not appended inline — must be received for the effect's
        // state mutation to apply, same as `recoveryRecreateCallsRestartAndPushesRecreatedPlanWithInjectedSchedule`'s
        // identically-shaped dispatch.
        await store.receive(\.pushHydratedPathState)

        #expect(store.state.mode == MigrationMode.immediate)
        #expect(setMigrationModeCalls.value == [MigrationMode.immediate])
        // MOB-1496: `selectMigrationMode` had no real-SDK counterpart — `setMigrationMode` above is
        // the only mode-setting call now (see `SDKSynchronizerClient+Simulated.swift`'s doc).
        // MOB-1487 (round 3): the flag-on shortcut now also persists — previously only the sheet's
        // own confirm did (a pre-existing gap; a background send reads the persisted copy, not this
        // in-memory state). MOB-1496 (W4): the coordinator no longer materializes/stashes
        // `MigrationNetworkPrivacyOptions` at all — the migration network snapshot's execute-time
        // read (`migrationManager.migrationNetworkOptions(_:)`) is the authoritative source now; the
        // persisted `useTor` choice below is what feeds it.
        #expect(setOptionsCalls.value == [true])
        #expect(store.state.isTorSheetPresented == false)
        // MOB-1497 (T1): the flag-on shortcut is a Tor-choice RESOLUTION point exactly like the
        // sheet's own confirm — it forms the run's (provisional) network snapshot here too. (T2:
        // unchanged trigger point — there's no sheet on this branch, so forming stays here.)
        #expect(formNetworkSnapshotCalls.value.count == 1)
        #expect(formNetworkSnapshotCalls.value.first == Self.defaultAccount.id)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer on the path (Tor sheet skipped)")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.immediate)
        // MOB-1497 (T2, R13): sheet-skipped provider users never see the sheet's own disclosure
        // line — this screen's footer carries it instead.
        #expect(reviewState.broadcastDisclosureHost == "eu.zec.stardust.rest")
    }

    /// MOB-1497 (T2, R13 skip-path footer): the custom-server twin of the test above — no
    /// disclosure line for a custom user (their server IS the sync server), even on the skip path.
    @MainActor @Test func entryChoseImmediateWithTorFlagOnAndCustomServerSkipBranchFooterCarriesNoHost() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.migrationManager.setNetworkPrivacyOptions = { _ in }
            $0.migrationManager.formNetworkSnapshot = { _ in }
            $0.migrationManager.networkSnapshot = { _ in Self.someCustomNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.pushHydratedPathState)

        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer on the path (Tor sheet skipped)")
            return
        }
        #expect(reviewState.broadcastDisclosureHost == nil)
    }

    @MainActor @Test func entryChoseImmediateWithTorFlagOffPresentsTorSheetAndStashesReviewDestination() async {
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            $0.migrationManager.networkSnapshot = { _ in Self.someProviderNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        // MOB-1497 (T2): presentation is now the async `torSheetState` helper, dispatched via
        // `torSheetStateReady` — must be received for its state writes (torSheetState/
        // pendingTorDestination/isTorSheetPresented) to apply.
        await store.receive(\.torSheetStateReady)

        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.pendingTorDestination == MigrationCoordFlow.PendingTorDestination.reviewTransfer)
        // MOB-1494 (round 4): the sheet presents with the toggle defaulted ON and the immediate
        // path's "your full balance" body variant.
        #expect(store.state.torSheetState.isTorOn == true)
        #expect(store.state.torSheetState.usesFullBalanceCopy == true)
        // MOB-1497 (T2, R13): provider — the toggle sheet variant, hydrated with the formed host.
        #expect(store.state.torSheetState.isCustomServer == false)
        #expect(store.state.torSheetState.broadcastHost == "eu.zec.stardust.rest")
        // Nothing pushed yet — the sheet gates the push until confirmed/dismissed.
        #expect(store.state.path.isEmpty)
        // MOB-1497 (T2): forming moves to PRESENTATION — R13 needs the endpoint to exist on the
        // choice surface the moment it appears, so this is no longer 0.
        #expect(formNetworkSnapshotCalls.value == 1)
    }

    /// MOB-1497 (T2, R2/R12 variant matrix — immediate/"full" path): identity-custom presents the
    /// no-toggle unavailable variant instead of the toggle sheet.
    @MainActor @Test func entryChoseImmediateWithTorFlagOffAndCustomServerPresentsUnavailableVariant() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.migrationManager.formNetworkSnapshot = { _ in }
            $0.migrationManager.networkSnapshot = { _ in Self.someCustomNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.torSheetStateReady)

        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.torSheetState.isCustomServer == true)
        #expect(store.state.torSheetState.broadcastHost == "custom.example.org")
        // T1's data-side R2: forced false — no toggle exists to draw ON here either.
        #expect(store.state.torSheetState.isTorOn == false)
        #expect(store.state.torSheetState.usesFullBalanceCopy == true)
    }

    /// R7-T2 fix-wave 1 (Important-1, RED-FIRST PIN 1): testnet / the defensive same-server fallback
    /// classify as a normal provider (`isCustomServer == false` — NOT identity-custom) yet still
    /// share one server end to end (`broadcastProvider == syncProvider`). Before the fix, the sheet's
    /// disclosure line rendered anyway (gated on `isCustomServer` alone), printing a false "different
    /// server" claim. Must keep the TOGGLE variant (unlike identity-custom) while suppressing only
    /// the disclosure line.
    @MainActor @Test func entryChoseImmediateWithTorFlagOffAndSameServerNonCustomPresentsToggleVariantWithoutDisclosure() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.migrationManager.formNetworkSnapshot = { _ in }
            $0.migrationManager.networkSnapshot = { _ in Self.someSameServerProviderNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.torSheetStateReady)

        #expect(store.state.isTorSheetPresented == true)
        // Still the TOGGLE variant — same-server non-custom is NOT identity-custom.
        #expect(store.state.torSheetState.isCustomServer == false)
        #expect(store.state.torSheetState.isTorOn == true)
        // The actual pin: no disclosure for a same-server user, even though they're a provider.
        #expect(store.state.torSheetState.showsBroadcastDisclosure == false)
    }

    /// MOB-1497 (T2): a second presentation re-forms (T1's reform-when-provisional rule) and must
    /// thread whatever THAT fresh roll produced — not silently keep showing the first roll's host.
    /// Re-triggers presentation directly (no intervening confirm) — `.entry(.chose(.immediate))`
    /// re-presents unconditionally regardless of whether a sheet is already up, which is exactly
    /// what re-entering Entry and picking immediate again would do after backing out.
    @MainActor @Test func presentingTorSheetASecondTimeReRollsTheHostObservableInState() async {
        let snapshotCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.migrationManager.formNetworkSnapshot = { _ in }
            $0.migrationManager.networkSnapshot = { _ in
                let call = snapshotCalls.withValue {
                    $0 += 1
                    return $0
                }
                return call == 1
                    ? Self.someProviderNetworkSnapshot(host: "eu.zec.stardust.rest")
                    : Self.someProviderNetworkSnapshot(host: "us.zec.stardust.rest")
            }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.torSheetStateReady)
        #expect(store.state.torSheetState.broadcastHost == "eu.zec.stardust.rest")

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.torSheetStateReady)

        #expect(store.state.torSheetState.broadcastHost == "us.zec.stardust.rest")
        #expect(store.state.torSheetState.broadcastHost != "eu.zec.stardust.rest")
    }

    // MARK: - Tor bottom sheet (MOB-1478 W2): "Got it" and swipe-dismiss resume the stashed destination

    @MainActor @Test func torSheetGotItInImmediateModePersistsOptionsAndPushesReviewTransfer() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let formNetworkSnapshotCalls = LockIsolated<[AccountUUID?]>([])
        let confirmProvisionalCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: true, broadcastHost: "eu.zec.stardust.rest")
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { accountUUID in formNetworkSnapshotCalls.withValue { $0.append(accountUUID) } }
            $0.migrationManager.confirmProvisionalTorChoice = { accountUUID, useTor in
                confirmProvisionalCalls.withValue { $0.append((accountUUID, useTor)) }
            }
        }
        store.exhaustivity = .off

        await store.send(.torSheet(.delegate(.gotIt)))
        await store.finish()

        #expect(setOptionsCalls.value == [true])
        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        // MOB-1497 (T2): confirm-must-not-re-roll — presentation already formed the snapshot the
        // user was shown; confirm calls `confirmProvisionalTorChoice` instead of forming again.
        #expect(formNetworkSnapshotCalls.value.isEmpty)
        #expect(confirmProvisionalCalls.value.count == 1)
        #expect(confirmProvisionalCalls.value.first?.0 == Self.defaultAccount.id)
        #expect(confirmProvisionalCalls.value.first?.1 == true)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.immediate)
        // MOB-1497 (T2, R13): read straight off the sheet's own (just-resolved) state — no re-read.
        #expect(reviewState.broadcastDisclosureHost == "eu.zec.stardust.rest")
    }

    /// MOB-1497 (T2, R2/R12 variant matrix — "forced-false preserved through confirm"): the
    /// identity-custom "Got it" (single acknowledge CTA, §2 of the brief) persists `setNetworkPrivacyOptions`
    /// unconditionally (unchanged) but must NOT call `confirmProvisionalTorChoice` — there is no
    /// toggle value to persist that way, and R2 already forced the formed snapshot's `useTor` false.
    @MainActor @Test func torSheetGotItForCustomServerDoesNotCallConfirmProvisionalTorChoice() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let confirmProvisionalCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: false, isCustomServer: true, broadcastHost: "custom.example.org")
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.confirmProvisionalTorChoice = { _, _ in confirmProvisionalCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.torSheet(.delegate(.gotIt)))
        await store.finish()

        #expect(setOptionsCalls.value == [false])
        #expect(confirmProvisionalCalls.value == 0)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top")
            return
        }
        // No disclosure for a custom user — their server IS the sync server (R13 doesn't apply).
        #expect(reviewState.broadcastDisclosureHost == nil)
    }

    /// R7-T2 fix-wave 1 (Important-1, RED-FIRST PIN 2a): the same-server-non-custom twin of the
    /// custom test above, driven through `confirmTorSheet`'s `.reviewTransfer` case — the footer must
    /// carry no disclosure host either, even though this IS a provider confirm
    /// (`confirmProvisionalTorChoice` still runs, unlike the identity-custom case — only the
    /// disclosure is suppressed, nothing else about provider handling changes).
    @MainActor @Test func torSheetGotItForSameServerNonCustomFooterCarriesNoDisclosureHost() async {
        let confirmProvisionalCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(
            isTorOn: true,
            broadcastHost: "testnet.zec.rocks",
            showsBroadcastDisclosure: false
        )
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { _ in }
            $0.migrationManager.confirmProvisionalTorChoice = { _, _ in confirmProvisionalCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.torSheet(.delegate(.gotIt)))
        await store.finish()

        // Not identity-custom — the choice still persists like any provider confirm.
        #expect(confirmProvisionalCalls.value == 1)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top")
            return
        }
        #expect(reviewState.broadcastDisclosureHost == nil)
    }

    /// MOB-1497 (T2, R3/R11 swipe-dismiss decision): a swipe with the toggle ON keeps the sheet's
    /// EXISTING semantics unchanged — persists and resumes exactly like "Got it" would. (The
    /// hazardous OFF combination is covered separately below — see `torSheetPresentationChanged`'s
    /// doc for why only that ONE combination changes behavior.)
    @MainActor @Test func torSheetSwipeDismissWithToggleOnInImmediateModePersistsOptionsAndPushesReviewTransfer() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        let confirmProvisionalCalls = LockIsolated<[Bool]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: true)
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            $0.migrationManager.confirmProvisionalTorChoice = { _, useTor in confirmProvisionalCalls.withValue { $0.append(useTor) } }
        }
        store.exhaustivity = .off

        await store.send(.torSheetPresentationChanged(false))
        await store.finish()

        #expect(setOptionsCalls.value == [true])
        #expect(confirmProvisionalCalls.value == [true])
        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        // MOB-1497 (T2): confirm never forms, swipe or not.
        #expect(formNetworkSnapshotCalls.value == 0)
        guard case .reviewTransfer = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top (swipe-dismiss == Got it, toggle ON)")
            return
        }
    }

    /// MOB-1497 (T2, R3/R11 swipe-dismiss decision — the minimal-change fix): a swipe with the
    /// toggle showing OFF on a PROVIDER sheet carries no warning-alert confirmation — persisting
    /// that OFF choice would be exactly the unwarned opt-out R3 forbids. Treated as a full cancel:
    /// nothing persisted, nothing pushed, the sheet just closes.
    @MainActor @Test func torSheetSwipeDismissWithToggleOffInImmediateModeDoesNotPersistOrAdvance() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let confirmProvisionalCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: false)
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.confirmProvisionalTorChoice = { _, _ in confirmProvisionalCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.torSheetPresentationChanged(false))
        await store.finish()

        #expect(setOptionsCalls.value.isEmpty)
        #expect(confirmProvisionalCalls.value == 0)
        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        #expect(store.state.path.isEmpty)
    }

    /// MOB-1497 (T2, R3/R11 swipe-dismiss decision): the identity-custom twin of the ON case above —
    /// R12's disclosure already stood in for the warning, so a custom swipe keeps the existing
    /// persist-and-resume semantics too (nothing to warn about; `confirmProvisionalTorChoice` is
    /// still skipped, same as an explicit custom "Got it").
    @MainActor @Test func torSheetSwipeDismissForCustomServerPersistsAndAdvancesWithoutConfirmProvisionalCall() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let confirmProvisionalCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: false, isCustomServer: true, broadcastHost: "custom.example.org")
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.confirmProvisionalTorChoice = { _, _ in confirmProvisionalCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.torSheetPresentationChanged(false))
        await store.finish()

        #expect(setOptionsCalls.value == [false])
        #expect(confirmProvisionalCalls.value == 0)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top (identity-custom swipe still advances)")
            return
        }
        #expect(reviewState.broadcastDisclosureHost == nil)
    }

    @MainActor @Test func torSheetGotItInScheduledModeResumesPermissionChainAndPushesTransferPlan() async {
        // MOB-1494 (round 4): the scheduled lane hosts the sheet again — its confirm persists
        // whatever the toggle shows (default ON) and resumes the permission chain (all permissions
        // satisfied here, so the plan screen pushes directly).
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        let confirmProvisionalCalls = LockIsolated<[Bool]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        state.torSheetState = MigrationTorSheet.State(broadcastHost: "us.zec.stardust.rest")
        state.isTorSheetPresented = true
        state.pendingTorDestination = .permissionChain
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            $0.migrationManager.confirmProvisionalTorChoice = { _, useTor in confirmProvisionalCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.isManualDelivery = { false }
            $0.migrationManager.networkSnapshot = { _ in Self.someProviderNetworkSnapshot(host: "us.zec.stardust.rest") }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.torSheet(.delegate(.gotIt)))
        await store.receive(\.pushNextPermissionStep)

        #expect(setOptionsCalls.value == [true])
        #expect(confirmProvisionalCalls.value == [true])
        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        // MOB-1497 (T2): confirm never forms — presentation already did, earlier.
        #expect(formNetworkSnapshotCalls.value == 0)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (permission chain resumed from the sheet)")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
        #expect(planState.broadcastDisclosureHost == "us.zec.stardust.rest")
    }

    /// R7-T2 fix-wave 1 (Important-1, RED-FIRST PIN 2b): the TransferPlan-footer twin of the pin
    /// above — same same-server fixture, reached via the scheduled lane's permission-chain resume
    /// (`nextPermissionStepResult`'s `.transferPlan` branch, driven by the shared
    /// `broadcastDisclosureHost` helper). Must also carry no disclosure host.
    @MainActor @Test func torSheetGotItInScheduledModeForSameServerNonCustomTransferPlanFooterCarriesNoDisclosureHost() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        state.torSheetState = MigrationTorSheet.State(broadcastHost: "testnet.zec.rocks", showsBroadcastDisclosure: false)
        state.isTorSheetPresented = true
        state.pendingTorDestination = .permissionChain
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { _ in }
            $0.migrationManager.formNetworkSnapshot = { _ in }
            $0.migrationManager.confirmProvisionalTorChoice = { _, _ in }
            $0.migrationManager.isManualDelivery = { false }
            $0.migrationManager.networkSnapshot = { _ in Self.someSameServerProviderNetworkSnapshot() }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.torSheet(.delegate(.gotIt)))
        await store.receive(\.pushNextPermissionStep)

        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (permission chain resumed from the sheet)")
            return
        }
        #expect(planState.broadcastDisclosureHost == nil)
    }

    @MainActor @Test func torSheetPresentationChangedToFalseWithNothingPendingIsANoOp() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        }

        await store.send(.torSheetPresentationChanged(false))
    }

    @MainActor @Test func manualDeliveryFreshPlanUsesManualVariant() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.notifications(MigrationNotifications.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { true }
            // MOB-1497 (T2): every fresh `.transferPlan` construction reads the (non-forming) R13
            // disclosure peek now — see `nextPermissionStepResult`'s doc.
            $0.migrationManager.networkSnapshot = { _ in nil }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .notifications(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed on top")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.manual)
    }

    @MainActor @Test func reviewTransferConfirmedPushesSending() async {
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.confirmed)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top")
            return
        }
        // MOB-1496 (W4): `MigrationSending` no longer carries a coordinator-injected options field —
        // its own effect reads `migrationManager.migrationNetworkOptions(_:)` AT EXECUTE TIME
        // instead (covered by `MigrationSendingTests`' lane-wiring tests).
        #expect(sendingState.totalCount == 1)
    }

    // MARK: - MOB-1468: Keystone signing — signRequested sets context + pushes keystoneSign

    @MainActor @Test func transferPlanKeystoneSignRequestedSetsPlanCommitContextAndPushesKeystoneSign() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        let pczts: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.keystoneSignRequested(pczts))))))

        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.planCommit)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        #expect(signState.pczts == pczts)
    }

    @MainActor @Test func reviewTransferKeystoneSignRequestedSetsImmediateReviewContextAndPushesKeystoneSign() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        let pczts: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xCC]))]
        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.keystoneSignRequested(pczts))))))

        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.immediateReview)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        #expect(signState.pczts == pczts)
    }

    // MARK: - MOB-1468/1478 (W10): Keystone signing — getSignature pushes scan configured for migration

    @MainActor @Test func keystoneSignGetSignaturePushesScanConfiguredWithMigrationBatchCheckerAndScanConfig() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.getSignature)))))

        guard case let .scan(scanState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scan pushed on top")
            return
        }
        #expect(scanState.checkers == [.keystoneMigrationBatchScanChecker])
        #expect(scanState.instructions == String(localizable: .migrationKeystoneScanInstructions))
        #expect(scanState.forceLibraryToHide == true)
    }

    // MARK: - MOB-1468: Keystone signing — foundPCZTBatch resumes planCommit (shared post-confirm chain)

    @MainActor @Test func foundPCZTBatchForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant() async {
        let callOrder = LockIsolated<[String]>([])
        // MOB-1496: `signed` (from `.scan(.foundPCZTBatch)`) is raw bytes in scan order — the
        // coordinator zips them against the ORIGINAL unsigned batch's ids (still on the
        // `keystoneSign` element beneath `scan`) to rebuild `[MigrationSignedTransferPczt]`.
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        let signed: [Data] = [Data([0xAA, 0x01]), Data([0xBB, 0x01])]
        let expectedStored: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA, 0x01])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0xBB, 0x01]))
        ]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                #expect(stored == expectedStored)
                callOrder.withValue { $0.append("store") }
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { callOrder.withValue { $0.append("scheduleFirstWindow") } }
            // MOB-1496 (W2): a successful store now also reconciles — explicit no-op override
            // since swift-dependencies requires `migrationManager` to be customized at least once
            // before any of its members can run in a test context (this fixture's `.transferPlan`
            // carries no `.schedule`, so `recordCommittedSchedule` itself is never reached).
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(callOrder.value == ["store", "scheduleFirstWindow"])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed on top of the retained .transferPlan element")
            return
        }
        guard case .transferPlan = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .transferPlan retained at the bottom (never re-signs again)")
            return
        }
    }

    // MOB-1496 (W2): the Keystone store-success write point — `recordCommittedSchedule` reads the
    // schedule off the `.transferPlan` element still beneath `keystoneSign`+`scan` at store time
    // (before `resumeAfterKeystoneSigning` pops back up to it), and `reconcile()` runs alongside.
    @MainActor @Test func foundPCZTBatchForPlanCommitContextRecordsCommittedScheduleAndReconciles() async {
        let recordCommittedScheduleCalls = LockIsolated<[(AccountUUID?, MigrationSchedule)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))]
        let signed: [Data] = [Data([0xAA, 0x01])]
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24
        )
        var planState = MigrationTransferPlan.State(variant: .scheduled)
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(planState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.recordCommittedSchedule = { accountUUID, schedule in
                recordCommittedScheduleCalls.withValue { $0.append((accountUUID, schedule)) }
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(recordCommittedScheduleCalls.value.count == 1)
        #expect(recordCommittedScheduleCalls.value.first?.0 == Self.defaultAccount.id)
        #expect(recordCommittedScheduleCalls.value.first?.1 == schedule)
        #expect(reconcileCalls.value == 1)
    }

    /// [MOB-1496] R8-T2 (#5): a store failure (`storeSignedMigrationTransactions` throws) must not
    /// persist the schedule NOR report success — the pre-fix coordinator discarded the thrown error
    /// into a bare `Bool` (`(try? await ...) != nil`) and fired `.keystoneSigningSubmitted` (->
    /// terminal "Migration Scheduled" screen, `scheduleFirstWindow()`) UNCONDITIONALLY regardless,
    /// with nothing stored in the engine and no schedule recorded. This now abandons the session
    /// instead (same `keystoneScanAbandoned` semantics as a re-pair failure or a split-store
    /// failure) — see `MigrationCoordFlowCoordinator.storeKeystoneSignedBatch`'s doc for why
    /// `MigrationNoteSplit`'s store-only retry affordance was investigated and rejected as the reuse
    /// target for this, the no-split case.
    @MainActor @Test func foundPCZTBatchForPlanCommitContextAbandonsSessionWithoutSubmittingWhenStoreFails() async {
        struct StoreFailure: Error { }
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let reconcileCalls = LockIsolated<Int>(0)
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))]
        let signed: [Data] = [Data([0xAA, 0x01])]
        var planState = MigrationTransferPlan.State(variant: .scheduled)
        planState.schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(1), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 1
        )
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(planState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in throw StoreFailure() }
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(recordCommittedScheduleCalls.value == 0)
        #expect(reconcileCalls.value == 0)
        #expect(scheduleFirstWindowCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed) — an honest failure, not a false 'Migration Scheduled'")
            return
        }
    }

    /// [MOB-1496] R8-T2 (#5-b): same fix, through the simulator-only bypass — proves it lives in the
    /// shared `storeKeystoneSignedBatch` helper both callers use, not just the real round-trip. Never
    /// pushes `.scan`, so only 1 element (`keystoneSign`) unwinds — mirrors
    /// `keystoneSignSimulateSignatureWithSplitStoreFailureAbandonsSessionWithoutScanPopped`'s pop-count
    /// proof for the split-store-failure branch.
    @MainActor @Test func keystoneSignSimulateSignatureAbandonsSessionWithoutSubmittingWhenStoreFails() async {
        struct StoreFailure: Error { }
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let reconcileCalls = LockIsolated<Int>(0)
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(
            .keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))]))
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in throw StoreFailure() }
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.simulateSignature)))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(recordCommittedScheduleCalls.value == 0)
        #expect(reconcileCalls.value == 0)
        #expect(scheduleFirstWindowCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (keystoneSign removed, no .scan was ever pushed)")
            return
        }
    }

    // MARK: - MOB-1496 (W6 §1): Keystone signing — foundPCZTBatch splits the note-split sentinel out
    //
    // The latent real-SDK break these fix: `storeSignedMigrationSchedulePCZTs` is all-or-nothing and
    // keyed by engine-issued transfer ids — a `"note-split"` sentinel is not an engine id, so the
    // real engine would reject the WHOLE store if it rode along (the pre-W6 behavior these tests
    // replace). The sentinel now gets split out and routed to the dedicated note-split broadcast lane
    // instead — see `MigrationCoordFlowCoordinator.resumeAfterKeystoneSigning`'s doc.

    @MainActor @Test func foundPCZTBatchWithNoteSplitSentinelStoresOnlyEngineIdPairs() async {
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        let signed: [Data] = [Data([0x01, 0x99]), Data([0xAA, 0x99]), Data([0xBB, 0x99])]
        // The sentinel entry must NOT appear here — only the schedule's own engine-id pairs.
        let expectedStored: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA, 0x99])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0xBB, 0x99]))
        ]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in MigrationTransferResult.success(txId: "split-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.path) // dispatched .noteSplit(.retryTapped)
        await store.receive(\.path) // .noteSplit(.splitResult(.success)) — the broadcast landed
        // MOB-1496 (C-1b fix, fix-wave 2): `storeSignedMigrationTransactions` is no longer called
        // inline in the batch-commit effect — it is DEFERRED until here, driven by the broadcast
        // succeeding above.
        await store.receive(\.path) // .noteSplit(.splitBroadcastSucceeded)
        await store.receive(\.path) // .noteSplit(.delegate(.storeScheduleRequested))
        await store.receive(\.path) // .noteSplit(.splitConfirmed) — the deferred store succeeded

        #expect(storeCalls.value == [expectedStored])
    }

    /// MOB-1496 (final engine, plural preps): coverage 1 — a real ceremony batch can carry N > 1
    /// preparation entries (the final engine builds N preparation transactions, not one split
    /// transaction). Three sentinel-prefixed preps interleaved with two schedule entries must all
    /// route to `storeSignedNoteSplits` as one 3-element array, ids stripped back to their bare engine
    /// form, while the two schedule entries reach the (deferred) `storeSignedMigrationTransactions`
    /// store untouched — twin of `foundPCZTBatchWithNoteSplitSentinelStoresOnlyEngineIdPairs` above,
    /// generalized from N=1 to N=3 preps.
    @MainActor @Test func foundPCZTBatchWithMultipleNoteSplitPrepsStoresAllOfThemAsOneArrayAndScheduleSeparately() async {
        let storeScheduleCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let storePrepsCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "note-split#p1", pczt: Data([0x02])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB])),
            MigrationUnsignedTransferPczt(id: "note-split#p2", pczt: Data([0x03]))
        ]
        let signed: [Data] = [
            Data([0x01, 0x99]), Data([0xAA, 0x99]), Data([0x02, 0x99]), Data([0xBB, 0x99]), Data([0x03, 0x99])
        ]
        let expectedPreps: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "p0", pczt: Data([0x01, 0x99])),
            MigrationSignedTransferPczt(id: "p1", pczt: Data([0x02, 0x99])),
            MigrationSignedTransferPczt(id: "p2", pczt: Data([0x03, 0x99]))
        ]
        let expectedSchedule: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA, 0x99])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0xBB, 0x99]))
        ]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, signed in
                storePrepsCalls.withValue { $0.append(signed) }
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeScheduleCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in MigrationTransferResult.success(txId: "split-tx") }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.path) // dispatched .noteSplit(.retryTapped)
        await store.receive(\.path) // .noteSplit(.splitResult(.success)) — the broadcast landed
        await store.receive(\.path) // .noteSplit(.splitBroadcastSucceeded)
        await store.receive(\.path) // .noteSplit(.delegate(.storeScheduleRequested))
        await store.receive(\.path) // .noteSplit(.splitConfirmed) — the deferred store succeeded

        #expect(storePrepsCalls.value == [expectedPreps])
        #expect(storeScheduleCalls.value == [expectedSchedule])
    }

    /// "via the note-split lane": the coordinator routes the signed split PCZT into a freshly pushed
    /// `MigrationNoteSplit` screen the SAME way its existing Keystone resubmit lane
    /// (`resubmitSignedNoteSplit`) receives one. MOB-1496 (C-1 fix, final review R6): the coordinator
    /// itself calls `storeSignedNoteSplits` with the signed bytes (BEFORE the schedule store — see the
    /// order-pin test below); the pushed screen's `splitStored: true` then means its automatically
    /// dispatched `.retryTapped` only ever broadcasts (`broadcastStoredNoteSplit`, which no longer
    /// takes the pczt bytes at all — the store already consumed them).
    @MainActor @Test func foundPCZTBatchWithNoteSplitSentinelRoutesSignedSplitPcztToNoteSplitScreenAndBroadcastsIt() async {
        let storeSignedCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let broadcastCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))
        ]
        let signed: [Data] = [Data([0x01, 0x99]), Data([0xAA, 0x99])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, signed in
                storeSignedCalls.withValue { $0.append(signed) }
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                broadcastCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "split-tx")
            }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.path) // dispatched .noteSplit(.retryTapped)
        await store.receive(\.path) // .noteSplit(.splitResult(.success))
        await store.receive(\.path) // .noteSplit(.splitBroadcastSucceeded)
        await store.receive(\.path) // .noteSplit(.delegate(.storeScheduleRequested))
        await store.receive(\.path) // .noteSplit(.splitConfirmed) — the deferred store succeeded

        #expect(storeSignedCalls.value == [[MigrationSignedTransferPczt(id: "p0", pczt: Data([0x01, 0x99]))]])
        #expect(broadcastCalls.value == 1)
        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .noteSplit pushed on top of the retained .transferPlan element")
            return
        }
        #expect(noteSplitState.isFlowRoot == false)
        guard case .transferPlan = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .transferPlan retained at the bottom (never re-signs again)")
            return
        }
    }

    /// THE C-1/C-1b PIN (final review R6, fix-wave 2): the split must store before it broadcasts, and
    /// the schedule must store only AFTER that broadcast succeeds. Two engine hazards, closed by one
    /// order: (C-1, historical — see `SDKSynchronizerInterface`'s doc for the final engine's corrected
    /// account: the run is actually created earlier, at PCZT-build time, not by this store) storing
    /// the schedule first would let the split's later store shadow it with a second, newer run.
    /// (C-1b, fix-wave 2, still in force) even with the split stored first, storing the schedule
    /// BEFORE the split broadcasts is still unsafe: the split's broadcast-success
    /// record (`record_transfer_result`, `context.rs:1299-1303`) UNCONDITIONALLY overwrites the run's
    /// phase, clobbering the schedule store's `BroadcastScheduled` the instant the broadcast lands —
    /// the run then parks at `.readyToPropose` forever once the split mines (`context.rs:361-378`),
    /// stranding the schedule. This test is RED against wave 1's C-1-only fix (recorded in the fix-wave
    /// 2 report: broadcast landed LAST, after the schedule was already stored) and GREEN against the
    /// full fix: split store, split BROADCAST, schedule store, then the persisted schedule is recorded
    /// — strictly in that order.
    @MainActor @Test func foundPCZTBatchWithNoteSplitSentinelStoresSplitBeforeScheduleBeforeRecordingCommittedSchedule() async {
        let callOrder = LockIsolated<[String]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))
        ]
        let signed: [Data] = [Data([0x01, 0x99]), Data([0xAA, 0x99])]
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24
        )
        var planState = MigrationTransferPlan.State(variant: .scheduled)
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(planState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in callOrder.withValue { $0.append("storeSignedNoteSplits") } }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in
                callOrder.withValue { $0.append("storeSignedMigrationTransactions") }
            }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in
                callOrder.withValue { $0.append("broadcastStoredNoteSplit") }
                return MigrationTransferResult.success(txId: "split-tx")
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in callOrder.withValue { $0.append("recordCommittedSchedule") } }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.path) // dispatched .noteSplit(.retryTapped)
        await store.receive(\.path) // .noteSplit(.splitResult(.success)) — the broadcast landed
        await store.receive(\.path) // .noteSplit(.splitBroadcastSucceeded) — sets awaitingScheduleStore
        await store.receive(\.path) // .noteSplit(.delegate(.storeScheduleRequested)) — asks the coordinator to store
        await store.receive(\.path) // .noteSplit(.splitConfirmed) — the deferred store succeeded

        // MOB-1496 (C-1b fix, final review R6 fix-wave 2): the schedule store must not precede the
        // split's BROADCAST (not just its local store) — the engine's prep-success record
        // unconditionally overwrites the run's phase (`context.rs:1299-1303`), so a schedule store
        // performed before the split broadcasts gets clobbered the instant it lands, stranding the
        // run at `.readyToPropose` once the split mines (`context.rs:361-378`). RED against wave 1's
        // code (store, store, record — broadcast last): recorded in the fix report.
        #expect(
            callOrder.value ==
                ["storeSignedNoteSplits", "broadcastStoredNoteSplit", "storeSignedMigrationTransactions", "recordCommittedSchedule"]
        )
        // The deferred store's success flips the note-split screen to `.confirmed` and releases the
        // stash — nothing left pending.
        #expect(store.state.pendingKeystoneScheduleStore == nil)
        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .noteSplit still on top, now confirmed")
            return
        }
        #expect(noteSplitState.phase == MigrationNoteSplit.State.Phase.confirmed)
    }

    /// A split-broadcast failure (MOB-1496 C-1b fix, fix-wave 2: the schedule is no longer stored
    /// before the split broadcasts, so there is nothing "already committed" here any more — the
    /// entries stay stashed, unstored, in `pendingKeystoneScheduleStore`, exactly where a later
    /// successful broadcast attempt will find them) — the note-split screen's OWN existing failure
    /// sheet (`isFailurePresented`) is what surfaces the retry affordance, with the SAME signed PCZT
    /// still stashed so a real retry tap RE-BROADCASTS it (not a schedule-store retry — the split
    /// itself hasn't landed yet, so `awaitingScheduleStore` never became `true`).
    @MainActor @Test func foundPCZTBatchWithNoteSplitSentinelSplitBroadcastFailureLeavesScheduleUnstoredAndPresentsRetry() async {
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))
        ]
        let signed: [Data] = [Data([0x01, 0x99]), Data([0xAA, 0x99])]
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24
        )
        var planState = MigrationTransferPlan.State(variant: .scheduled)
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(planState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            // R7-T3 (MOB-1497): `.networkError(retryable: true)` now classifies as `.endpointUnreachable`
            // and routes BEFORE `.splitResult` — `routeBroadcastFailure` is mocked to `.plainRetry`
            // here (this pins the coordinator-level integration, not the routing decision itself — see
            // `MigrationFailureRoutingTests` for the real router exercised against a provisional
            // snapshot, the actual shape this lane's pre-commit broadcast produces per the R7-review
            // Important-1 fix).
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.path) // dispatched .noteSplit(.retryTapped)
        await store.receive(\.path) // .noteSplit(.broadcastFailureRouted(.plainRetry)) — R7-T3
        await store.receive(\.path) // .noteSplit(.splitResult(.networkError)) — broadcast failed

        // MOB-1496 (C-1b fix, fix-wave 2): the deferred store is never even attempted — the broadcast
        // that would trigger it (`.splitBroadcastSucceeded`) never fired.
        #expect(recordCommittedScheduleCalls.value == 0)
        #expect(store.state.pendingKeystoneScheduleStore != nil)
        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .noteSplit still on top showing its own failure sheet")
            return
        }
        #expect(noteSplitState.isFailurePresented == true)
        // R7-T3 (MOB-1497): the routed kind reached the screen's state too.
        #expect(noteSplitState.failureKind == MigrationBroadcastFailureRoute.plainRetry)
        #expect(noteSplitState.signedNoteSplitPczt == [MigrationSignedTransferPczt(id: "p0", pczt: Data([0x01, 0x99]))])
        #expect(noteSplitState.awaitingScheduleStore == false)
    }

    // MARK: - MOB-1496 (C-1 fix, final review R6): split-store failure abandons the session

    /// `storeSignedNoteSplits` throwing means NOTHING was stored — the schedule store must never even
    /// be attempted (it would land in a run the split never created), nothing gets recorded, and the
    /// session abandons exactly like a re-pair failure: nothing to resume, same `keystoneScanAbandoned`
    /// semantics (pop back to `.transferPlan`, context cleared).
    @MainActor @Test func foundPCZTBatchWithSplitStoreFailureAbandonsSessionWithoutStoringScheduleOrRecording() async {
        struct SplitStoreFailure: Error { }
        let scheduleStoreCalls = LockIsolated<Int>(0)
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))
        ]
        let signed: [Data] = [Data([0x01, 0x99]), Data([0xAA, 0x99])]
        var planState = MigrationTransferPlan.State(variant: .scheduled)
        planState.schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24
        )
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(planState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in throw SplitStoreFailure() }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in scheduleStoreCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(scheduleStoreCalls.value == 0)
        #expect(recordCommittedScheduleCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    /// Same split-store-failure abandon, but from the simulator-only bypass — which never pushes
    /// `.scan`, so only 1 element (`keystoneSign`) needs popping, not 2. Proves
    /// `keystoneScanAbandoned`'s generalized pop count is correct for this caller too.
    @MainActor @Test func keystoneSignSimulateSignatureWithSplitStoreFailureAbandonsSessionWithoutScanPopped() async {
        struct SplitStoreFailure: Error { }
        let scheduleStoreCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(pczts: [
                    MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
                    MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))
                ])
            )
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in throw SplitStoreFailure() }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in scheduleStoreCalls.withValue { $0 += 1 } }
            // Never actually called on this (abandon) path, but the `.run` effect's capture list
            // still resolves `migrationManager` when constructed — swift-dependencies requires SOME
            // override to be registered before a test context may touch it at all.
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.simulateSignature)))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(scheduleStoreCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (keystoneSign removed, no .scan was ever pushed)")
            return
        }
    }

    /// The "happy path" consumption of `pendingKeystoneSplitResume`: once the note-split screen's
    /// broadcast is confirmed and the user taps Continue (`.delegate(.continued)`), the coordinator
    /// must resume to the SAME post-commit screen a no-split batch would have reached immediately,
    /// clear the resume context (a leaked context would silently mis-route a LATER, unrelated
    /// `.noteSplit(.delegate(.continued))`), and pop the note-split detour itself (so back-navigation
    /// from `.scheduled` lands on `.transferPlan`, not a stale "Split Confirmed!" screen).
    @MainActor @Test func noteSplitContinuedAfterKeystoneSplitRoutingResumesToScheduledAndClearsPendingResume() async {
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))
        ]
        let signed: [Data] = [Data([0x01, 0x99]), Data([0xAA, 0x99])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in MigrationTransferResult.success(txId: "split-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.path) // dispatched .noteSplit(.retryTapped)
        await store.receive(\.path) // .noteSplit(.splitResult(.success))
        // MOB-1496 (C-1b fix, fix-wave 2): the deferred schedule store — driven by the broadcast
        // succeeding above — runs and succeeds before the "Split Confirmed!" phase (and Continue) is
        // ever reachable.
        await store.receive(\.path) // .noteSplit(.splitBroadcastSucceeded)
        await store.receive(\.path) // .noteSplit(.delegate(.storeScheduleRequested))
        await store.receive(\.path) // .noteSplit(.splitConfirmed) — the deferred store succeeded

        guard case let .noteSplit(noteSplitState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .noteSplit pushed and showing before Continue")
            return
        }
        #expect(noteSplitState.phase == MigrationNoteSplit.State.Phase.confirmed)
        #expect(store.state.pendingKeystoneSplitResume == MigrationCoordFlow.KeystoneSigningContext.planCommit)
        #expect(store.state.pendingKeystoneScheduleStore == nil)
        guard let noteSplitId = store.state.path.ids.last else {
            Issue.record("Expected a noteSplit element id")
            return
        }

        // The split confirmed and the user tapped Continue. The actual pop+resume is deferred to
        // `keystoneSplitResumeContinued` (mirrors `keystoneSignRejected`'s deferred pop — popping the
        // `noteSplit` element inline while `.forEach` is still delivering ITS OWN action to that same
        // element is a TCA "missing element" runtime error), so a second receive is expected here.
        await store.send(.path(.element(id: noteSplitId, action: .noteSplit(.delegate(.continued)))))
        await store.receive(\.keystoneSplitResumeContinued)

        #expect(store.state.pendingKeystoneSplitResume == nil)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed — the SAME post-commit screen a no-split batch reaches immediately")
            return
        }
        guard case .transferPlan = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected the .transferPlan retained beneath (never re-signs again)")
            return
        }
        #expect(store.state.path.contains { $0.is(\.noteSplit) } == false)
    }

    /// §1's split-routing fix applies uniformly to `.immediateReview`, not just `.planCommit` — a
    /// needed split in the immediate-mode batch is stripped and routed the same way, and its
    /// Continue resumes to `.sending` (not `.scheduled`), still clearing the resume context.
    @MainActor @Test func noteSplitContinuedAfterImmediateReviewKeystoneSplitRoutingResumesToSendingAndClearsPendingResume() async {
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x02])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xCC]))
        ]
        let signed: [Data] = [Data([0x02, 0x99]), Data([0xCC, 0x99])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in MigrationTransferResult.success(txId: "split-tx") }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.path) // dispatched .noteSplit(.retryTapped)
        await store.receive(\.path) // .noteSplit(.splitResult(.success))
        await store.receive(\.path) // .noteSplit(.splitBroadcastSucceeded)
        await store.receive(\.path) // .noteSplit(.delegate(.storeScheduleRequested))
        await store.receive(\.path) // .noteSplit(.splitConfirmed) — the deferred store succeeded

        #expect(store.state.pendingKeystoneSplitResume == MigrationCoordFlow.KeystoneSigningContext.immediateReview)
        #expect(store.state.pendingKeystoneScheduleStore == nil)
        guard let noteSplitId = store.state.path.ids.last else {
            Issue.record("Expected a noteSplit element id")
            return
        }

        await store.send(.path(.element(id: noteSplitId, action: .noteSplit(.delegate(.continued)))))
        await store.receive(\.keystoneSplitResumeContinued)

        #expect(store.state.pendingKeystoneSplitResume == nil)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed")
            return
        }
        #expect(sendingState.totalCount == 1)
        guard case .reviewTransfer = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .reviewTransfer retained at the bottom")
            return
        }
    }

    /// No-split batches are unaffected: `splitKeystoneBatch` finds no sentinel, so every entry lands
    /// in `scheduleEntries` and the resume proceeds straight to `.scheduled`, exactly as before —
    /// twin of `foundPCZTBatchForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant`
    /// above, just asserting the split-free path explicitly stays split-free (no `.noteSplit` push).
    @MainActor @Test func foundPCZTBatchWithoutNoteSplitSentinelNeverPushesNoteSplitScreen() async {
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        let signed: [Data] = [Data([0xAA, 0x01]), Data([0xBB, 0x01])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(store.state.pendingKeystoneSplitResume == nil)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed directly, no .noteSplit detour")
            return
        }
    }

    // MARK: - MOB-1496 (W6 §2): re-pair validation — coordinator abandon-on-mismatch (short/long batch)
    //
    // The empty-batch case is already covered by
    // `foundPCZTBatchWithEmptyArrayForPlanCommitContextAbandonsSessionWithoutStoring` below; the pure
    // `rePairedKeystoneBatch`/`splitKeystoneBatch` table tests are their own `@Suite` at the bottom of
    // this file.

    @MainActor @Test func foundPCZTBatchWithShortBatchAbandonsSessionWithoutStoring() async {
        let storeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(pczts: [
                    MigrationUnsignedTransferPczt(id: "t0", pczt: Data()),
                    MigrationUnsignedTransferPczt(id: "t1", pczt: Data())
                ])
            )
        )
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        // Only ONE signed entry scanned back for a TWO-entry unsigned batch.
        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch([Data([0x01])])))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(storeCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    @MainActor @Test func foundPCZTBatchWithLongBatchAbandonsSessionWithoutStoring() async {
        let storeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        // TWO signed entries scanned back for a ONE-entry unsigned batch.
        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch([Data([0x01]), Data([0x02])])))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(storeCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    @MainActor @Test func foundPCZTBatchForPlanCommitContextPushesSendingForManualVariant() async {
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xCC]))]
        let signed: [Data] = [Data([0xCC, 0x01])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .manual)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            // MOB-1496 (W2): see `foundPCZTBatchForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant`'s comment.
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top for the manual variant")
            return
        }
        #expect(sendingState.totalCount == 1)
    }

    // MARK: - MOB-1468: Keystone signing — foundPCZTBatch resumes immediateReview

    @MainActor @Test func foundPCZTBatchForImmediateReviewContextStoresPopsAndPushesSending() async {
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xDD]))]
        let signed: [Data] = [Data([0xDD, 0x01])]
        let expectedStored: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "t0", pczt: Data([0xDD, 0x01]))]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            // MOB-1496 (W2): see `foundPCZTBatchForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant`'s comment.
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [expectedStored])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of the retained .reviewTransfer element")
            return
        }
        #expect(sendingState.totalCount == 1)
        guard case .reviewTransfer = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .reviewTransfer retained at the bottom")
            return
        }
    }

    // MARK: - MOB-1468: Keystone signing — empty batch never stores (no-partial-storage)

    @MainActor @Test func foundPCZTBatchWithEmptyArrayForPlanCommitContextAbandonsSessionWithoutStoring() async {
        let storeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch([])))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(storeCalls.value == 0)
        // Deferred pop of scan + sign back to the plan, context cleared — the user re-initiates
        // signing from the confirm button (no-partial-storage invariant: nothing was stored).
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    // MARK: - MOB-1468: Keystone signing — rejected pops back with state intact, context cleared

    @MainActor @Test func keystoneSignRejectedPopsBackToUnsignedTransferPlanConfirmingScreenUntouched() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data()), MigrationUnsignedTransferPczt(id: "t1", pczt: Data())])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign popped, .transferPlan remaining on top, unsigned")
            return
        }
    }

    @MainActor @Test func keystoneSignRejectedNeverCallsStore() async {
        let storeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(storeCalls.value == 0)
    }

    /// R8-T3 (V18-b): the immediate-mode Sending close no longer acknowledges AT ALL — the engine
    /// may still be genuinely `.inProgress` at this point (completion needs mined-confirmed +
    /// `orchard_spendable == 0`, not merely "the last broadcast succeeded"), so acknowledging here
    /// unconditionally (the pre-fix behavior) risked wiping a still-live run's own
    /// schedule/snapshot records. It now just sends `.flowFinished`; storages are asserted intact
    /// via the absent acknowledge call (a spy that must see zero invocations).
    @MainActor @Test func sendingClosedInImmediateModeFinishesFlowWithoutAcknowledging() async {
        let acknowledgeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.path.append(.sending(MigrationSending.State(phase: .success)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.acknowledgeComplete = { _ in acknowledgeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .sending(.delegate(.closed)))))
        await store.receive(\.flowFinished)

        #expect(acknowledgeCalls.value == 0)
    }

    // MARK: - Scheduled flow (§6.2, MOB-1478 W3): Entry always pushes How This Works

    @MainActor @Test func entryChoseScheduledAlwaysPushesHowItWorksRegardlessOfNoteSplitNeed() async {
        // Note splitting no longer gates (or appears in) forward routing at all — it runs silently
        // under the commit CTAs (W4). `isNoteSplitNeeded` is stubbed `true` here specifically to
        // prove Entry doesn't even look at it any more.
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _ in }
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.isNoteSplitNeeded = { _ in true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.privateScheduled))))

        #expect(store.state.mode == MigrationMode.privateScheduled)
        guard case .howItWorks = try? #require(store.state.path.last) else {
            Issue.record("Expected .howItWorks pushed")
            return
        }
    }

    // MARK: - HowItWorks (MOB-1494 round 4): same Tor-sheet gate as the immediate lane

    @MainActor @Test func howItWorksContinuedWithTorFlagOnSkipsSheetPersistsAndProceeds() async {
        // Flag-on shortcut: `useTor` is implicitly on and persisted (MOB-1487's persist-fix — a
        // background send reads the persisted copy, not this in-memory state), no sheet, straight
        // into the permission chain.
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            // MOB-1497 (T2, R13): the skip branch's `nextPermissionStepResult` reads the just-formed
            // snapshot back to hydrate the Transfer Plan footer.
            $0.migrationManager.networkSnapshot = { _ in Self.someProviderNetworkSnapshot() }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { false }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .howItWorks(.delegate(.continueTapped)))))
        await store.receive(\.pushNextPermissionStep)

        #expect(setOptionsCalls.value == [true])
        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        // MOB-1497 (T1): the flag-on shortcut on the scheduled/How-This-Works chain is a Tor-choice
        // resolution point too — forms the run's (provisional) network snapshot here.
        #expect(formNetworkSnapshotCalls.value == 1)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (Tor sheet skipped, flag on)")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
        // MOB-1497 (T2, R13): sheet-skipped provider users never see the sheet's own disclosure
        // line — this screen's footer carries it instead.
        #expect(planState.broadcastDisclosureHost == "eu.zec.stardust.rest")
    }

    @MainActor @Test func howItWorksContinuedWithTorFlagOffPresentsTorSheetAndStashesPermissionChain() async {
        // MOB-1494 (round 4): flag unset presents the toggle sheet (default ON, scheduled
        // "your balance" body variant) and stashes `.permissionChain`; nothing is persisted or
        // pushed until the sheet resolves.
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            $0.migrationManager.networkSnapshot = { _ in Self.someProviderNetworkSnapshot() }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .howItWorks(.delegate(.continueTapped)))))
        // MOB-1497 (T2): presentation is now the async `torSheetState` helper, dispatched via
        // `torSheetStateReady`.
        await store.receive(\.torSheetStateReady)

        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.pendingTorDestination == MigrationCoordFlow.PendingTorDestination.permissionChain)
        #expect(store.state.torSheetState.isTorOn == true)
        #expect(store.state.torSheetState.usesFullBalanceCopy == false)
        // MOB-1497 (T2, R13): provider — the toggle sheet variant, hydrated with the formed host.
        #expect(store.state.torSheetState.isCustomServer == false)
        #expect(store.state.torSheetState.broadcastHost == "eu.zec.stardust.rest")
        #expect(setOptionsCalls.value.isEmpty)
        // MOB-1497 (T2): forming moves to PRESENTATION — no longer 0.
        #expect(formNetworkSnapshotCalls.value == 1)
        // Nothing new pushed — `.howItWorks` is still the top element.
        guard case .howItWorks = try? #require(store.state.path.last) else {
            Issue.record("Expected .howItWorks still on top (sheet gates the push)")
            return
        }
    }

    /// MOB-1497 (T2, R2/R12 variant matrix — scheduled/"gradual" path): the twin of
    /// `entryChoseImmediateWithTorFlagOffAndCustomServerPresentsUnavailableVariant` on the scheduled
    /// lane — "both paths get the variant when custom" (§2 of the brief), no trigger-logic changes.
    @MainActor @Test func howItWorksContinuedWithTorFlagOffAndCustomServerPresentsUnavailableVariant() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
            $0.migrationManager.formNetworkSnapshot = { _ in }
            $0.migrationManager.networkSnapshot = { _ in Self.someCustomNetworkSnapshot() }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .howItWorks(.delegate(.continueTapped)))))
        await store.receive(\.torSheetStateReady)

        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.torSheetState.isCustomServer == true)
        #expect(store.state.torSheetState.broadcastHost == "custom.example.org")
        #expect(store.state.torSheetState.isTorOn == false)
        #expect(store.state.torSheetState.usesFullBalanceCopy == false)
    }

    // MARK: - Scheduled flow (§6.2): permission-step skip combinations

    @MainActor @Test func backgroundDeliveryDeclinedSetsManualDeliveryAndContinuesToNotifications() async {
        let setManualDeliveryCalls = LockIsolated<[Bool]>([])
        var state = MigrationCoordFlow.State()
        state.path.append(.backgroundDelivery(MigrationBackgroundDelivery.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setManualDelivery = { allowed in setManualDeliveryCalls.withValue { $0.append(allowed) } }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .notDetermined }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .backgroundDelivery(.delegate(.continued(backgroundAllowed: false))))))
        await store.receive(\.pushNextPermissionStep)

        #expect(setManualDeliveryCalls.value == [true])
        guard case .notifications = try? #require(store.state.path.last) else {
            Issue.record("Expected .notifications pushed (authorization not determined)")
            return
        }
    }

    // MOB-1478 (W8): mirrors `freshPlanVariant()`'s ternary — today `.manual` was unreachable since
    // this always defaulted to `.scheduled`.
    @MainActor @Test func notificationsVariantIsManualWhenManualDeliveryIsSet() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.backgroundDelivery(MigrationBackgroundDelivery.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setManualDelivery = { _ in }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .notDetermined }
            $0.migrationManager.isManualDelivery = { true }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .backgroundDelivery(.delegate(.continued(backgroundAllowed: false))))))
        await store.receive(\.pushNextPermissionStep)

        guard case let .notifications(notificationsState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .notifications pushed")
            return
        }
        #expect(notificationsState.variant == MigrationNotifications.State.Variant.manual)
    }

    @MainActor @Test func notificationsContinuedGoesStraightToTransferPlan() async {
        // Tor is no longer part of this chain at all (W2) — notifications-continued always resolves
        // straight to TransferPlan once background delivery + notifications are both settled.
        var state = MigrationCoordFlow.State()
        state.path.append(.notifications(MigrationNotifications.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { false }
            $0.migrationManager.networkSnapshot = { _ in nil }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .notifications(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
    }

    @MainActor @Test func allPermissionStepsSkippedGoesStraightToTransferPlan() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.notifications(MigrationNotifications.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .denied }
            $0.migrationManager.isManualDelivery = { false }
            $0.migrationManager.networkSnapshot = { _ in nil }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .notifications(.delegate(.continued)))))
        await store.receive(\.pushNextPermissionStep)

        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (all permission steps skipped)")
            return
        }
    }

    // MARK: - Scheduled flow (§6.2): plan confirm -> Scheduled

    @MainActor @Test func transferPlanConfirmedInScheduledVariantSchedulesFirstWindowAndPushesScheduled() async {
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))
        await store.finish()

        #expect(scheduleFirstWindowCalls.value == 1)
        // MOB-1497: plan-confirm does NOT form a network snapshot — forming already happened at the
        // Tor-choice step, earlier in the chain (see the `torSheet...`/`howItWorksContinued...`
        // tests above). `migrationNetworkOptions`'s eventual broadcast-time read is naturally
        // idempotent against the already-formed snapshot; this coordinator step itself never calls
        // `formNetworkSnapshot` at all.
        #expect(formNetworkSnapshotCalls.value == 0)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed")
            return
        }
    }

    @MainActor @Test func scheduledDoneFinishesFlow() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.scheduled(MigrationScheduled.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .scheduled(.delegate(.done)))))
        await store.receive(\.flowFinished)
    }

    // MARK: - Manual flow (§6.3)

    @MainActor @Test func transferPlanConfirmedInManualVariantSchedulesFirstWindowAndPushesSendingWithTotalCountOne() async {
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .manual)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))

        #expect(scheduleFirstWindowCalls.value == 1)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed")
            return
        }
        #expect(sendingState.totalCount == 1)
    }

    @MainActor @Test func manualPlanConfirmPushesSendingWithSingleTransfer() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var planState = MigrationTransferPlan.State(variant: .manual, requiresSigning: true)
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(planState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed")
            return
        }
        #expect(sendingState.totalCount == 1)
    }

    @MainActor @Test func sendingClosedInManualModeWithNoStatusBeneathPushesFreshStatus() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi(1_000),
            dust: Zatoshi.zero,
            transfersSent: 1,
            transfersTotal: 1,
            estimatedDurationHours: 24
        )
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.sending(MigrationSending.State(phase: .success)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in rows }
            $0.migrationManager.migrationSummary = { _ in summary }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .sending(.delegate(.closed)))))
        await store.receive(\.pushHydratedStatus)

        #expect(store.state.path.count == 2)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status pushed on top of the (still-present) .sending element")
            return
        }
        #expect(statusState.presentation == MigrationStatus.State.Presentation.progress)
        #expect(statusState.isFlowRoot == false)
    }

    // MARK: - sendNow: totalCount capped at one transfer (ZIP-0318), completion returns to Status

    /// MOB-1496 (fix-wave, review MINOR-5): the push site's `totalCount` used to be driven by the
    /// overdue row count (`max(overdueCount, 1)`) — vestigial once `MigrationSendingStore` stopped
    /// looping on `totalCount` (W5, ZIP-0318 MUST: at most one broadcast per screen/session
    /// regardless of how many transfers are overdue). Renamed from
    /// `statusSendNowPushesSendingConfiguredForOverdueCount`: the cap is the contract now, not the
    /// overdue count, so the pushed `Sending` state's `totalCount` is always exactly 1 — asserted
    /// here even with MULTIPLE overdue rows present, to prove the count no longer drives it.
    @MainActor @Test func statusSendNowPushesSendingConfiguredWithSingleTransferCap() async {
        let rows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 5),
            MigrationTransferRow(id: "2", index: 2, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 3)
        ]
        var state = MigrationCoordFlow.State()
        state.path.append(.status(MigrationStatus.State(presentation: .resume, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in rows }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .status(.delegate(.sendNow)))))
        await store.receive(\.pushHydratedPathState)

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed")
            return
        }
        #expect(sendingState.totalCount == 1)
        // R8-T6: the push site threads the Send-now lane context so `MigrationSendingStore` routes
        // through the silence-window gate-check/wait flow instead of broadcasting immediately.
        #expect(sendingState.entersViaSendNow == true)
    }

    @MainActor @Test func sendingClosedAfterSendNowPopsBackToStatusWithRefreshedRows() async {
        let refreshedRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0)
        ]
        var state = MigrationCoordFlow.State()
        state.path.append(.status(MigrationStatus.State(presentation: .resume, isFlowRoot: true)))
        state.path.append(.sending(MigrationSending.State(phase: .success, totalCount: 2)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.migrationManager.migrationTransfers = { _ in refreshedRows }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .sending(.delegate(.closed)))))
        await store.receive(\.sendNowCompleted)

        #expect(store.state.path.count == 1)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending popped, .status remaining on top")
            return
        }
        #expect(statusState.rows == IdentifiedArrayOf(uniqueElements: refreshedRows))
        #expect(statusState.isFlowRoot == true)
    }

    /// [MOB-1496] R8-T2 (#14): the Sending success-phase Close button stays enabled while its own
    /// `.sending(.delegate(.closed))` handler's async effect is in flight, and that handler
    /// (`hasStatusBeneath`'s branch, above) spawns a FRESH effect per delivery — a double-tap before
    /// the first effect's result comes back therefore queues TWO `.sendNowCompleted` deliveries
    /// (driven directly here, rather than via two `.closed` sends: with the test's synchronous
    /// `migrationTransfers` stub, TestStore's first `send` runs its spawned effect to completion
    /// before the test can issue a second `.closed` send, popping `.sending` for real and making a
    /// literal double-`.closed`-send an invalid/misleading repro of the race — the REAL bug is in how
    /// `sendNowCompleted` itself handles being delivered twice, which is what this exercises directly).
    /// Before this fix, `sendNowCompleted` popped the path unconditionally, so the second delivery
    /// popped the `.status` element the first had already landed on, dumping the user out to Entry
    /// mid-run. The pop is now guarded on the top element still being `.sending`, so the second
    /// delivery is a no-op.
    @MainActor @Test func secondSendNowCompletedDeliveryIsANoOpAfterFirstAlreadyPoppedSending() async {
        let firstRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0)
        ]
        let secondRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0),
            MigrationTransferRow(id: "1", index: 1, amount: Zatoshi(1_000), status: .sent, hoursFromNow: 0)
        ]
        var state = MigrationCoordFlow.State()
        state.path.append(.status(MigrationStatus.State(presentation: .resume, isFlowRoot: true)))
        state.path.append(.sending(MigrationSending.State(phase: .success, totalCount: 2)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        // First delivery: `.sending` is on top — pops it, refreshes `.status` with `firstRows`.
        await store.send(.sendNowCompleted(rows: firstRows))
        #expect(store.state.path.count == 1)

        // Second delivery (the double-tap's second spawned effect landing): `.sending` is no longer
        // on top, so this must be a no-op — no further pop, and `secondRows` is never applied.
        await store.send(.sendNowCompleted(rows: secondRows))

        #expect(store.state.path.count == 1)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status still on top — a second pop would have emptied the path down to Entry")
            return
        }
        #expect(statusState.rows == IdentifiedArrayOf(uniqueElements: firstRows))
        #expect(statusState.isFlowRoot == true)
    }

    // MARK: - Reschedule (MOB-1478 W7): SDK + scheduler spies called in order, lands .rescheduleCompleted
    // on the SAME status element — no new plan push.

    @MainActor @Test func statusRescheduleSetsIsReschedulingCallsSDKAndSchedulerThenLandsRescheduleCompletedInPlace() async {
        let callOrder = LockIsolated<[String]>([])
        let refreshedRows: [MigrationTransferRow] = [
            MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)
        ]
        let summary = MigrationSummary(
            transferred: Zatoshi.zero,
            dust: Zatoshi.zero,
            transfersSent: 0,
            transfersTotal: 1,
            estimatedDurationHours: 18
        )
        var state = MigrationCoordFlow.State()
        state.path.append(
            .status(
                MigrationStatus.State(
                    presentation: .resume,
                    rows: [MigrationTransferRow(id: "old", index: 0, amount: Zatoshi(1_000), status: .overdue, hoursFromNow: 5)],
                    stalledNumber: 1,
                    isFlowRoot: true
                )
            )
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.rescheduleOverdueMigrationTransfer = { _ in
                callOrder.withValue { $0.append("reschedule") }
                return nil
            }
            $0.migrationManager.migrationTransfers = { _ in refreshedRows }
            $0.migrationManager.migrationSummary = { _ in summary }
            $0.migrationBGScheduler.scheduleFirstWindow = { callOrder.withValue { $0.append("scheduleFirstWindow") } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .status(.delegate(.reschedule)))))
        await store.receive(\.path)

        #expect(callOrder.value == ["reschedule", "scheduleFirstWindow"])
        // No new path element — the SAME status element lands the confirmation.
        #expect(store.state.path.count == 1)
        guard case let .status(statusState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .status still the only path element")
            return
        }
        #expect(statusState.isRescheduling == false)
        #expect(statusState.presentation == MigrationStatus.State.Presentation.rescheduleConfirmed(first: 1, last: 1))
        #expect(statusState.rows == IdentifiedArrayOf(uniqueElements: refreshedRows))
        #expect(statusState.totalDurationHours == 18)
    }

    @MainActor @Test func rescheduledPlanConfirmDoesNotSignAndFinishesFlow() async {
        let signCalls = LockIsolated<Int>(0)
        var planState = MigrationTransferPlan.State(variant: .scheduled, requiresSigning: false)
        planState.rows = [MigrationTransferRow(id: "0", index: 0, amount: Zatoshi(1_000), status: .active, hoursFromNow: 0)]
        let store = TestStore(initialState: planState) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, _, _ in signCalls.withValue { $0 += 1 } }
        }

        await store.send(.confirmTapped)
        await store.receive(.delegate(.confirmed))

        #expect(signCalls.value == 0)
    }

    @MainActor @Test func rescheduledPlanConfirmedInCoordinatorFinishesFlowWithoutPushingScheduled() async {
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled, requiresSigning: false)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))
        await store.receive(\.flowFinished)

        #expect(scheduleFirstWindowCalls.value == 0)
    }

    // MARK: - Recovery: restartCurrentMigrationStep spy, re-created plan injected, its confirm DOES sign

    @MainActor @Test func recoveryRecreateCallsRestartAndPushesRecreatedPlanWithInjectedSchedule() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        let restartCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _, includeResidual in
                #expect(includeResidual == false)
                restartCalls.withValue { $0 += 1 }
                return schedule
            }
            // MOB-1496 (W2): a successful restart now also reconciles — explicit no-op override
            // since swift-dependencies requires `migrationManager` to be customized at least once
            // before any of its members can run in a test context.
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.pushHydratedPathState)

        #expect(restartCalls.value == 1)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan (re-created) pushed")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.recreated)
        #expect(planState.injectedSchedule == schedule)
        #expect(planState.requiresSigning == true)
    }

    /// MOB-1496 (W2): `restartCurrentMigrationStep` succeeding is one of `reconcile()`'s triggers —
    /// the fresh restart's state transition (e.g. off `.requiresAttention`) should be observed
    /// promptly, ahead of the later schedule-commit reconcile that fires once this re-created plan
    /// is actually signed+stored.
    @MainActor @Test func recoveryRecreateReconcilesWhenRestartSucceeds() async {
        let reconcileCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _, _ in
                MigrationSchedule(transfers: [], estimatedDurationHours: 0)
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.pushHydratedPathState)

        #expect(reconcileCalls.value == 1)
    }

    /// A failed restart must not reconcile — nothing actually changed on the engine side to
    /// observe. MOB-1496 (R8-T1, S3): also no longer falls back to a silent empty placeholder
    /// schedule — `injectedSchedule` is left `nil` so the pushed `.recreated` plan's own `onAppear`
    /// falls through to a fresh `proposeMigrationTransfers` attempt (same as a first-run
    /// `.scheduled` plan) and surfaces its OWN propose-failure sheet if that fails too; see
    /// `MigrationTransferPlanTests` for that fallthrough's own coverage.
    @MainActor @Test func recoveryRecreateDoesNotReconcileWhenRestartFails() async {
        struct RestartFailure: Error { }
        let reconcileCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _, _ in throw RestartFailure() }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.pushHydratedPathState)

        #expect(reconcileCalls.value == 0)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan (recreated) pushed")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.recreated)
        #expect(planState.injectedSchedule == nil)
    }

    @MainActor @Test func recreatedPlanConfirmDoesSign() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 24
        )
        var planState = MigrationTransferPlan.State(variant: .recreated)
        planState.schedule = schedule
        let signedSchedule = LockIsolated<MigrationSchedule?>(nil)
        let store = TestStore(initialState: planState) {
            MigrationTransferPlan()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.signAndStoreMigrationSchedule = { _, schedule, _ in signedSchedule.setValue(schedule) }
            // MOB-1496: the software-signing path derives a real USK from the wallet's stored seed
            // (`UnifiedSpendingKey` has no public initializer anywhere in the SDK) — see
            // `MigrationTransferPlanTests`' `withDependenciesUSKDerivable` helper for the rationale;
            // this file has no shared helper of its own since this is its only such case.
            $0.derivationTool = .liveValue
            $0.mnemonic = .mock
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            // MOB-1496 (W2): the sign+store success path now also calls these two — explicit
            // no-op overrides since swift-dependencies requires `migrationManager` to be
            // customized at least once before any of its members can run in a test context.
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.reconcile = { }
        }

        await store.send(.confirmTapped)
        await store.receive(\.scheduleSigned)
        await store.receive(.delegate(.confirmed))

        #expect(signedSchedule.value == schedule)
    }

    // MARK: - Every flow-root back -> .flowFinished

    @MainActor @Test func entryBackFinishesFlow() async {
        // Entry is the NavigationStack root (not a `path` element): its back button can't pop
        // anything, so `dismissRequired` must exit the whole flow (MOB-1466 fix — the button was
        // previously wired to SwiftUI `dismiss()`, a no-op at the flow root).
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.entry(.dismissRequired))
        await store.receive(\.flowFinished)
    }

    @MainActor @Test func statusDoneFinishesFlow() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.status(MigrationStatus.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .status(.delegate(.done)))))
        await store.receive(\.flowFinished)
    }

    @MainActor @Test func recoveryCloseFinishesFlow() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.close)))))
        await store.receive(\.flowFinished)
    }

    @MainActor @Test func reviewTransferClosedFinishesFlow() async {
        var state = MigrationCoordFlow.State()
        state.path.append(
            .reviewTransfer(MigrationReviewTransfer.State(mode: .manualStep(number: 3, total: 5), isFlowRoot: true))
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.closed)))))
        await store.receive(\.flowFinished)
    }

    /// R8-T3 (V18): "Got it" keeps acknowledging (the Complete screen only shows once the run is
    /// genuinely `.complete`) — now async + account-scoped, merged with the navigation send rather
    /// than awaited before it.
    @MainActor @Test func completeDoneAcknowledgesCompleteAndFinishesFlow() async {
        let acknowledgeCalls = LockIsolated<[AccountUUID?]>([])
        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.acknowledgeComplete = { accountUUID in acknowledgeCalls.withValue { $0.append(accountUUID) } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.done)))))
        await store.receive(\.flowFinished)
        // R8-T3: acknowledge now runs as a separate effect `.merge`d alongside the navigation send
        // (never awaited before it) — `store.finish()` drains it before the spy is asserted.
        await store.finish()

        #expect(acknowledgeCalls.value == [Self.defaultAccount.id])
    }

    // MARK: - MOB-1487: dust lane ("Migrate anyway" over Migration Complete)

    @MainActor @Test func completeMigrateAnywayPushesSendingConfiguredForDustLane() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of .complete")
            return
        }
        #expect(sendingState.totalCount == 1)
        #expect(sendingState.isDustLane == true)
    }

    @MainActor @Test func sendingClosedOverCompleteAcknowledgesCompleteAndFinishesFlow() async {
        // MOB-1487: this Sending sits over the complete screen (reached via "Migrate anyway") —
        // closing it must end the flow with the same bookkeeping as the complete screen's own
        // "Got it" (`completeDoneAcknowledgesCompleteAndFinishesFlow` above), even though `.sending`
        // is on top and the flow is NOT in `.immediate` mode. R8-T3 (V18): acknowledge stays here
        // too (the dust lane only reaches this over an already-`.complete` screen) — async +
        // account-scoped now, merged with the navigation send.
        let acknowledgeCalls = LockIsolated<[AccountUUID?]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        state.path.append(.sending(MigrationSending.State(phase: .success, isDustLane: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.acknowledgeComplete = { accountUUID in acknowledgeCalls.withValue { $0.append(accountUUID) } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .sending(.delegate(.closed)))))
        await store.receive(\.flowFinished)
        await store.finish()

        #expect(acknowledgeCalls.value == [Self.defaultAccount.id])
    }

    // MARK: - MOB-1480: Keystone signing — simulator-only bypass (no `.scan` ever pushed)

    @MainActor @Test func keystoneSignSimulateSignatureForImmediateReviewContextStoresPopsAndPushesSendingWithoutScan() async {
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xEE]))]
        // "Signing" is pretending the unsigned bytes are already signed (same id/bytes) — see
        // `MigrationCoordFlowCoordinator`'s `.simulateSignature` handler doc.
        let expectedStored: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "t0", pczt: Data([0xEE]))]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            // MOB-1496 (W2): see `foundPCZTBatchForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant`'s comment.
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        // No `.scan` element on the path at all — the bypass button lives on `keystoneSign` itself
        // and the coordinator reads the batch straight off that element instead of a scanned
        // result. Deliberately NOT asserting `isSimulatorBypassVisible` here: this test target
        // (zodl-internal) always has `MigrationSimulatorFlag.isEnabled == false`, so the button
        // would never actually be visible in this build — the coordinator's handler is
        // intentionally not flag-gated (only the button's visibility is), so driving the delegate
        // directly is the correct boundary to test.
        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.simulateSignature)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [expectedStored])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of the retained .reviewTransfer element")
            return
        }
        #expect(sendingState.totalCount == 1)
        guard case .reviewTransfer = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .reviewTransfer retained at the bottom (only keystoneSign popped)")
            return
        }
    }

    // MOB-1496 (W2): same write point as the real round-trip above, but the simulator bypass never
    // pushes `scan` — `pendingKeystoneSchedule` reads the `.reviewTransfer` element one level below
    // `keystoneSign` instead of two.
    @MainActor @Test func keystoneSignSimulateSignatureForImmediateReviewContextRecordsCommittedScheduleAndReconciles() async {
        let recordCommittedScheduleCalls = LockIsolated<[(AccountUUID?, MigrationSchedule)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xEE]))]
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(1_245_800_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 0
        )
        var reviewState = MigrationReviewTransfer.State(mode: .immediate)
        reviewState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(reviewState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { accountUUID, schedule in
                recordCommittedScheduleCalls.withValue { $0.append((accountUUID, schedule)) }
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.simulateSignature)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(recordCommittedScheduleCalls.value.count == 1)
        #expect(recordCommittedScheduleCalls.value.first?.0 == Self.defaultAccount.id)
        #expect(recordCommittedScheduleCalls.value.first?.1 == schedule)
        #expect(reconcileCalls.value == 1)
    }

    @MainActor @Test func keystoneSignSimulateSignatureWithEmptyBatchFallsBackToPlaceholderAndResumesPlanCommit() async {
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            // MOB-1496 (W2): see `foundPCZTBatchForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant`'s comment.
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        // Unlike the real `.scan(.foundPCZTBatch([]))` path (which abandons the session — see
        // `foundPCZTBatchWithEmptyArrayForPlanCommitContextAbandonsSessionWithoutStoring` above),
        // the simulator bypass falls back to a single fabricated placeholder entry instead: this
        // button exists purely to exercise the resume chain for manual QA, never a real signing
        // session that could legitimately fail to decode.
        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.simulateSignature)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [[MigrationSignedTransferPczt(id: "simulated", pczt: Data())]])
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed on top of the retained .transferPlan element")
            return
        }
        guard case .transferPlan = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .transferPlan retained at the bottom (only keystoneSign popped)")
            return
        }
    }

    // MARK: - MOB-1496 (abandon reconciliation): keystoneScanAbandoned cancels a stray engine run
    //
    // The final engine creates a Keystone commit's WHOLE run (preps and schedule alike) the moment
    // its PCZTs are built (`proposeNoteSplitPCZTs`, called unconditionally by `proposeKeystoneBatch`),
    // and always resumes a stored non-terminal run on the next attempt, ignoring any newer preview.
    // `pendingKeystoneSigning` is only ever set once that build succeeds, so its presence when
    // `.keystoneScanAbandoned` fires means a stray run exists and must be cancelled — otherwise a
    // later re-entry would silently resume signing the same, by-then-stale PCZTs.

    @MainActor @Test func keystoneScanAbandonedWithPendingCeremonyCancelsStrayMigrationRunExactlyOnce() async {
        let restartCalls = LockIsolated<[(AccountUUID, Bool)]>([])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { accountUUID, includeResidual in
                restartCalls.withValue { $0.append((accountUUID, includeResidual)) }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
            }
        }
        store.exhaustivity = .off

        await store.send(.keystoneScanAbandoned)

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (keystoneSign removed)")
            return
        }
        #expect(restartCalls.value.count == 1)
        #expect(restartCalls.value.first?.0 == Self.defaultAccount.id)
        // `includeResidual: false` — matches `MigrationRecovery`'s `.recreate` restart, the other
        // live caller of this member.
        #expect(restartCalls.value.first?.1 == false)
    }

    /// Twin of the test above with NO ceremony context — abandoning a batch that was never actually
    /// proposed (defensive; not reachable via any live `.keystoneScanAbandoned` sender today, all of
    /// which already confirmed `pendingKeystoneSigning != nil` before sending it) must never call
    /// `restartCurrentMigrationStep` — there is no stray run to cancel.
    @MainActor @Test func keystoneScanAbandonedWithNoPendingCeremonyNeverCancelsMigrationRun() async {
        let restartCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = nil
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _, _ in
                restartCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0)
            }
        }
        store.exhaustivity = .off

        await store.send(.keystoneScanAbandoned)

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        #expect(restartCalls.value == 0)
    }

    // MARK: - MOB-1496 (W6 §3): Keystone dust lane ("Migrate anyway" over Migration Complete)

    @MainActor @Test func completeMigrateAnywayWithKeystoneAccountProposesPCZTsAndPushesKeystoneSignContext() async {
        let proposeTransfersCalls = LockIsolated<[Bool]>([])
        let proposePCZTsCalls = LockIsolated<[MigrationSchedule]>([])
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "dust0", amount: Zatoshi(12_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let pczts: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "dust0", pczt: Data([0xDD]))]
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 20) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _, includeResidual in
                proposeTransfersCalls.withValue { $0.append(includeResidual) }
                return schedule
            }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, proposed in
                proposePCZTsCalls.withValue { $0.append(proposed) }
                return pczts
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.keystoneDustPCZTsProposed)

        // `includeResidual: true` — the dust lane proposes the residual-inclusive schedule.
        #expect(proposeTransfersCalls.value == [true])
        #expect(proposePCZTsCalls.value == [schedule])
        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.dust(schedule))
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top of .complete")
            return
        }
        #expect(signState.pczts == pczts)
    }

    /// Empty-residual edge (§4): below-threshold falls back to the SAME existing failure UX the
    /// (already-shipped) software dust lane's empty-schedule path uses — no new screen/copy, and the
    /// coordinator never even reaches the PCZT-proposal step.
    @MainActor @Test func completeMigrateAnywayWithKeystoneAccountAndEmptyResidualFallsBackToBelowThresholdSending() async {
        let proposePCZTsCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 22) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeMigrationTransfers = { _, _ in MigrationSchedule(transfers: [], estimatedDurationHours: 0) }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in
                proposePCZTsCalls.withValue { $0 += 1 }
                return []
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.pushHydratedPathState)

        #expect(proposePCZTsCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the existing below-threshold Sending fallback pushed")
            return
        }
        #expect(sendingState.isDustLane == true)
    }

    /// Software dust is byte-for-byte unchanged — twin of the pre-existing
    /// `completeMigrateAnywayPushesSendingConfiguredForDustLane` above, restated here explicitly
    /// alongside the new Keystone fork so the vendor split is visible in one place.
    @MainActor @Test func completeMigrateAnywayWithSoftwareAccountPushesSendingConfiguredForDustLaneUnchanged() async {
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 24) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of .complete")
            return
        }
        #expect(sendingState.totalCount == 1)
        #expect(sendingState.isDustLane == true)
        #expect(store.state.pendingKeystoneSigning == nil)
    }

    /// Full lane, sign-context-to-store half: once the batch-of-1 is scanned+stored, the coordinator
    /// hands off to the dust Sending lane's EXISTING `executeNextPendingMigrationTransfer` path
    /// (`isDustLane: false`) — never `migrateMigrationDust` (a USK composite that would re-propose
    /// from scratch). The execute-with-snapshot-options / never-touches-USK half of this lane is
    /// covered by `MigrationSendingTests`' `onAppearWithoutDustLaneAndKeystoneAccountExecutes...`.
    @MainActor @Test func keystoneDustFoundPCZTBatchStoresAndPushesSendingConfiguredForExecuteNotDustComposite() async {
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let recordCommittedScheduleCalls = LockIsolated<[MigrationSchedule]>([])
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "dust0", amount: Zatoshi(12_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 0
        )
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "dust0", pczt: Data([0xDD]))]
        let signed: [Data] = [Data([0xDD, 0x01])]
        let expectedStored: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "dust0", pczt: Data([0xDD, 0x01]))]

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 23) }
        state.pendingKeystoneSigning = MigrationCoordFlow.KeystoneSigningContext.dust(schedule)
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            $0.migrationManager.recordCommittedSchedule = { _, schedule in recordCommittedScheduleCalls.withValue { $0.append(schedule) } }
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [expectedStored])
        #expect(recordCommittedScheduleCalls.value == [schedule])
        #expect(store.state.pendingKeystoneSigning == nil)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of the retained .complete element")
            return
        }
        #expect(sendingState.isDustLane == false)
        #expect(sendingState.totalCount == 1)
        guard case .complete = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .complete retained at the bottom")
            return
        }
    }

    // MARK: - MOB-1496 (W6 §6): Keystone recovery — recreate routes through the PCZT batch session

    /// Recovery -> `.recreate` -> `restartCurrentMigrationStep` -> re-created plan -> confirm: for a
    /// Keystone account this must route through the SAME PCZT batch session the fresh-entry plan
    /// uses (`MigrationTransferPlanStore.confirmTapped` already forks on vendor before signing —
    /// this proves the COORDINATOR side of that round trip, from the recreated plan's
    /// `keystoneSignRequested` delegate through to a committed, scheduled store).
    @MainActor @Test func recoveryRecreateForKeystoneAccountRoutesThroughKeystoneBatchSessionToStoreAndSchedule() async {
        let restartCalls = LockIsolated<Int>(0)
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let recordCommittedScheduleCalls = LockIsolated<[MigrationSchedule]>([])
        let restartedSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "r0", amount: Zatoshi(2_000_000), anchorHeight: 300, nextExecutableAfterHeight: 300, expiryHeight: 400)
            ],
            estimatedDurationHours: 12
        )
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "r0", pczt: Data([0x11]))]
        let signed: [Data] = [Data([0x11, 0x99])]
        let expectedStored: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "r0", pczt: Data([0x11, 0x99]))]

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 30) }
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _, _ in
                restartCalls.withValue { $0 += 1 }
                return restartedSchedule
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordCommittedSchedule = { _, schedule in recordCommittedScheduleCalls.withValue { $0.append(schedule) } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.pushHydratedPathState)

        #expect(restartCalls.value == 1)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan (recreated, injected schedule) pushed")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.recreated)
        #expect(planState.injectedSchedule == restartedSchedule)

        guard let planId = store.state.path.ids.last else {
            Issue.record("Expected a TransferPlan element id")
            return
        }
        // The real view's `onAppear` populates `.schedule` from `.injectedSchedule` (this test drives
        // the coordinator directly, without a live view) — needed below so `pendingKeystoneSchedule`
        // has something to hand `recordCommittedSchedule` at store time, same as a real run.
        await store.send(.path(.element(id: planId, action: .transferPlan(.onAppear))))

        // The recreated plan's OWN store (`MigrationTransferPlanStore`) is what forks on vendor and
        // delegates `.keystoneSignRequested` — simulate that delegate landing, since this test's
        // scope is the COORDINATOR's routing from there onward (covered end-to-end for the fresh-plan
        // case already; `MigrationTransferPlanTests` covers the store-side fork itself, including the
        // `.recreated` variant specifically).
        guard store.state.path.ids.last == planId else {
            Issue.record("Expected the TransferPlan element to still be on top")
            return
        }
        await store.send(.path(.element(id: planId, action: .transferPlan(.delegate(.keystoneSignRequested(unsigned))))))

        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.planCommit)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed")
            return
        }
        #expect(signState.pczts == unsigned)

        guard let signId = store.state.path.ids.last else {
            Issue.record("Expected a KeystoneSign element id")
            return
        }
        await store.send(.path(.element(id: signId, action: .keystoneSign(.delegate(.getSignature)))))

        guard let scanId = store.state.path.ids.last else {
            Issue.record("Expected a Scan element id")
            return
        }
        await store.send(.path(.element(id: scanId, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)

        #expect(storeCalls.value == [expectedStored])
        #expect(recordCommittedScheduleCalls.value == [restartedSchedule])
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled — the recreated plan's Keystone commit routes to the SAME post-commit chain as a fresh plan")
            return
        }
        guard case .transferPlan = try? #require(store.state.path[id: planId]) else {
            Issue.record("Expected the recreated .transferPlan retained beneath (never re-signs again)")
            return
        }
    }

    /// Confirms §1's fix generalizes to recreated plans too: "a restart never includes a note split"
    /// is NOT actually assumed anywhere — if the engine demands a split again after a restart, the
    /// sentinel still gets split out before the recreated schedule is stored, via the exact same
    /// mechanism a fresh plan uses (no vendor/flow-specific special-casing).
    @MainActor @Test func recoveryRecreateForKeystoneAccountWithNoteSplitSentinelStripsSentinelBeforeStoring() async {
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let storeSignedNoteSplitCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let restartedSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "r0", amount: Zatoshi(2_000_000), anchorHeight: 300, nextExecutableAfterHeight: 300, expiryHeight: 400)
            ],
            estimatedDurationHours: 12
        )
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x22])),
            MigrationUnsignedTransferPczt(id: "r0", pczt: Data([0x11]))
        ]
        let signed: [Data] = [Data([0x22, 0x99]), Data([0x11, 0x99])]

        var planState = MigrationTransferPlan.State(variant: .recreated)
        planState.injectedSchedule = restartedSchedule
        planState.schedule = restartedSchedule
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 31) }
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(planState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, signed in
                storeSignedNoteSplitCalls.withValue { $0.append(signed) }
            }
            $0.sdkSynchronizer.broadcastStoredNoteSplit = { _, _ in MigrationTransferResult.success(txId: "split-tx") }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZTBatch(signed)))))
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.path) // dispatched .noteSplit(.retryTapped)
        await store.receive(\.path) // .noteSplit(.splitResult(.success))
        await store.receive(\.path) // .noteSplit(.splitBroadcastSucceeded)
        await store.receive(\.path) // .noteSplit(.delegate(.storeScheduleRequested))
        await store.receive(\.path) // .noteSplit(.splitConfirmed) — the deferred store succeeded

        #expect(storeCalls.value == [[MigrationSignedTransferPczt(id: "r0", pczt: Data([0x11, 0x99]))]])
        #expect(storeSignedNoteSplitCalls.value == [[MigrationSignedTransferPczt(id: "p0", pczt: Data([0x22, 0x99]))]])
    }
}

// MARK: - MOB-1496 (W6 §2): re-pair validation + sentinel split — pure function table

/// `MigrationCoordFlow.rePairedKeystoneBatch`/`splitKeystoneBatch` are small, dependency-free pure
/// functions (see their docs in `MigrationCoordFlowCoordinator.swift`) — tested directly here rather
/// than only indirectly through the coordinator reducer, per the brief's "small pure function
/// (testable table)" ask. No shared/global state, so unserialized.
@Suite struct MigrationCoordFlowPureFunctionTests {
    // MARK: - rePairedKeystoneBatch: exact match / short / long / empty

    @Test func rePairedKeystoneBatchExactMatchZipsSignedBytesWithOriginalIdsByPosition() {
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB])),
            MigrationUnsignedTransferPczt(id: "t2", pczt: Data([0xCC]))
        ]
        let signed: [Data] = [Data([0x01]), Data([0x02]), Data([0x03])]

        let result = MigrationCoordFlow.rePairedKeystoneBatch(signed: signed, unsigned: unsigned)

        #expect(result == [
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0x01])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0x02])),
            MigrationSignedTransferPczt(id: "t2", pczt: Data([0x03]))
        ])
    }

    @Test func rePairedKeystoneBatchShortBatchReturnsNil() {
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB])),
            MigrationUnsignedTransferPczt(id: "t2", pczt: Data([0xCC]))
        ]
        let signed: [Data] = [Data([0x01]), Data([0x02])]

        #expect(MigrationCoordFlow.rePairedKeystoneBatch(signed: signed, unsigned: unsigned) == nil)
    }

    @Test func rePairedKeystoneBatchLongBatchReturnsNil() {
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))]
        let signed: [Data] = [Data([0x01]), Data([0x02])]

        #expect(MigrationCoordFlow.rePairedKeystoneBatch(signed: signed, unsigned: unsigned) == nil)
    }

    @Test func rePairedKeystoneBatchEmptyParseReturnsNil() {
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]

        #expect(MigrationCoordFlow.rePairedKeystoneBatch(signed: [], unsigned: unsigned) == nil)
    }

    @Test func rePairedKeystoneBatchEmptyBothReturnsNil() {
        #expect(MigrationCoordFlow.rePairedKeystoneBatch(signed: [], unsigned: []) == nil)
    }

    // MARK: - splitKeystoneBatch: prep prefix present (one or many) / absent

    @Test func splitKeystoneBatchSeparatesSentinelFromScheduleEntriesPreservingOrder() {
        let paired: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]

        let (prepEntries, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch(paired)

        #expect(prepEntries == [MigrationSignedTransferPczt(id: "p0", pczt: Data([0x01]))])
        #expect(scheduleEntries == [
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ])
    }

    /// MOB-1496 (final engine, plural preps): coverage 1 — the final engine can propose N preparation
    /// transactions, not just zero or one. A 3-prep + 2-schedule mixed batch must partition correctly,
    /// preserving each group's relative order and stripping every prep entry's sentinel prefix back
    /// down to its bare engine id.
    @Test func splitKeystoneBatchWithMultiplePrepsSeparatesAllOfThemFromScheduleEntriesPreservingOrder() {
        let paired: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationSignedTransferPczt(id: "note-split#p1", pczt: Data([0x02])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0xBB])),
            MigrationSignedTransferPczt(id: "note-split#p2", pczt: Data([0x03]))
        ]

        let (prepEntries, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch(paired)

        #expect(prepEntries == [
            MigrationSignedTransferPczt(id: "p0", pczt: Data([0x01])),
            MigrationSignedTransferPczt(id: "p1", pczt: Data([0x02])),
            MigrationSignedTransferPczt(id: "p2", pczt: Data([0x03]))
        ])
        #expect(scheduleEntries == [
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ])
    }

    @Test func splitKeystoneBatchWithNoSentinelReturnsNilSplitEntryAndAllScheduleEntries() {
        let paired: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationSignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]

        let (prepEntries, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch(paired)

        #expect(prepEntries.isEmpty)
        #expect(scheduleEntries == paired)
    }

    @Test func splitKeystoneBatchWithEmptyBatchReturnsNilSplitEntryAndEmptyScheduleEntries() {
        let (prepEntries, scheduleEntries) = MigrationCoordFlow.splitKeystoneBatch([])

        #expect(prepEntries.isEmpty)
        #expect(scheduleEntries.isEmpty)
    }
}
