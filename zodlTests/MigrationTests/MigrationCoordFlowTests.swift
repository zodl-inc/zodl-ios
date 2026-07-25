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
//  migration batch checker; `scan(.foundKeystoneBatchSignatures)` stores the signed PCZTs, pops `scan`+
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
//  MOB-1497 (R9-T3, finding 1): both flag-on shortcuts above (Entry `.immediate`, How This Works
//  `.continueTapped`) were blind to identity-custom — they persisted `useTor = true` and pushed
//  straight through even for a custom sync server, which forces clearnet at forming AND carries a
//  nil R13 footer by construction, so the user was silently routed over clearnet with no
//  unavailable-server notice ever shown. Both now detect identity-custom before skipping and detour
//  to the SAME unavailable-variant sheet the flag-off branch already presents, never persisting
//  anything on that detour (finding 6, same round: the sheet's own "Got it" persists nothing for a
//  custom server either) — `entryChoseImmediateWithTorFlagOnAndCustomServerDetoursToTorSheet` /
//  `...DetourThenGotItReachesReviewTransfer` and their How-This-Works twins
//  (`howItWorksContinuedWithTorFlagOnAndCustomServerDetoursToTorSheet` /
//  `...DetourThenGotItReachesTransferPlan`) cover the detour and its confirm continuation; the
//  non-custom pins above are unchanged.
//
//  `.serialized`: every `MigrationCoordFlow.State()` carries a `MigrationEntry.State` (`entryState`),
//  which reads the process-global `@Shared(.inMemory(.selectedWalletAccount))` on init — matching the
//  precedent in `MigrationEntryTests`, which mutates the same key directly.
//

import Testing
import Foundation
@preconcurrency import Combine
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

    /// MOB-1513: a firmware version at (not below) the migration batch-signing floor
    /// (`MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware`, 3.0.2) — the decode-envelope
    /// `firmwareVersion` every "happy path" ceremony test below passes to
    /// `.scan(.foundKeystoneBatchSignatures(data:firmwareVersion:))` so the firmware gate clears and
    /// the ceremony proceeds to apply. Tests that specifically exercise the gate itself live in
    /// `MigrationCoordFlowPureFunctionTests` below (the pure floor comparison) and this suite's own
    /// `foundKeystoneBatchSignatures...Firmware...` block. Unrelated to (and not to be confused
    /// with) the single-transaction Keystone flow's own gate, covered by `KeystoneFirmwareGateTests`
    /// (`SendTests/KeystoneFirmwareTests.swift`).
    private static let validKeystoneMigrationFirmware = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2)

    /// MOB-1496 (W6): `migrationManager.migrationNetworkOptions(_:)` has no macro default (unlike the
    /// SDK synchronizer's `.noOp`) — any test that reaches the note-split-broadcast or dust-execute
    /// branch must mock it explicitly or trip `unimplemented`. Same fixture shape as
    /// `MigrationTransferPlanTests`.
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

    /// MOB-1513: stubs `sdkSynchronizer.applyKeystoneBatchSignatures` to re-pair `signedBytes`
    /// against the passed `pczts` positionally, by index — the SAME zip this file's tests relied on
    /// `MigrationCoordFlow.rePairedKeystoneBatch` (app-side, removed) to do; now it's exactly what
    /// the real SDK call does internally, so a test-side stub of it is the right place for that
    /// pairing to happen. `signedBytes` plays the same fixture role the old `signed: [Data]`
    /// fixtures played pre-MOB-1513 — most call sites below keep that name.
    private func stubApply(
        _ signedBytes: [Data]
    ) -> @Sendable ([MigrationUnsignedTransferPczt], Data) async throws -> [MigrationSignedTransferPczt] {
        { pczts, _ in
            zip(pczts, signedBytes).map { MigrationSignedTransferPczt(id: $0.id, pczt: $1) }
        }
    }

    /// MOB-1497 (T2): a PROVIDER `MigrationNetworkSnapshot` fixture for `migrationManager
    /// .networkSnapshot` stubs — sync on `.zecRocks`, broadcast on `.stardust` at `host`, matching
    /// T1's cross-provider pairing (R6).
    private static func someProviderNetworkSnapshot(host: String = "eu.zec.stardust.rest") -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: false,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "na.zec.rocks", port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 443, secure: true),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// MOB-1497 (T2): an identity-CUSTOM `MigrationNetworkSnapshot` fixture — sync and broadcast on
    /// the SAME custom host (R2/R6: no separation possible), `useTor` forced false (T1's data-side R2).
    private static func someCustomNetworkSnapshot(host: String = "custom.example.org") -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: false,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 9067, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 9067, secure: true),
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
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: host, port: 443, secure: true),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Re-entry: .onAppear with empty path

    /// MOB-1513 (H3 guard): genuine flow start (`state.path.isEmpty`) synchronously records the
    /// selected account as this instance's owner (`presentedMigrationFlowAccountUUID`) and arms
    /// `migrationManager.setMigrationFlowPresented` for it — BEFORE the async re-entry lookup even
    /// resolves. Exhaustive `TestStore` (no `exhaustivity = .off`), so the state assertion below
    /// also proves this is the ONLY synchronous mutation `.onAppear` makes here.
    @MainActor @Test func onAppearWithEntryRouteAppendsNothing() async {
        let setMigrationFlowPresentedCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.reentryRoute = { .entry }
            $0.migrationManager.setMigrationFlowPresented = { accountUUID, isPresented in
                setMigrationFlowPresentedCalls.withValue { $0.append((accountUUID, isPresented)) }
            }
        }

        await store.send(.onAppear) {
            $0.presentedMigrationFlowAccountUUID = Self.defaultAccount.id
        }
        await store.receive(\.pushNextPermissionStep)

        #expect(store.state.path.isEmpty)
        #expect(setMigrationFlowPresentedCalls.value.count == 1)
        #expect(setMigrationFlowPresentedCalls.value.first?.0 == Self.defaultAccount.id)
        #expect(setMigrationFlowPresentedCalls.value.first?.1 == true)
    }

    /// Twin of the test above for the OTHER branch of the `state.path.isEmpty` guard: a re-entry
    /// that finds the path already non-empty (mid-flow, e.g. process death mid-run re-showing the
    /// same screen) returns `.none` before ever reaching the H3-guard wiring — no recording, no
    /// arming. Confirms the signal only ever arms at a GENUINE flow start, never on every
    /// `.onAppear` delivery.
    @MainActor @Test func onAppearWithNonEmptyPathDoesNotArmMigrationFlowPresentedSignal() async {
        let setMigrationFlowPresentedCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        var initialState = MigrationCoordFlow.State()
        initialState.path.append(.status(MigrationStatus.State(isFlowRoot: true)))

        let store = TestStore(initialState: initialState) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationFlowPresented = { accountUUID, isPresented in
                setMigrationFlowPresentedCalls.withValue { $0.append((accountUUID, isPresented)) }
            }
        }

        await store.send(.onAppear)

        #expect(setMigrationFlowPresentedCalls.value.isEmpty)
        #expect(store.state.presentedMigrationFlowAccountUUID == nil)
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
            // R7 final review, Important-1: same "hydrate every `.statusLoaded`-covered field at
            // re-entry too" precedent as `syncPrivacyBufferMinutes` above (avoids a one-frame flash
            // of "no Tor line" before `onAppear`'s own load lands) — `true` here so a stale default
            // (`false`) would visibly fail the new assertion below.
            $0.migrationManager.isMigrationTorHoldActive = { _ in true }
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
        #expect(statusState.isTorHoldActive == true)
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
        // R8-T5 (#13): `hoursFromNow: 0` here models the REAL value `MigrationDerivations.transferRows`
        // produces for a GENUINELY overdue row — MOB-1513 A3 replaced the old `nonSentPosition × 6`
        // placeholder cadence with a height-vs-tip ETA that floors to `0` once the row's height is
        // at-or-behind the tip (always true for the stalled row here), not `0` BY CONSTRUCTION for
        // every first non-sent row — no longer meaningful for `stalledHoursAgo` (see below); this
        // fixture used to hand-pick `5` here directly, which happened to mask the bug this row's real
        // construction has (the mock bypassed the real derivation entirely).
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
            // R7 final review, Important-1: see the twin comment in
            // `onAppearWithStatusProgressRouteAppendsFlowRootStatusScreen` above.
            $0.migrationManager.isMigrationTorHoldActive = { _ in true }
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
        #expect(statusState.isTorHoldActive == true)
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
    // of re-offering resolution. MOB-1496: `completeState(isFlowRoot:)` reads the balance-derived
    // `migrationLockedAmount()` for BOTH the `.locked` routing and the card's amount — after a
    // real lock, `migrationSummary().dust` re-plans from spendable notes and reads ZERO (the
    // locked notes are excluded), so the summary alone would render a "0 ZEC" locked card. This
    // pins the production re-entry shape: dust-less summary + nonzero locked value.
    @MainActor @Test func onAppearWithCompleteRouteAndLockedDustDerivesLockedDustResolution() async {
        let summary = MigrationSummary(
            transferred: Zatoshi(1_245_800_000),
            dust: Zatoshi.zero,
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
            $0.migrationManager.migrationLockedAmount = { _ in Zatoshi(800_000) }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .complete(completeState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .complete on the path")
            return
        }
        #expect(completeState.dustResolution == MigrationComplete.State.DustResolution.locked)
        #expect(completeState.dust == Zatoshi(800_000))
    }

    // MOB-1496: the counterpart — nothing locked leaves the summary's own dust in charge, so a
    // nonzero unlocked remainder still lands on the offered resolution with the summary amount.
    @MainActor @Test func onAppearWithCompleteRouteAndUnlockedDustKeepsSummaryAmount() async {
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
            $0.migrationManager.migrationLockedAmount = { _ in Zatoshi.zero }
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushNextPermissionStep)

        guard case let .complete(completeState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .complete on the path")
            return
        }
        #expect(completeState.dustResolution == MigrationComplete.State.DustResolution.offered)
        #expect(completeState.dust == Zatoshi(800_000))
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
            $0.migrationManager.setMigrationMode = { _, mode in setMigrationModeCalls.withValue { $0.append(mode) } }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { accountUUID in formNetworkSnapshotCalls.withValue { $0.append(accountUUID) } }
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
        // the only mode-setting call now.
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
    }

    /// MOB-1497 (R9-T3 fix, C1 — RED-FIRST ORDER PIN): the non-custom flag-on path must persist
    /// `setNetworkPrivacyOptions(true)` STRICTLY BEFORE `formNetworkSnapshot` — forming bakes in
    /// whatever is currently persisted (`MigrationNetworkSnapshot.useTor`'s doc: a LATER persist does
    /// NOT correct an already-formed snapshot), so a version that detected identity-custom by forming
    /// first (via `torSheetState`) could silently bake in a stale persisted OFF choice left over from
    /// an earlier off-warning pick — a silent clearnet migration broadcast with no sheet and no
    /// warning, the exact regression review C1 caught. The pin above
    /// (`entryChoseImmediateWithTorFlagOnSkipsTorSheetAndPushesReview`) cannot catch this: it only
    /// observes each call happened once, never their RELATIVE order. A single shared call-log both
    /// stubs append to pins the order itself.
    @MainActor @Test func entryChoseImmediateWithTorFlagOnAndNonCustomServerPersistsBeforeForming() async {
        enum CallLogEntry: Equatable {
            case persist(Bool)
            case form
        }
        let callLog = LockIsolated<[CallLogEntry]>([])
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _, _ in }
            $0.migrationManager.isSyncServerIdentityCustom = { false }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in callLog.withValue { $0.append(.persist(useTor)) } }
            $0.migrationManager.formNetworkSnapshot = { _ in callLog.withValue { $0.append(.form) } }
            $0.migrationManager.networkSnapshot = { _ in Self.someProviderNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.pushHydratedPathState)

        #expect(callLog.value == [CallLogEntry.persist(true), CallLogEntry.form])
    }

    /// MOB-1497 (R9-T3, finding 1): the custom-server twin of the flag-on pin above — its PREDECESSOR
    /// (`entryChoseImmediateWithTorFlagOnAndCustomServerSkipBranchFooterCarriesNoHost`) pinned the
    /// defect this fixes: custom + flag-on used to push Review directly, forcing clearnet with the
    /// R13 footer nil by construction (same-server) — so an identity-custom user was routed over
    /// clearnet with NO unavailable-server notice ever shown. Flag-on now detects identity-custom
    /// BEFORE skipping via the synchronous, snapshot-free `migrationManager
    /// .isSyncServerIdentityCustom()` (R9-T3 C1 fix — NOT `torSheetState`'s own `isCustomServer`,
    /// which requires forming first) and detours to that SAME unavailable-variant sheet the flag-OFF
    /// branch presents — never calling `setNetworkPrivacyOptions`, never pushing directly. `torSheetState`
    /// is still exercised here too, but only AFTER the detour decision, to build the sheet's own
    /// contents (toggle state) — hence `networkSnapshot` is still mocked as a custom snapshot
    /// alongside the new outer gate, so both agree on the same (consistent) custom-server account.
    @MainActor @Test func entryChoseImmediateWithTorFlagOnAndCustomServerDetoursToTorSheet() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _, _ in }
            $0.migrationManager.isSyncServerIdentityCustom = { true }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            $0.migrationManager.networkSnapshot = { _ in Self.someCustomNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.torSheetStateReady)

        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.pendingTorDestination == MigrationCoordFlow.PendingTorDestination.reviewTransfer)
        #expect(store.state.torSheetState.isCustomServer == true)
        // T1's data-side R2: forced false — no toggle exists to draw ON here either.
        #expect(store.state.torSheetState.isTorOn == false)
        // The detour never persists a choice — finding 6 (commit 1) already made the eventual
        // "Got it" persist nothing too; this pins that the detour itself never calls it either.
        #expect(setOptionsCalls.value.isEmpty)
        // Exactly one form — the outer detection gate never forms at all (C1 fix); `torSheetState`
        // forms once, to build the sheet's own contents once we already know to detour.
        #expect(formNetworkSnapshotCalls.value == 1)
        // Nothing pushed yet — the sheet gates the push until confirmed, same as the flag-off path.
        #expect(store.state.path.isEmpty)
    }

    /// MOB-1497 (R9-T3, finding 1): chains the detour above through to "Got it" — proves
    /// `confirmTorSheet`'s existing `.reviewTransfer` destination drives the flow onward to exactly
    /// the same screen the (pre-fix) skip would have reached, and that (finding 6) the confirm
    /// persists nothing along the way.
    @MainActor @Test func entryChoseImmediateWithTorFlagOnAndCustomServerDetourThenGotItReachesReviewTransfer() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _, _ in }
            $0.migrationManager.isSyncServerIdentityCustom = { true }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in }
            $0.migrationManager.networkSnapshot = { _ in Self.someCustomNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.torSheetStateReady)
        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.path.isEmpty)

        await store.send(.torSheet(.delegate(.gotIt)))
        // R10: explicitly consume the push before asserting on `path` — after the Q3'26 sheet
        // redesign the scoped TorSheet/Entry reducers return effects on this action path, and a
        // non-exhaustive `finish()` no longer reliably drains the buffered `pushHydratedPathState`
        // into state before the asserts below run. Receiving it pins the push itself, too.
        await store.receive(\.pushHydratedPathState)
        await store.finish()

        #expect(store.state.isTorSheetPresented == false)
        #expect(setOptionsCalls.value.isEmpty)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .reviewTransfer pushed on top (detour -> confirm reaches the same destination the skip would have)")
            return
        }
        #expect(reviewState.mode == MigrationReviewTransfer.State.Mode.immediate)
    }

    @MainActor @Test func entryChoseImmediateWithTorFlagOffPresentsTorSheetAndStashesReviewDestination() async {
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _, _ in }
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
        // MOB-1497 (T2): provider — the toggle sheet variant (not the no-toggle unavailable one).
        // (T3: `torSheetState` no longer carries the formed host — see the R13 footer tests below.)
        #expect(store.state.torSheetState.isCustomServer == false)
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
            $0.migrationManager.setMigrationMode = { _, _ in }
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
        // T1's data-side R2: forced false — no toggle exists to draw ON here either.
        #expect(store.state.torSheetState.isTorOn == false)
        #expect(store.state.torSheetState.usesFullBalanceCopy == true)
    }

    /// A testnet / defensive same-server-fallback snapshot classifies as a normal provider
    /// (`isCustomServer == false` — NOT identity-custom) yet shares one server end to end
    /// (`broadcastProvider == syncProvider`). It must still present the TOGGLE variant, not the
    /// no-toggle unavailable one (unlike identity-custom).
    ///
    /// MOB-1497 (T4): the R13 broadcast-server disclosure is fully retired (sheet line removed in T3,
    /// the Transfer Plan / Review Transfer footers removed here in T4), so there is no longer any
    /// same-server-vs-different-server distinction to pin — the twin footer tests that once carried
    /// that half of the original pin are gone with the feature. What remains real is narrower: the
    /// toggle-variant classification for a same-server non-custom snapshot.
    @MainActor @Test func entryChoseImmediateWithTorFlagOffAndSameServerNonCustomPresentsToggleVariant() async {
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _, _ in }
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
    }

    /// MOB-1497 (T2/T4): re-entering the Tor sheet re-forms the run's provisional network snapshot —
    /// the per-presentation "re-form when provisional" rule doubles as the per-presentation re-roll
    /// (`torSheetState` calls `formNetworkSnapshot` every time it presents, so a fresh sheet always
    /// reflects a fresh roll). Asserted via a `formNetworkSnapshot` call-count spy: once after one
    /// presentation, twice after two. Re-triggers presentation directly (no intervening confirm) —
    /// `.entry(.chose(.immediate))` re-presents unconditionally, exactly what re-entering Entry and
    /// picking immediate again would do after backing out. (Restores a regression test lost in T3,
    /// when the `broadcastHost` observable it originally pinned was deleted — re-expressed against
    /// the forming call itself, which is the actual production rule the deleted host observable stood
    /// in for.)
    @MainActor @Test func presentingTorSheetASecondTimeReFormsTheNetworkSnapshot() async {
        let formNetworkSnapshotCalls = LockIsolated<Int>(0)
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setMigrationMode = { _, _ in }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            $0.migrationManager.networkSnapshot = { _ in Self.someProviderNetworkSnapshot() }
            $0.sdkSynchronizer = .noOp
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { false }
        }
        store.exhaustivity = .off

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.torSheetStateReady)
        #expect(formNetworkSnapshotCalls.value == 1)

        await store.send(.entry(.delegate(.chose(.immediate))))
        await store.receive(\.torSheetStateReady)
        #expect(formNetworkSnapshotCalls.value == 2)
    }

    // MARK: - Tor bottom sheet (MOB-1478 W2): "Got it" and swipe-dismiss resume the stashed destination

    @MainActor @Test func torSheetGotItInImmediateModePersistsOptionsAndPushesReviewTransfer() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let formNetworkSnapshotCalls = LockIsolated<[AccountUUID?]>([])
        let confirmProvisionalCalls = LockIsolated<[(AccountUUID?, Bool)]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: true)
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
        // The `.reviewTransfer` case dispatches its push via `pushHydratedPathState` (kept symmetric
        // with the `.permissionChain` case) — must be received for its state write to apply.
        await store.receive(\.pushHydratedPathState)

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
    }

    /// MOB-1497 (R9-T3, finding 6): the identity-custom "Got it" (single acknowledge CTA, §2 of
    /// the brief) now persists NOTHING — neither `setNetworkPrivacyOptions` nor
    /// `confirmProvisionalTorChoice` — since the custom sheet offers no choice: its forced
    /// `isTorOn == false` is a circumstance of being on a custom server, not a preference the user
    /// picked. Persisting it would silently overwrite the stored cross-run preference (default ON,
    /// or an earlier explicit provider choice) the moment the user later switches to a provider
    /// server. Renamed from `torSheetGotItForCustomServerDoesNotCallConfirmProvisionalTorChoice`:
    /// pre-fix, only `confirmProvisionalTorChoice` was skipped, while `setNetworkPrivacyOptions`
    /// still ran and persisted the forced `false` — the exact defect this fixes.
    @MainActor @Test func torSheetGotItForCustomServerPersistsNothing() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let confirmProvisionalCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: false, isCustomServer: true)
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
        await store.receive(\.pushHydratedPathState)

        #expect(setOptionsCalls.value == [])
        #expect(confirmProvisionalCalls.value == 0)
        // Custom "Got it" still advances to Review Transfer, same as any provider confirm.
        guard case .reviewTransfer = store.state.path.last else {
            Issue.record("Expected .reviewTransfer pushed on top")
            return
        }
    }

    /// MOB-1497 (T4): the custom-server Tor sheet's "Switch Server" delegate must LEAVE the migration
    /// flow — dismiss the sheet, drop the stashed destination, signal `Root` via `switchServerRequested`
    /// — and persist NOTHING for the abandoned attempt (no `setNetworkPrivacyOptions`, no
    /// `confirmProvisionalTorChoice`; the run's snapshot stays provisional for Root's teardown to
    /// discard). Nothing is pushed onto the coordinator's own `path`.
    @MainActor @Test func switchServerDelegateDismissesSheetAndSignalsRootWithoutPersisting() async {
        let setOptionsCalls = LockIsolated<Int>(0)
        let confirmProvisionalCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: false, isCustomServer: true)
        state.isTorSheetPresented = true
        state.pendingTorDestination = .reviewTransfer
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { _ in setOptionsCalls.withValue { $0 += 1 } }
            $0.migrationManager.confirmProvisionalTorChoice = { _, _ in confirmProvisionalCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.torSheet(.delegate(.switchServer)))
        await store.receive(\.switchServerRequested)

        #expect(store.state.isTorSheetPresented == false)
        #expect(store.state.pendingTorDestination == nil)
        #expect(store.state.path.isEmpty)
        // Nothing persisted for the abandoned attempt — the snapshot stays provisional.
        #expect(setOptionsCalls.value == 0)
        #expect(confirmProvisionalCalls.value == 0)
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
        await store.receive(\.pushHydratedPathState)

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

    /// MOB-1497 (R9-T3, finding 6): the identity-custom twin of the ON case above — R12's
    /// disclosure already stood in for the warning, so a custom swipe still advances exactly like
    /// an explicit custom "Got it" (same `confirmTorSheet` path), but now persists NOTHING —
    /// neither `setNetworkPrivacyOptions` nor `confirmProvisionalTorChoice` — same reasoning as
    /// `torSheetGotItForCustomServerPersistsNothing`. Renamed from
    /// `torSheetSwipeDismissForCustomServerPersistsAndAdvancesWithoutConfirmProvisionalCall`, which
    /// pinned the pre-fix behavior of still persisting the forced `false` via
    /// `setNetworkPrivacyOptions`.
    @MainActor @Test func torSheetSwipeDismissForCustomServerPersistsNothingAndAdvances() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        let confirmProvisionalCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.torSheetState = MigrationTorSheet.State(isTorOn: false, isCustomServer: true)
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
        await store.receive(\.pushHydratedPathState)

        #expect(setOptionsCalls.value == [])
        #expect(confirmProvisionalCalls.value == 0)
        guard case .reviewTransfer = store.state.path.last else {
            Issue.record("Expected .reviewTransfer pushed on top (identity-custom swipe still advances)")
            return
        }
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
        state.torSheetState = MigrationTorSheet.State()
        state.isTorSheetPresented = true
        state.pendingTorDestination = .permissionChain
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            $0.migrationManager.confirmProvisionalTorChoice = { _, useTor in confirmProvisionalCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.isManualDelivery = { _ in false }
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
            $0.migrationManager.isManualDelivery = { _ in true }
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

    /// MOB-1497 (T8, fix-wave 1, review Finding 1 — Important): the coordinator threading of
    /// `MigrationSending.State.isManualStepLane` (added in T8) was untested beyond the state-level
    /// `sentSubtitle` mapping — an inverted peek in the `.reviewTransfer(.delegate(.confirmed))`
    /// handler below would have slipped through unnoticed. Manual-lane half of the pair: a
    /// `.manualStep` review confirm must push `.sending` with `isManualStepLane == true`.
    @MainActor @Test func reviewTransferConfirmedWithManualStepModePushesSendingWithIsManualStepLaneTrue() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .manualStep(number: 2, total: 5))))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.confirmed)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top")
            return
        }
        #expect(sendingState.isManualStepLane == true)
    }

    /// Immediate-lane counterpart of the test above — the SAME peek (`state.path.last`'s
    /// `MigrationReviewTransfer.State.Mode`) must resolve `false` for an `.immediate` review confirm,
    /// keeping the one-shot-sweep lane on the "migrated" success wording.
    @MainActor @Test func reviewTransferConfirmedWithImmediateModePushesSendingWithIsManualStepLaneFalse() async {
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
        #expect(sendingState.isManualStepLane == false)
    }

    /// MOB-1513: the software immediate lane's `ImmediateMigrationProposal` must thread through into
    /// the pushed `MigrationSending.State` — that screen's `onAppear` performs the actual
    /// create+sign+submit and needs the proposal to do it (see `MigrationSendingStore`'s header doc).
    @MainActor @Test func reviewTransferConfirmedWithImmediateModeThreadsImmediateProposalIntoSendingState() async {
        let proposal = ImmediateMigrationProposal(
            proposal: .testOnlyFakeProposal(totalFee: 15_000),
            amount: Zatoshi(1_245_800_000),
            fee: Zatoshi(15_000)
        )
        var reviewState = MigrationReviewTransfer.State(mode: .immediate)
        reviewState.immediateProposal = proposal
        var state = MigrationCoordFlow.State()
        state.mode = .immediate
        state.path.append(.reviewTransfer(reviewState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.confirmed)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top")
            return
        }
        #expect(sendingState.immediateProposal == proposal)
    }

    /// Twin of the test above: a manual-step confirm must NOT thread any proposal (manual transfers
    /// were already signed at plan commit and have no `ImmediateMigrationProposal` at all).
    @MainActor @Test func reviewTransferConfirmedWithManualStepModeNeverThreadsAnImmediateProposal() async {
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .manualStep(number: 2, total: 5))))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.confirmed)))))

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top")
            return
        }
        #expect(sendingState.immediateProposal == nil)
    }

    // MARK: - MOB-1468: Keystone signing — signRequested sets context + pushes keystoneSign

    @MainActor @Test func transferPlanKeystoneSignRequestedSetsPlanCommitContextAndPushesKeystoneSign() async {
        let account = walletAccount(keystone: true, idByte: 21)
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = account }
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
        // MOB-1509: the ceremony's OWNER is recorded beside the context — external teardowns
        // cancel the stranded run on this account even after the selection has moved on.
        #expect(store.state.pendingKeystoneSigningAccountUUID == account.id)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        #expect(signState.pczts == pczts)
    }

    /// MOB-1513 (R8): the immediate lane's delegate carries the (unsigned, redacted) pair and the
    /// pushed `keystoneSign` enters SINGLE-PCZT mode — `redactedSinglePczt` set for the production
    /// `urEncoderForPCZT` QR, `pczts` carrying the unredacted original the post-scan submit reads.
    @MainActor @Test func reviewTransferKeystoneImmediateSignRequestedSetsImmediateReviewContextAndPushesSinglePcztKeystoneSign() async {
        let account = walletAccount(keystone: true, idByte: 22)
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        let unsigned = Data([0xCC])
        let redacted = Data([0xCC, 0x0F])
        await store.send(.path(.element(id: 0, action: .reviewTransfer(.delegate(.keystoneImmediateSignRequested(unsigned: unsigned, redacted: redacted))))))

        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.immediateReview)
        // MOB-1509: owner recorded beside the context (see the planCommit twin above).
        #expect(store.state.pendingKeystoneSigningAccountUUID == account.id)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top")
            return
        }
        #expect(signState.pczts == [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: unsigned)])
        #expect(signState.redactedSinglePczt == redacted)
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

    // MARK: - MOB-1468: Keystone signing — foundKeystoneBatchSignatures resumes planCommit (shared post-confirm chain)

    @MainActor @Test func foundKeystoneBatchSignaturesForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant() async {
        let callOrder = LockIsolated<[String]>([])
        // MOB-1513: `applyKeystoneBatchSignatures` returns the paired `[MigrationSignedTransferPczt]`
        // directly now (the app-side zip this comment used to describe, `rePairedKeystoneBatch`, is
        // gone) — `stubApply` reproduces the SAME positional pairing as a test double of that SDK
        // call.
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                #expect(stored == expectedStored)
                callOrder.withValue { $0.append("store") }
            }
            // MOB-1513 (B4): the post-confirm first-delivery kick runs after landing on Scheduled
            // — a nil next-due keeps it a silent no-op here.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationBGScheduler.scheduleFirstWindow = { callOrder.withValue { $0.append("scheduleFirstWindow") } }
            // MOB-1496 (W2): a successful store now also reconciles — explicit no-op override
            // since swift-dependencies requires `migrationManager` to be customized at least once
            // before any of its members can run in a test context (this fixture's `.transferPlan`
            // carries no `.schedule`, so `recordCommittedSchedule` itself is never reached).
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
            // MOB-1458 (W-E): the post-commit chain now hydrates `.scheduled` via
            // `migrationManager.migrationSummary` before pushing — harmless zero, unasserted here
            // (this test is about the Keystone store/pop/push plumbing, not the hydrated numbers;
            // see `MigrationScheduled`-hydration tests below for those).
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        // MOB-1458 (W-E): the post-commit `.scheduled` push is now hydrated (an async peek), so it
        // lands via its own `pushHydratedPathState` action rather than synchronously inside the
        // `keystoneSigningSubmitted` handler — see `transferPlanPostConfirmChain`'s doc.
        await store.receive(\.pushHydratedPathState)
        await store.finish()

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

    /// MOB-1513 (R10): the scan screen's "Signing…" hold — the coordinator arms
    /// `Scan.State.isKeystoneSigningInProgress` on the `scan` element the INSTANT the scheduled/
    /// recovery lanes' post-scan leg (apply + store) starts, since that element stays on top for the
    /// whole leg. Cloned setup from `foundKeystoneBatchSignaturesForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant`
    /// above — this test only adds the new flag assertion to the send closure.
    @MainActor @Test func foundKeystoneBatchSignaturesArmsScanSigningHoldOnTheScanElement() async {
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
    }

    /// MOB-1513 (final review, I-1 fix): the late-frame duplicate-completion race — the camera
    /// forwards every metadata callback (`ScanUIView`) regardless of ceremony state, and `Scan`'s own
    /// intake gate only flips once this action's OWN async apply effect result lands, so a second
    /// `.foundKeystoneBatchSignatures` for the SAME ceremony can reach the coordinator before the
    /// first one's apply/store chain resolves. `keystoneBatchApplyInFlight` makes the completion
    /// one-shot: the second delivery must be DROPPED (no state change, no effect) rather than
    /// double-applying and double-storing, while the first delivery's own chain proceeds exactly like
    /// the happy path above (`...StoresPopsAndPushesScheduledForScheduledVariant`) — one apply call,
    /// one store call.
    @MainActor @Test func foundKeystoneBatchSignaturesSentTwiceInARowAppliesAndStoresExactlyOnceDroppingTheDuplicate() async {
        let applyCalls = LockIsolated<Int>(0)
        let storeCalls = LockIsolated<Int>(0)
        // MOB-1513 (final review, I-1 fix): holds the FIRST apply call suspended so the second
        // (duplicate) send below is guaranteed to land while `keystoneBatchApplyInFlight` is still
        // `true` — same release-gate idiom as `MigrationReviewTransferTests
        // .confirmTappedKeystoneSetsIsConfirmingAndIgnoresSecondTapWhilePcztBuildInFlight`.
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = { pczts, data in
                applyCalls.withValue { $0 += 1 }
                for await _ in releaseStream { break }
                return zip(pczts, signed).map { MigrationSignedTransferPczt(id: $0.id, pczt: $1) }
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in
                storeCalls.withValue { $0 += 1 }
            }
            // MOB-1513 (B4): the post-confirm first-delivery kick runs after landing on Scheduled —
            // a nil next-due keeps it a silent no-op here, same as the happy-path test above.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
        }
        store.exhaustivity = .off

        let foundSignatures = MigrationCoordFlow.Action.path(
            .element(
                id: 2,
                action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
            )
        )

        // First delivery: passes the guard, arms it, dispatches the apply effect — which suspends on
        // `releaseStream` before returning, so it's still in flight for everything below.
        await store.send(foundSignatures) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        #expect(store.state.keystoneBatchApplyInFlight == true)
        let stateAfterFirstDelivery = store.state

        // Second delivery (the late-frame duplicate): the guard is already armed, so this is
        // DROPPED — no state change, no effect, and (per the finding) never routed through
        // `keystoneScanAbandoned` either.
        await store.send(foundSignatures)
        #expect(store.state == stateAfterFirstDelivery)

        // Release the first (and only) apply call to let the ceremony's chain proceed.
        releaseContinuation.yield()
        releaseContinuation.finish()

        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.finish()

        #expect(applyCalls.value == 1)
        #expect(storeCalls.value == 1)
        #expect(store.state.keystoneBatchApplyInFlight == false)
        #expect(store.state.pendingKeystoneSigning == nil)
    }

    // MOB-1496 (W2): the Keystone store-success write point — `recordCommittedSchedule` reads the
    // schedule off the `.transferPlan` element still beneath `keystoneSign`+`scan` at store time
    // (before `resumeAfterKeystoneSigning` pops back up to it), and `reconcile()` runs alongside.
    @MainActor @Test func foundKeystoneBatchSignaturesForPlanCommitContextRecordsCommittedScheduleAndReconciles() async {
        let recordCommittedScheduleCalls = LockIsolated<[(AccountUUID?, MigrationSchedule)]>([])
        let reconcileCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))]
        let signed: [Data] = [Data([0xAA, 0x01])]
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24,
                    proposalHandle: 1
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            // MOB-1513 (B4): kick stubs — a nil next-due keeps the post-landing kick a silent no-op.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.recordCommittedSchedule = { accountUUID, schedule in
                recordCommittedScheduleCalls.withValue { $0.append((accountUUID, schedule)) }
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.finish()

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
    @MainActor @Test func foundKeystoneBatchSignaturesForPlanCommitContextAbandonsSessionWithoutSubmittingWhenStoreFails() async {
        struct StoreFailure: Error { }
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let reconcileCalls = LockIsolated<Int>(0)
        let scheduleFirstWindowCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))]
        let signed: [Data] = [Data([0xAA, 0x01])]
        var planState = MigrationTransferPlan.State(variant: .scheduled)
        planState.schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(1), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 1,
                    proposalHandle: 1
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in throw StoreFailure() }
            $0.migrationBGScheduler.scheduleFirstWindow = { scheduleFirstWindowCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
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

    // MARK: - MOB-1513 (B4): Keystone signing — preps stored at ceremony, schedule deferred to the kick
    //
    // The latent real-SDK break the sentinel split fixes stays: `storeSignedMigrationTransactions`
    // is all-or-nothing and keyed by engine-issued transfer ids — a sentinel-prefixed id is not an
    // engine id, so the real engine would reject the WHOLE store if a prep rode along. Preps are
    // still split out (ids stripped) and stored via `storeSignedNoteSplits` at ceremony end (C-1
    // order: preps first). MOB-1513 (B4) re-homes everything AFTER that store: there is no
    // "Splitting Funds" screen any more — the flow resumes straight to B9 Migration Scheduled, the
    // coordinator's first-delivery kick broadcasts the first prep over the existing next-due lane
    // (`executeNextPendingMigrationTransfer`), and the deferred schedule store (C-1b: only after a
    // prep broadcast succeeds) runs inside that same kick, releasing `pendingKeystoneScheduleStore`
    // via `.deferredKeystoneScheduleStored`. A kick failure is SILENT: the run stays
    // `splitPendingConfirmation` (progress banner/route) and BG windows/foreground reconcile retry
    // the prep naturally.

    @MainActor @Test func foundKeystoneBatchSignaturesWithNoteSplitSentinelStoresOnlyEngineIdPairs() async {
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        let signed: [Data] = [
            Data([0x01, 0x99]),
            Data([0xAA, 0x99]),
            Data([0xBB, 0x99])
        ]
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "prep-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        // The kick's deferred schedule store ran only AFTER its prep broadcast landed.
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(storeCalls.value == [expectedStored])
        #expect(store.state.pendingKeystoneScheduleStore == nil)
    }

    /// MOB-1496 (final engine, plural preps): coverage 1 — a real ceremony batch can carry N > 1
    /// preparation entries (the final engine builds N preparation transactions, not one split
    /// transaction). Three sentinel-prefixed preps interleaved with two schedule entries must all
    /// route to `storeSignedNoteSplits` as one 3-element array, ids stripped back to their bare engine
    /// form, while the two schedule entries reach the (kick-deferred) `storeSignedMigrationTransactions`
    /// store untouched — twin of `foundKeystoneBatchSignaturesWithNoteSplitSentinelStoresOnlyEngineIdPairs` above,
    /// generalized from N=1 to N=3 preps.
    @MainActor @Test func foundKeystoneBatchSignaturesWithMultipleNoteSplitPrepsStoresAllOfThemAsOneArrayAndScheduleSeparately() async {
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
            Data([0x01, 0x99]),
            Data([0xAA, 0x99]),
            Data([0x02, 0x99]),
            Data([0xBB, 0x99]),
            Data([0x03, 0x99])
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, signed in
                storePrepsCalls.withValue { $0.append(signed) }
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeScheduleCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "prep-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(storePrepsCalls.value == [expectedPreps])
        #expect(storeScheduleCalls.value == [expectedSchedule])
    }

    /// MOB-1513 (R8 finding 1): the SDK's batch-apply FFI numeric-parses every id it receives, so
    /// the ceremony must hand it SANITIZED ids — the `note-split#` sentinel stripped down to the
    /// bare (numeric) engine id — and re-attach the original sentinel ids to the result before any
    /// downstream consumer sees it. This test captures the ids that actually cross the SDK
    /// boundary AND re-asserts the downstream split still sees the sentinel round-tripped.
    @MainActor @Test func foundKeystoneBatchSignaturesSanitizesSentinelIdsForApplyAndRestoresThemDownstream() async {
        let applyReceivedIds = LockIsolated<[[String]]>([])
        let storePrepsCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let storeScheduleCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#7", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "12", pczt: Data([0xAA]))
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = { pczts, _ in
                applyReceivedIds.withValue { $0.append(pczts.map(\.id)) }
                return zip(pczts, signed).map { MigrationSignedTransferPczt(id: $0.id, pczt: $1) }
            }
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, stored in
                storePrepsCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeScheduleCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "prep-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)

        // The SDK boundary saw ONLY numeric-parseable ids...
        #expect(applyReceivedIds.value == [["7", "12"]])
        // ...while the downstream split still received the sentinel-prefixed original, stripped
        // exactly once by `splitKeystoneBatch` as always.
        #expect(storePrepsCalls.value == [[MigrationSignedTransferPczt(id: "7", pczt: Data([0x01, 0x99]))]])
        #expect(storeScheduleCalls.value == [[MigrationSignedTransferPczt(id: "12", pczt: Data([0xAA, 0x99]))]])
    }

    // MARK: - MOB-1513 (R9): capped multi-round Keystone batch ceremony

    /// MOB-1513 (R9): a batch beyond `KeystoneBatchChunking.maxItemsPerRound` (32) arms round 0
    /// over the FIRST slice only, with the rounds bookkeeping holding the full batch — the
    /// device-safety cap the R5 rewire dropped, restored.
    @MainActor @Test func keystoneSignRequestedBeyondCapArmsRoundZeroSliceOnly() async {
        let all = Self.roundFixturePczts(count: 65)
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.keystoneSignRequested(all))))))

        #expect(store.state.pendingKeystoneSigning == .planCommit)
        #expect(store.state.keystoneBatchRounds?.allPczts.count == 65)
        #expect(store.state.keystoneBatchRounds?.roundIndex == 0)
        #expect(store.state.keystoneBatchRounds?.accumulatedSigned.isEmpty == true)
        #expect(store.state.path.count == 2)
        guard case let .keystoneSign(signState)? = store.state.path.last else {
            Issue.record("Expected keystoneSign armed with round 0's slice")
            return
        }
        #expect(signState.pczts.map(\.id) == (0..<32).map { "t\($0)" })
        #expect(signState.roundIndex == 0)
        #expect(signState.totalRounds == 3)
    }

    /// MOB-1513 (R9): a batch within the cap stays a SINGLE round — the sign screen carries the
    /// whole batch and the indicator's `totalRounds` is 1, byte-identical ceremony to before R9.
    @MainActor @Test func keystoneSignRequestedWithinCapStaysSingleRound() async {
        let all = Self.roundFixturePczts(count: 2)
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.keystoneSignRequested(all))))))

        #expect(store.state.keystoneBatchRounds?.allPczts.count == 2)
        guard case let .keystoneSign(signState)? = store.state.path.last else {
            Issue.record("Expected keystoneSign armed with the whole batch")
            return
        }
        #expect(signState.pczts.map(\.id) == ["t0", "t1"])
        #expect(signState.totalRounds == 1)
    }

    /// MOB-1513 (R9): a mid-sequence round completion applies + ACCUMULATES, then re-arms
    /// `keystoneSign` with the next slice (fresh request id) — and stores NOTHING: the stores run
    /// exactly once, after the last round.
    @MainActor @Test func foundKeystoneBatchSignaturesMidSequenceArmsNextRoundWithoutStoring() async {
        let storePrepsCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let storeScheduleCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let all = Self.roundFixturePczts(count: 33)
        let round0State = MigrationKeystoneSign.State(pczts: Array(all[0..<32]), roundIndex: 0, totalRounds: 2)
        let round0RequestId = round0State.requestId
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.keystoneBatchRounds = MigrationCoordFlow.KeystoneBatchRounds(allPczts: all)
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(round0State))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = Self.derivedBytesApply
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, stored in
                storePrepsCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeScheduleCalls.withValue { $0.append(stored) }
            }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        )
        await store.receive(\.keystoneBatchSignaturesApplied)

        #expect(storePrepsCalls.value.isEmpty)
        #expect(storeScheduleCalls.value.isEmpty)
        #expect(store.state.keystoneBatchApplyInFlight == false)
        #expect(store.state.pendingKeystoneSigning == .planCommit)
        #expect(store.state.keystoneBatchRounds?.roundIndex == 1)
        #expect(store.state.keystoneBatchRounds?.accumulatedSigned.map(\.id) == (0..<32).map { "t\($0)" })
        #expect(store.state.path.count == 2)
        guard case let .keystoneSign(nextSignState)? = store.state.path.last else {
            Issue.record("Expected the NEXT round's keystoneSign armed after the mid-sequence apply")
            return
        }
        #expect(nextSignState.pczts.map(\.id) == ["t32"])
        #expect(nextSignState.roundIndex == 1)
        #expect(nextSignState.totalRounds == 2)
        #expect(nextSignState.requestId != round0RequestId)
    }

    /// MOB-1513 (R9): the LAST round's completion stores the FULL accumulated batch in original
    /// order — and, being a later round, skips the firmware gate entirely (round 0 already gated
    /// the same physical device; a `nil` version here must not block the ceremony's tail).
    @MainActor @Test func foundKeystoneBatchSignaturesLastRoundSkipsFirmwareGateAndStoresFullAccumulatedBatch() async {
        let storeScheduleCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let all = Self.roundFixturePczts(count: 33)
        let accumulated = all[0..<32].map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt + Data([0x99])) }
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.keystoneBatchRounds = MigrationCoordFlow.KeystoneBatchRounds(
            allPczts: all,
            roundIndex: 1,
            accumulatedSigned: accumulated
        )
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [all[32]], roundIndex: 1, totalRounds: 2)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = Self.derivedBytesApply
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeScheduleCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "prep-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: nil))
                )
            )
        )
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)

        #expect(store.state.isKeystoneFirmwareGatePresented == false)
        #expect(store.state.keystoneBatchRounds == nil)
        #expect(storeScheduleCalls.value.count == 1)
        #expect(storeScheduleCalls.value.first?.map(\.id) == (0..<33).map { "t\($0)" })
        #expect(storeScheduleCalls.value.first?.map(\.pczt) == all.map { $0.pczt + Data([0x99]) })
    }

    /// MOB-1513 (R9): an abandon mid-sequence discards the accumulated rounds — nothing was
    /// stored, and the next ceremony must start from a clean slate (the engine re-serves the
    /// still-unsigned batch).
    @MainActor @Test func keystoneScanAbandonedMidSequenceDiscardsAccumulatedRounds() async {
        let all = Self.roundFixturePczts(count: 33)
        let accumulated = all[0..<32].map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt + Data([0x99])) }
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.keystoneBatchRounds = MigrationCoordFlow.KeystoneBatchRounds(
            allPczts: all,
            roundIndex: 1,
            accumulatedSigned: accumulated
        )
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [all[32]], roundIndex: 1, totalRounds: 2)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.keystoneScanAbandoned)

        #expect(store.state.keystoneBatchRounds == nil)
        #expect(store.state.pendingKeystoneSigning == nil)
    }

    /// MOB-1513 (R9): a reject mid-sequence discards the accumulated rounds too — the
    /// no-partial-storage invariant holds across every ceremony-ending route.
    @MainActor @Test func keystoneSignRejectedMidSequenceDiscardsAccumulatedRounds() async {
        let all = Self.roundFixturePczts(count: 33)
        let accumulated = all[0..<32].map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt + Data([0x99])) }
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.keystoneBatchRounds = MigrationCoordFlow.KeystoneBatchRounds(
            allPczts: all,
            roundIndex: 1,
            accumulatedSigned: accumulated
        )
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [all[32]], roundIndex: 1, totalRounds: 2)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.keystoneSignRejected)

        #expect(store.state.keystoneBatchRounds == nil)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
    }

    /// MOB-1513 (R9, review fix): a late apply completion landing AFTER the ceremony was torn
    /// down (reject/abandon mid-apply — the ceremony's tombstone, `pendingKeystoneSigning`, is
    /// nil) must store NOTHING and leave the path alone. Without the tombstone guard, the nil
    /// rounds state would masquerade as a single-round ceremony and store the LATE ROUND'S SLICE
    /// as if it were the whole batch — a partial store, the exact invariant breach R9 exists to
    /// prevent.
    @MainActor @Test func keystoneBatchSignaturesAppliedAfterCeremonyTeardownStoresNothing() async {
        let storePrepsCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let storeScheduleCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let slice = Self.roundFixturePczts(count: 32)
        let signedSlice = slice.map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt + Data([0x99])) }
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = nil
        state.keystoneBatchRounds = nil
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, stored in
                storePrepsCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeScheduleCalls.withValue { $0.append(stored) }
            }
        }
        store.exhaustivity = .off

        await store.send(
            .keystoneBatchSignaturesApplied(
                context: .planCommit,
                accountUUID: AccountUUID(id: [UInt8](repeating: 9, count: 16)),
                unsignedPczts: slice,
                signed: signedSlice
            )
        )

        #expect(storePrepsCalls.value.isEmpty)
        #expect(storeScheduleCalls.value.isEmpty)
        #expect(store.state.path.count == 1)
        #expect(store.state.keystoneBatchRounds == nil)
    }

    /// MOB-1513 (R9, review fix — coverage): sentinel-prefixed preparation ids survive the
    /// multi-round accumulate and partition correctly at the LAST round's store — the prep (round
    /// 0's slice carried it) reaches the note-split store stripped, the schedule entries reach the
    /// deferred schedule store via the first-delivery kick, all in original order.
    @MainActor @Test func foundKeystoneBatchSignaturesLastRoundPartitionsAccumulatedPrepsAndSchedule() async {
        let storePrepsCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let storeScheduleCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        var all = Self.roundFixturePczts(count: 33)
        all[0] = MigrationUnsignedTransferPczt(id: "note-split#7", pczt: Data([0x01]))
        let accumulated = all[0..<32].map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt + Data([0x99])) }
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.keystoneBatchRounds = MigrationCoordFlow.KeystoneBatchRounds(
            allPczts: all,
            roundIndex: 1,
            accumulatedSigned: accumulated
        )
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [all[32]], roundIndex: 1, totalRounds: 2)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = Self.derivedBytesApply
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, stored in
                storePrepsCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                storeScheduleCalls.withValue { $0.append(stored) }
            }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "prep-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: nil))
                )
            )
        )
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(store.state.keystoneBatchRounds == nil)
        #expect(storePrepsCalls.value == [[MigrationSignedTransferPczt(id: "7", pczt: Data([0x01, 0x99]))]])
        #expect(storeScheduleCalls.value.count == 1)
        #expect(storeScheduleCalls.value.first?.map(\.id) == (1..<33).map { "t\($0)" })
    }

    /// MOB-1513 (R9, review fix — coverage): the recovery-refresh lane (schedule rides the
    /// CONTEXT, not the path) chunks and advances rounds exactly like plan commit — the two batch
    /// contexts share `beginKeystoneCeremony` and the round-advance branch.
    @MainActor @Test func recoveryRefreshMultiRoundAdvancesLikeThePlanCommitLane() async {
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "12", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24,
            proposalHandle: 7
        )
        let all = Self.roundFixturePczts(count: 33)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .recoveryRefresh(schedule: schedule)
        state.keystoneBatchRounds = MigrationCoordFlow.KeystoneBatchRounds(allPczts: all)
        state.path.append(.recovery(MigrationRecovery.State()))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: Array(all[0..<32]), roundIndex: 0, totalRounds: 2)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = Self.derivedBytesApply
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        )
        await store.receive(\.keystoneBatchSignaturesApplied)

        #expect(store.state.pendingKeystoneSigning == .recoveryRefresh(schedule: schedule))
        #expect(store.state.keystoneBatchRounds?.roundIndex == 1)
        #expect(store.state.keystoneBatchRounds?.accumulatedSigned.count == 32)
        guard case let .keystoneSign(nextSignState)? = store.state.path.last else {
            Issue.record("Expected the recovery lane's next round armed")
            return
        }
        #expect(nextSignState.pczts.map(\.id) == ["t32"])
        #expect(nextSignState.roundIndex == 1)
    }

    /// MOB-1513 (R9): shared fixture — `count` unsigned PCZTs with ordinal ids `t0...` and
    /// distinct single-byte payloads.
    private static func roundFixturePczts(count: Int) -> [MigrationUnsignedTransferPczt] {
        (0..<count).map { MigrationUnsignedTransferPczt(id: "t\($0)", pczt: Data([UInt8($0)])) }
    }

    /// MOB-1513 (R9): an apply stub whose signed bytes derive from each input PCZT (`pczt +
    /// 0x99`), so multi-round tests stay positionally honest regardless of which round's slice
    /// crosses the boundary (unlike `stubApply`, whose fixed fixture array zips from index 0
    /// every call).
    private static let derivedBytesApply: @Sendable ([MigrationUnsignedTransferPczt], Data) async throws -> [MigrationSignedTransferPczt] = {
        pczts, _ in
        pczts.map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt + Data([0x99])) }
    }

    /// MOB-1513 (B4): the first-prep broadcast re-homes from the deleted "Splitting Funds" screen to
    /// the coordinator's first-delivery kick — the ceremony resumes STRAIGHT to B9 Migration
    /// Scheduled (no `.noteSplit` detour, the screen no longer exists), and the kick broadcasts the
    /// first prep via the EXISTING next-due lane, exactly the closure the BG-window path uses.
    @MainActor @Test func foundKeystoneBatchSignaturesWithNoteSplitSentinelResumesToScheduledAndKickBroadcastsFirstPrep() async {
        let executeCalls = LockIsolated<Int>(0)
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "prep-tx")
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(executeCalls.value == 1)
        #expect(store.state.path.count == 2)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed directly — no .noteSplit detour exists any more")
            return
        }
        guard case .transferPlan = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .transferPlan retained at the bottom (never re-signs again)")
            return
        }
        #expect(store.state.pendingKeystoneSigning == nil)
    }

    /// THE C-1/C-1b ORDER PIN under the B4 kick (final review R6, fix-wave 2 — see
    /// `SDKSynchronizerInterface`'s doc for the final engine's corrected account of C-1): the preps
    /// store at ceremony end, the first prep BROADCASTS (via the kick's next-due call), and only
    /// then does the deferred schedule store + `recordCommittedSchedule` run — strictly in that
    /// order. Storing the schedule before the prep's broadcast lands would let the broadcast-success
    /// record clobber the run's phase and strand the schedule once the prep mines (C-1b).
    @MainActor @Test func foundKeystoneBatchSignaturesWithNoteSplitSentinelStoresPrepsThenBroadcastsThenStoresScheduleThenRecords() async {
        let callOrder = LockIsolated<[String]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))
        ]
        let signed: [Data] = [Data([0x01, 0x99]), Data([0xAA, 0x99])]
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24,
                    proposalHandle: 1
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in callOrder.withValue { $0.append("storeSignedNoteSplits") } }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in
                callOrder.withValue { $0.append("storeSignedMigrationTransactions") }
            }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                callOrder.withValue { $0.append("executeNextPendingMigrationTransfer") }
                return MigrationTransferResult.success(txId: "prep-tx")
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in
                callOrder.withValue { $0.append("recordCommittedSchedule") }
            }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(
            callOrder.value ==
                ["storeSignedNoteSplits", "executeNextPendingMigrationTransfer", "storeSignedMigrationTransactions", "recordCommittedSchedule"]
        )
        #expect(store.state.pendingKeystoneScheduleStore == nil)
    }

    /// A kick BROADCAST failure is silent (B4 controller resolution 3): the user stays on B9
    /// Migration Scheduled with no failure UI, the deferred schedule store never even runs (C-1b:
    /// it needs a landed prep broadcast first), and the entries stay stashed in
    /// `pendingKeystoneScheduleStore`. B4 fix wave: the kick makes its bounded attempts (3, spaced
    /// via the injected clock) and then ARMS the state-event re-arm (`.firstDeliveryKickFailed`) so
    /// the store still happens later — see the dedicated re-arm test below.
    @MainActor @Test func firstDeliveryKickBroadcastFailureLeavesScheduleStashedAndIsSilent() async {
        let scheduleStoreCalls = LockIsolated<Int>(0)
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let routeCalls = LockIsolated<Int>(0)
        let refreshGateCalls = LockIsolated<Int>(0)
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
            $0.continuousClock = ImmediateClock()
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in scheduleStoreCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.networkError(retryable: true) }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, _ in
                routeCalls.withValue { $0 += 1 }
                return MigrationBroadcastFailureRoute.plainRetry
            }
            $0.migrationManager.refreshMigrationSyncGate = { refreshGateCalls.withValue { $0 += 1 } }
            // The armed re-arm subscribes here — a completed-empty stream keeps this test focused
            // on the kick's own attempts (the re-arm's resolution has its own test below).
            $0.migrationManager.stateEvents = { _ in Empty().eraseToAnyPublisher() }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        // B4 fix wave: exhausting the bounded attempts arms the state-event re-arm.
        await store.receive(\.firstDeliveryKickFailed)
        await store.finish()

        #expect(scheduleStoreCalls.value == 0)
        #expect(recordCommittedScheduleCalls.value == 0)
        // Classified + routed ONCE PER ATTEMPT for R16 rotation/Tor-hold bookkeeping (same silent
        // treatment as the BG-window lane), and the stopped sync is nudged back each time.
        #expect(routeCalls.value == MigrationCoordFlow.firstDeliveryKickMaxAttempts)
        #expect(refreshGateCalls.value == MigrationCoordFlow.firstDeliveryKickMaxAttempts)
        #expect(store.state.pendingKeystoneScheduleStore != nil)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected the user to stay on .scheduled — a kick failure has NO UI")
            return
        }
    }

    /// A kick DEFERRED-STORE failure (the prep broadcast landed, then
    /// `storeSignedMigrationTransactions` threw) also stays silent and keeps the entries stashed —
    /// nothing records, `.deferredKeystoneScheduleStored` never fires. B4 fix wave: the later
    /// bounded attempts hit the `nil`-with-pending-store arm (the prep already landed, so next-due
    /// is exhausted) and retry the STORE only — never a second broadcast — before arming the
    /// re-arm.
    @MainActor @Test func firstDeliveryKickDeferredStoreFailureKeepsScheduleStashed() async {
        struct StoreFailure: Error { }
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        let executeCalls = LockIsolated<Int>(0)
        let scheduleStoreCalls = LockIsolated<Int>(0)
        let recordTransferBroadcastCalls = LockIsolated<Int>(0)
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
            $0.continuousClock = ImmediateClock()
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in
                scheduleStoreCalls.withValue { $0 += 1 }
                throw StoreFailure()
            }
            // Realistic engine shape: the first attempt lands the prep; every later probe answers
            // `nil` (the landed prep is recorded, nothing else is due yet).
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                let call = executeCalls.withValue {
                    $0 += 1
                    return $0
                }
                return call == 1 ? MigrationTransferResult.success(txId: "prep-tx") : nil
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in recordTransferBroadcastCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationManager.stateEvents = { _ in Empty().eraseToAnyPublisher() }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.firstDeliveryKickFailed)
        await store.finish()

        #expect(recordCommittedScheduleCalls.value == 0)
        // One store attempt per kick attempt — but only ONE broadcast ever landed/recorded; the
        // later attempts retried the store via the `nil` arm, never re-broadcasting.
        #expect(scheduleStoreCalls.value == MigrationCoordFlow.firstDeliveryKickMaxAttempts)
        #expect(recordTransferBroadcastCalls.value == 1)
        #expect(store.state.pendingKeystoneScheduleStore != nil)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected the user to stay on .scheduled — a kick store failure has NO UI")
            return
        }
    }

    /// B4 fix wave: a TRANSIENT broadcast failure (e.g. a Tor bootstrap flake right at confirm
    /// time — the same network leg behind the original freeze) resolves within the kick's own
    /// bounded attempts: attempt 1 fails, attempt 2 lands the prep and runs the deferred store.
    @MainActor @Test func firstDeliveryKickTransientBroadcastFailureRetriesWithinKickAndResolves() async {
        let executeCalls = LockIsolated<Int>(0)
        let scheduleStoreCalls = LockIsolated<Int>(0)
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
            $0.continuousClock = ImmediateClock()
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in scheduleStoreCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                let call = executeCalls.withValue {
                    $0 += 1
                    return $0
                }
                return call == 1 ? MigrationTransferResult.networkError(retryable: true) : MigrationTransferResult.success(txId: "prep-tx")
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(executeCalls.value == 2)
        #expect(scheduleStoreCalls.value == 1)
        #expect(store.state.pendingKeystoneScheduleStore == nil)
    }

    /// B4 fix wave, THE STRANDING REGRESSION PIN: a kick whose bounded attempts ALL fail must not
    /// orphan the deferred store — `.firstDeliveryKickFailed` arms a state-event re-arm whose
    /// payload rides the effect (not state), and a LATER `stateEvents` emission (here: the prep
    /// mined after a BG-window lane broadcast it, flipping the run to `.inProgress`) triggers one
    /// silent resolve: the next-due probe answers `nil` (the prep already landed), so the deferred
    /// store finally runs and `.deferredKeystoneScheduleStored` releases the stash.
    @MainActor @Test func firstDeliveryKickExhaustedRearmResolvesOnALaterStateEvent() async {
        let executeCalls = LockIsolated<Int>(0)
        let scheduleStoreCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let recordCommittedScheduleCalls = LockIsolated<[MigrationSchedule]>([])
        let broadcastAvailable = LockIsolated<Bool>(false)
        let stateSubject = PassthroughSubject<MigrationState, Never>()
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))
        ]
        let signed: [Data] = [Data([0x01, 0x99]), Data([0xAA, 0x99])]
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24,
                    proposalHandle: 1
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
            $0.continuousClock = ImmediateClock()
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in
                scheduleStoreCalls.withValue { $0.append(stored) }
            }
            // Kick phase: the network is down, every attempt fails. Re-arm phase (the test flips
            // `broadcastAvailable` after the kick exhausts): a BG-window lane has landed the prep
            // meanwhile, so the probe answers `nil`.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeCalls.withValue { $0 += 1 }
                if broadcastAvailable.value {
                    return nil
                }
                return MigrationTransferResult.networkError(retryable: true)
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, schedule in
                recordCommittedScheduleCalls.withValue { $0.append(schedule) }
            }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.routeBroadcastFailure = { _, _ in MigrationBroadcastFailureRoute.plainRetry }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationManager.stateEvents = { _ in stateSubject.eraseToAnyPublisher() }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.firstDeliveryKickFailed)
        #expect(executeCalls.value == MigrationCoordFlow.firstDeliveryKickMaxAttempts)
        #expect(scheduleStoreCalls.value.isEmpty)
        #expect(store.state.pendingKeystoneScheduleStore != nil)

        // A BG-window broadcast lands the prep while this coordinator wasn't looking; it later
        // mines and a reconcile emits the state change.
        broadcastAvailable.setValue(true)
        let progress = MigrationProgress(completedTransfers: 0, totalTransfers: 1, remainingOrchard: Zatoshi(500_000_000), nextTransferReadyAtHeight: nil)
        stateSubject.send(MigrationState.inProgress(progress))

        await store.receive(\.deferredKeystoneScheduleResolveDue)
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(scheduleStoreCalls.value == [[MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA, 0x99]))]])
        #expect(recordCommittedScheduleCalls.value == [schedule])
        #expect(store.state.pendingKeystoneScheduleStore == nil)
    }

    /// B4 fix wave, CROSS-ACCOUNT COLLISION PIN (MOB-1509 parallel migrations): `MigrationCoordFlow`
    /// is ONE permanent `Scope` child of Root, so two accounts migrating in parallel share this
    /// single coordinator. Account A arms its state-event re-arm (its kick exhausted with the deferred
    /// store still pending); account B then arms its OWN re-arm (`cancelInFlight: true`) and lands its
    /// deferred store (`.cancel(id:)`). With a payload-free `CancelID` BOTH of B's teardowns hit the
    /// shared id and kill A's still-armed re-arm, stranding A's run. Keying the id by account isolates
    /// them: A's re-arm must survive B entirely and still resolve on A's OWN later `stateEvents`
    /// emission. RED under the payload-free id — A's re-arm is cancelled, so A's emission produces no
    /// `.deferredKeystoneScheduleResolveDue` and the receive below times out.
    @MainActor @Test func deferredScheduleRearmIsPerAccountAndSurvivesAParallelAccountsRearmAndStore() async {
        let accountA = AccountUUID(id: [UInt8](repeating: 1, count: 16))
        let accountB = AccountUUID(id: [UInt8](repeating: 2, count: 16))
        let stateSubjectA = PassthroughSubject<MigrationState, Never>()
        let stateSubjectB = PassthroughSubject<MigrationState, Never>()
        let storedAccounts = LockIsolated<[AccountUUID]>([])
        let pendingA = MigrationCoordFlow.PendingScheduleStore(
            accountUUID: accountA,
            scheduleEntries: [MigrationSignedTransferPczt(id: "a0", pczt: Data([0xA0]))],
            schedule: nil
        )
        let pendingB = MigrationCoordFlow.PendingScheduleStore(
            accountUUID: accountB,
            scheduleEntries: [MigrationSignedTransferPczt(id: "b0", pczt: Data([0xB0]))],
            schedule: nil
        )
        let store = TestStore(initialState: MigrationCoordFlow.State()) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.sdkSynchronizer = .noOp
            // A's re-arm resolution: next-due is exhausted (the prep already landed on another lane),
            // so the probe answers `nil` and the deferred store runs.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { account, _ in
                storedAccounts.withValue { $0.append(account) }
            }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
            $0.migrationManager.stateEvents = { account in
                account == accountA
                    ? stateSubjectA.eraseToAnyPublisher()
                    : stateSubjectB.eraseToAnyPublisher()
            }
        }
        store.exhaustivity = .off

        // Account A arms its re-arm.
        await store.send(.firstDeliveryKickFailed(pendingScheduleStore: pendingA, accountUUID: accountA))
        // Account B then arms its own re-arm (`cancelInFlight: true`) ...
        await store.send(.firstDeliveryKickFailed(pendingScheduleStore: pendingB, accountUUID: accountB))
        // ... and lands its deferred store (`.cancel(id:)`). Under a payload-free id, either of these
        // B steps would already have torn down A's re-arm.
        await store.send(.deferredKeystoneScheduleStored(accountB))

        // A's own later state event must STILL drive A's re-arm to resolve and store A's schedule.
        stateSubjectA.send(
            MigrationState.inProgress(
                MigrationProgress(completedTransfers: 0, totalTransfers: 1, remainingOrchard: Zatoshi(500_000_000), nextTransferReadyAtHeight: nil)
            )
        )

        await store.receive(\.deferredKeystoneScheduleResolveDue)
        await store.receive(\.deferredKeystoneScheduleStored)

        // ONLY account A's schedule stored on A's re-arm — B's store was the direct send above.
        #expect(storedAccounts.value == [accountA])

        // Both re-arms are now cancelled by their own stores; completing the subjects is a no-op that
        // documents there is nothing left subscribed.
        stateSubjectA.send(completion: .finished)
        stateSubjectB.send(completion: .finished)
    }

    /// B4 fix wave (coverage gap): the `.manual` variant's kick arm — a Keystone MANUAL commit with
    /// preps pushes Sending (that screen keeps owning the manual lane's own delivery) AND fires the
    /// kick, since only the kick holds the deferred schedule store.
    @MainActor @Test func keystoneSigningSubmittedForManualVariantPushesSendingAndKickRunsDeferredStore() async {
        let executeCalls = LockIsolated<Int>(0)
        let scheduleStoreCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)],
            estimatedDurationHours: 24,
                    proposalHandle: 1
        )
        var planState = MigrationTransferPlan.State(variant: .manual)
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(planState))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA]))])))
        let pending = MigrationCoordFlow.PendingScheduleStore(
            accountUUID: Self.defaultAccount.id,
            scheduleEntries: [MigrationSignedTransferPczt(id: "t0", pczt: Data([0xAA, 0x99]))],
            schedule: schedule
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.continuousClock = ImmediateClock()
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in scheduleStoreCalls.withValue { $0 += 1 } }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in
                executeCalls.withValue { $0 += 1 }
                return MigrationTransferResult.success(txId: "prep-tx")
            }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(.keystoneSigningSubmitted(context: .planCommit, pendingScheduleStore: pending))
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(executeCalls.value == 1)
        #expect(scheduleStoreCalls.value == 1)
        #expect(store.state.pendingKeystoneScheduleStore == nil)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed for the manual variant")
            return
        }
        #expect(sendingState.isManualStepLane == true)
        guard case .transferPlan = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .transferPlan retained at the bottom")
            return
        }
    }

    /// B4 fix wave (coverage gap): pins `deferredScheduledState`'s numbers for the Keystone
    /// deferred-store window — schedule-derived fields come from the IN-HAND schedule (duration,
    /// total = prior sent + schedule count, amount = prior transferred + schedule sum) and
    /// `dustAmount` from the LIVE stored-run residual, never from the summary's (deliberately
    /// poisoned here) schedule-derived fields, which would read the previous payload or the
    /// degraded progress-only fallback in this window.
    @MainActor @Test func foundKeystoneBatchSignaturesWithNoteSplitSentinelHydratesScheduledFromDeferredNumbers() async throws {
        let unsigned: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#p0", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "t0", pczt: Data([0xAA])),
            MigrationUnsignedTransferPczt(id: "t1", pczt: Data([0xBB]))
        ]
        let signed: [Data] = [
            Data([0x01, 0x99]),
            Data([0xAA, 0x99]),
            Data([0xBB, 0x99])
        ]
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200),
                MigrationTransferProposal(id: "t1", amount: Zatoshi(300_000_000), anchorHeight: 100, nextExecutableAfterHeight: 150, expiryHeight: 250)
            ],
            estimatedDurationHours: 30,
                    proposalHandle: 1
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
            $0.continuousClock = ImmediateClock()
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "prep-tx") }
            // The stored-run residual the deferred hydration must prefer.
            $0.sdkSynchronizer.residualAfterMigration = { _ in Zatoshi(31_000) }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.migrationSummary = { _ in
                MigrationSummary(
                    // Prior-run bookkeeping (a `.recreated` re-commit): USED.
                    transferred: Zatoshi(600_000_000),
                    // Schedule-derived fields of the PRE-record payload: poisoned — must NOT leak in.
                    dust: Zatoshi(555),
                    transfersSent: 2,
                    transfersTotal: 99,
                    estimatedDurationHours: 77
                )
            }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.deferredKeystoneScheduleStored)

        guard case let .scheduled(scheduledState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed")
            return
        }
        #expect(scheduledState.totalAmount == Zatoshi(1_400_000_000))
        #expect(scheduledState.sentCount == 2)
        #expect(scheduledState.totalCount == 4)
        #expect(scheduledState.durationHours == 30)
        #expect(scheduledState.dustAmount == Zatoshi(31_000))
    }

    // MARK: - MOB-1496 (C-1 fix, final review R6): split-store failure abandons the session

    /// `storeSignedNoteSplits` throwing means NOTHING was stored — the schedule store must never even
    /// be attempted (it would land in a run the split never created), nothing gets recorded, and the
    /// session abandons exactly like a re-pair failure: nothing to resume, same `keystoneScanAbandoned`
    /// semantics (pop back to `.transferPlan`, context cleared).
    @MainActor @Test func foundKeystoneBatchSignaturesWithSplitStoreFailureAbandonsSessionWithoutStoringScheduleOrRecording() async {
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
            estimatedDurationHours: 24,
                    proposalHandle: 1
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, _ in throw SplitStoreFailure() }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in scheduleStoreCalls.withValue { $0 += 1 } }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
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

    /// MOB-1513: the pre-existing `noteSplitContinuedAfterImmediateReviewKeystoneSplitRoutingResumesToSendingAndClearsPendingResume`
    /// test covered `.immediateReview` carrying a note-split sentinel entry through the generic
    /// split-routing machinery (`storeKeystoneSignedBatch`/`resumeAfterKeystoneSigning`). That
    /// scenario is now impossible to reach: the immediate lane's Keystone PCZT is a single ordinary-
    /// send PCZT (`createPCZTFromProposal`), which never carries a note-split sentinel, AND
    /// `.scan(.foundKeystoneBatchSignatures)` intercepts `.immediateReview` via
    /// `submitImmediateKeystoneTransaction` BEFORE `storeKeystoneSignedBatch` (and its split-routing)
    /// ever runs — see `foundKeystoneBatchSignaturesForImmediateReviewContextAddsProofsSubmitsRecordsAndPushesSendingSuccess`
    /// below for the lane's real post-signing coverage now.

    /// No-split batches are unaffected: `splitKeystoneBatch` finds no sentinel, so every entry lands
    /// in `scheduleEntries` and the resume proceeds straight to `.scheduled`, exactly as before —
    /// twin of `foundKeystoneBatchSignaturesForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant`
    /// above, just asserting the split-free path explicitly stays split-free (no `.noteSplit` push).
    @MainActor @Test func foundKeystoneBatchSignaturesWithoutNoteSplitSentinelNeverPushesNoteSplitScreen() async {
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            // MOB-1513 (B4): the post-confirm first-delivery kick runs after landing on Scheduled —
            // nothing due is a valid outcome; the nudge/no-op stubs keep this test focused on the
            // no-detour push.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            // MOB-1458 (W-E): the post-commit chain now hydrates `.scheduled` via
            // `migrationManager.migrationSummary` before pushing — harmless zero, unasserted here.
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        // MOB-1458 (W-E): see `transferPlanPostConfirmChain`'s doc — the `.scheduled` push is now
        // hydrated (an async peek), landing via its own action rather than synchronously here.
        await store.receive(\.pushHydratedPathState)
        await store.finish()

        #expect(store.state.pendingKeystoneScheduleStore == nil)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed directly, no .noteSplit detour")
            return
        }
    }

    // MARK: - MOB-1513: applyKeystoneBatchSignatures failure abandons (no-partial-storage invariant)
    //
    // The pre-real-SDK app-side re-pair mismatch tests (short/long/empty scanned batch, checked by
    // the now-deleted `rePairedKeystoneBatch`) are superseded by this one: the real SDK does the
    // positional pairing itself now, so a malformed/mismatched device response surfaces as a THROW
    // from `applyKeystoneBatchSignatures` rather than an app-side `nil`. The pure `splitKeystoneBatch`
    // table tests are their own `@Suite` at the bottom of this file.

    @MainActor @Test func applyKeystoneBatchSignaturesFailureAbandonsSessionWithoutStoring() async {
        struct ApplyFailure: Error { }
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = { _, _ in throw ApplyFailure() }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneScanAbandoned)

        #expect(storeCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    // MARK: - MOB-1513 (final review, C1 fix): keystoneBatchDecodeFailed abandons the ceremony
    //
    // Before this fix the coordinator had NO handler at all for `.scan(.keystoneBatchDecodeFailed)` —
    // `decodeKeystoneSignBatchPart` throwing on a scanned frame (a stale, mismatched, or corrupt
    // response, including a request-id mismatch at completion) left the scan screen hung
    // unrecoverably instead of abandoning like every other failure point in this ceremony.

    @MainActor @Test func keystoneBatchDecodeFailedAbandonsSessionWithoutStoring() async {
        let applyCalls = LockIsolated<Int>(0)
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = { _, _ in
                applyCalls.withValue { $0 += 1 }
                return []
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.keystoneBatchDecodeFailed))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(applyCalls.value == 0)
        #expect(storeCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    @MainActor @Test func foundKeystoneBatchSignaturesForPlanCommitContextPushesSendingForManualVariant() async {
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            // MOB-1496 (W2): see `foundKeystoneBatchSignaturesForPlanCommitContextStoresPopsAndPushesScheduledForScheduledVariant`'s comment.
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top for the manual variant")
            return
        }
        #expect(sendingState.totalCount == 1)
    }

    // MARK: - MOB-1513: Keystone signing — foundKeystoneBatchSignatures resumes immediateReview via the immediate submit lane

    /// MOB-1513: the immediate lane's Keystone post-signing step diverges entirely from the
    /// schedule-based `.planCommit`/`.dust` contexts — no `storeSignedMigrationTransactions` call at
    /// all; `addProofsToPCZT` + `createAndSubmitTransactionFromPCZT` (guarded
    /// `MigrationCommitPipeline.commitImmediateKeystone`) fire instead, `recordImmediateMigration`
    /// records the success, and the Sending screen is pushed ALREADY in `.success` phase with the
    /// real txid (the broadcast already happened here — see `submitImmediateKeystoneTransaction`'s
    /// doc for why the Keystone lane can't defer to that screen's `onAppear` the way software does).
    @MainActor @Test func foundKeystoneBatchSignaturesForImmediateReviewContextAddsProofsSubmitsRecordsAndPushesSendingSuccess() async {
        let addProofsCalls = LockIsolated<[Data]>([])
        let submitCalls = LockIsolated<[(Data, Data)]>([])
        let recordedTxIds = LockIsolated<[(AccountUUID, Data)]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))]
        let signed: [Data] = [Data([0xDD, 0x01])]
        let provenPczt = Data([0xDD, 0xF0])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.addProofsToPCZT = { pczt in
                addProofsCalls.withValue { $0.append(pczt) }
                return provenPczt
            }
            $0.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { proofed, sig in
                submitCalls.withValue { $0.append((proofed, sig)) }
                return .success(txIds: ["ab12"])
            }
            $0.sdkSynchronizer.recordImmediateMigration = { accountUUID, txid in
                recordedTxIds.withValue { $0.append((accountUUID, txid)) }
            }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneImmediateSubmitted)

        #expect(addProofsCalls.value == [Data([0xDD])])
        #expect(submitCalls.value.count == 1)
        #expect(submitCalls.value.first?.0 == provenPczt)
        #expect(submitCalls.value.first?.1 == Data([0xDD, 0x01]))
        #expect(recordedTxIds.value.count == 1)
        #expect(recordedTxIds.value.first?.0 == Self.defaultAccount.id)
        // "ab12" hex-decoded forward is [0xAB,0x12]; the raw/internal order is that reversed.
        #expect(recordedTxIds.value.first?.1 == Data([0x12, 0xAB]))

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 2)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of the retained .reviewTransfer element")
            return
        }
        #expect(sendingState.phase == MigrationSending.State.Phase.success)
        #expect(sendingState.txId == "ab12")
        #expect(sendingState.totalCount == 1)
        guard case .reviewTransfer = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .reviewTransfer retained at the bottom")
            return
        }
    }

    /// Failure path: a non-`.success` submit outcome (or a thrown error from either SDK call) pops
    /// the ceremony and — MOB-1513 (R8, F2) — arms the retained Review element's commit-failure
    /// sheet instead of abandoning silently. (This batch entry into the `.immediateReview` submit is
    /// retained defensively; the live immediate lane rides the single-PCZT `.foundPCZT` round-trip,
    /// covered by `foundPCZTOnSubmitFailurePopsCeremonyAndArmsReviewCommitFailureSheet`.)
    @MainActor @Test func foundKeystoneBatchSignaturesForImmediateReviewContextOnSubmitFailureArmsReviewFailureSheetWithoutRecording() async {
        let recordCalls = LockIsolated<Int>(0)
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))]
        let signed: [Data] = [Data([0xDD, 0x01])]
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.addProofsToPCZT = { pczt in pczt }
            $0.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { _, _ in .failure(txIds: [], code: -1, description: "rejected") }
            $0.sdkSynchronizer.recordImmediateMigration = { _, _ in recordCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneImmediateSubmitFailed)

        #expect(recordCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .reviewTransfer (scan + sign removed)")
            return
        }
        #expect(reviewState.isFailurePresented == true)
        #expect(reviewState.failureReason == MigrationReviewTransfer.State.FailureReason.commit)
    }

    // MARK: - MOB-1513 (R8): immediate lane — SINGLE-PCZT production ceremony

    /// MOB-1513 (R8): a signed-PCZT fixture carrying the Keystone firmware proprietary-field stamp
    /// (`keystone:fw_version` + postcard length prefix `0x03` + 3 version bytes) the production
    /// stamp scan (`Data.keystoneFirmwareVersion()`) reads — the immediate single-PCZT ceremony
    /// gates on THIS stamp (the `SendConfirmation` floor, 3.0.0), never the batch envelope version.
    private func stampedSignedPczt(major: UInt8, minor: UInt8, build: UInt8, payload: [UInt8] = [0xD0, 0xD1]) -> Data {
        var bytes: [UInt8] = payload
        bytes.append(contentsOf: Array("keystone:fw_version".utf8))
        bytes.append(0x03)
        bytes.append(contentsOf: [major, minor, build])
        return Data(bytes)
    }

    /// MOB-1513 (R8): a single-PCZT-mode `keystoneSign` element's Get Signature pushes a scan
    /// session configured with the PRODUCTION checker (`keystonePCZTScanChecker` — the device echoes
    /// a full signed `zcash-pczt` UR, no batch decode session, no request-id) and resets the shared
    /// BC-UR fountain decoder so a retry ceremony never inherits a previous session's frames
    /// (`SendConfirmation.getSignatureTapped` precedent).
    @MainActor @Test func keystoneSignGetSignatureInSinglePcztModeConfiguresProductionCheckerAndResetsQRDecoder() async {
        let resetCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.keystoneHandler.resetQRDecoder = { resetCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.getSignature)))))

        #expect(resetCalls.value == 1)
        guard case let .scan(scanState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scan pushed on top")
            return
        }
        #expect(scanState.checkers == [.keystonePCZTScanChecker])
        #expect(scanState.keystoneBatchRequestId == Data())
        #expect(scanState.forceLibraryToHide)
        #expect(scanState.instructions == String(localizable: .migrationKeystoneScanInstructions))
    }

    /// MOB-1513 (R8): the immediate lane's post-scan step off the PRODUCTION ceremony — the scanned
    /// `.foundPCZT` payload IS the device-signed PCZT; the coordinator adds proofs to the ORIGINAL
    /// unsigned PCZT (still on the `keystoneSign` element beneath `scan`), combines+submits via the
    /// unchanged `commitImmediateKeystone`, records, and pushes Sending already in `.success` — the
    /// batch bridge (`applyKeystoneBatchSignatures`) is never touched.
    @MainActor @Test func foundPCZTForImmediateReviewContextAddsProofsSubmitsRecordsAndPushesSendingSuccess() async {
        let addProofsCalls = LockIsolated<[Data]>([])
        let submitCalls = LockIsolated<[(Data, Data)]>([])
        let recordedTxIds = LockIsolated<[(AccountUUID, Data)]>([])
        let applyCalls = LockIsolated<Int>(0)
        let unsignedBytes = Data([0xDD])
        let signedPczt = stampedSignedPczt(major: 3, minor: 0, build: 0)
        let provenPczt = Data([0xDD, 0xF0])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: unsignedBytes)],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = { _, _ in
                applyCalls.withValue { $0 += 1 }
                return []
            }
            $0.sdkSynchronizer.addProofsToPCZT = { pczt in
                addProofsCalls.withValue { $0.append(pczt) }
                return provenPczt
            }
            $0.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { proofed, sig in
                submitCalls.withValue { $0.append((proofed, sig)) }
                return .success(txIds: ["ab12"])
            }
            $0.sdkSynchronizer.recordImmediateMigration = { accountUUID, txid in
                recordedTxIds.withValue { $0.append((accountUUID, txid)) }
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signedPczt))))) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneImmediateSubmitted)

        #expect(applyCalls.value == 0)
        #expect(addProofsCalls.value == [unsignedBytes])
        #expect(submitCalls.value.count == 1)
        #expect(submitCalls.value.first?.0 == provenPczt)
        #expect(submitCalls.value.first?.1 == signedPczt)
        #expect(recordedTxIds.value.count == 1)
        #expect(recordedTxIds.value.first?.0 == Self.defaultAccount.id)
        // "ab12" hex-decoded forward is [0xAB,0x12]; the raw/internal order is that reversed.
        #expect(recordedTxIds.value.first?.1 == Data([0x12, 0xAB]))

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.keystoneImmediateSubmitInFlight == false)
        #expect(store.state.path.count == 2)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of the retained .reviewTransfer element")
            return
        }
        #expect(sendingState.phase == MigrationSending.State.Phase.success)
        #expect(sendingState.txId == "ab12")
        #expect(sendingState.totalCount == 1)
    }

    /// MOB-1513 (R10): the scan screen's "Signing…" hold — the coordinator arms
    /// `Scan.State.isKeystoneSigningInProgress` on the `scan` element the INSTANT the immediate
    /// lane's post-scan leg (proofs + broadcast) starts, since that element stays on top for the
    /// whole leg. Cloned setup from `foundPCZTForImmediateReviewContextAddsProofsSubmitsRecordsAndPushesSendingSuccess`
    /// above — this test only adds the new flag assertion to the send closure.
    @MainActor @Test func foundPCZTArmsScanSigningHoldOnTheScanElement() async {
        let signedPczt = stampedSignedPczt(major: 3, minor: 0, build: 0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.addProofsToPCZT = { pczt in pczt }
            $0.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { _, _ in .success(txIds: ["ab12"]) }
            $0.sdkSynchronizer.recordImmediateMigration = { _, _ in }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signedPczt))))) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneImmediateSubmitted)
    }

    /// MOB-1513 (R8, F2): a post-scan submit failure must be VISIBLE and retryable — the ceremony
    /// pops exactly like an abandon, but the retained Review Transfer element comes back with its
    /// existing commit-failure sheet armed (Retry re-runs the whole ceremony). This replaces the
    /// silent `keystoneScanAbandoned` funnel that produced the QA-reported infinite loop.
    @MainActor @Test func foundPCZTOnSubmitFailurePopsCeremonyAndArmsReviewCommitFailureSheet() async {
        let recordCalls = LockIsolated<Int>(0)
        let unsignedBytes = Data([0xDD])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: unsignedBytes)],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.addProofsToPCZT = { pczt in pczt }
            $0.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { _, _ in .failure(txIds: [], code: -1, description: "rejected") }
            $0.sdkSynchronizer.recordImmediateMigration = { _, _ in recordCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(stampedSignedPczt(major: 3, minor: 0, build: 0)))))) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneImmediateSubmitFailed)

        #expect(recordCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.keystoneImmediateSubmitInFlight == false)
        #expect(store.state.path.count == 1)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .reviewTransfer (scan + sign removed)")
            return
        }
        #expect(reviewState.isFailurePresented == true)
        #expect(reviewState.failureReason == MigrationReviewTransfer.State.FailureReason.commit)
        #expect(reviewState.isConfirming == false)
    }

    /// MOB-1513 (R8): the immediate ceremony's firmware gate reads the PRODUCTION proprietary-field
    /// stamp off the scanned signed PCZT against the `SendConfirmation` floor (3.0.0) — a stamp
    /// below it presents the migration firmware sheet with THAT floor's copy
    /// (`keystoneFirmwareGateMinimumVersion`) and abandons without ever touching proofs/submit.
    @MainActor @Test func foundPCZTBelowProductionFirmwareFloorPresentsGateWithProductionMinimumAndAbandons() async {
        let addProofsCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.addProofsToPCZT = { pczt in
                addProofsCalls.withValue { $0 += 1 }
                return pczt
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(stampedSignedPczt(major: 2, minor: 9, build: 9))))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(addProofsCalls.value == 0)
        #expect(store.state.isKeystoneFirmwareGatePresented == true)
        #expect(store.state.detectedKeystoneFirmwareVersion == "2.9.9")
        #expect(store.state.keystoneFirmwareGateMinimumVersion == zodl_internal.KeystoneFirmwareVersion.minimumSupported.versionString)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .reviewTransfer = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .reviewTransfer")
            return
        }
    }

    /// An UNSTAMPED signed PCZT (firmware predating the stamping feature — necessarily below the
    /// 3.0.0 floor, per the stamp's own 2.4.6 introduction) takes the same gate with the
    /// floor-only sheet copy (`detectedKeystoneFirmwareVersion` nil).
    @MainActor @Test func foundPCZTUnstampedPresentsGateAndAbandons() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(Data([0xD0, 0xD1, 0xD2]))))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(store.state.isKeystoneFirmwareGatePresented == true)
        #expect(store.state.detectedKeystoneFirmwareVersion == nil)
        #expect(store.state.keystoneFirmwareGateMinimumVersion == zodl_internal.KeystoneFirmwareVersion.minimumSupported.versionString)
        #expect(store.state.pendingKeystoneSigning == nil)
    }

    /// MOB-1513 (R8, review fix): a reject landing while the post-scan submit is still in flight
    /// (the user swipe-backs off `scan` mid-proving and taps Reject — the coordinator-level submit
    /// effect survives the pops) must clear the in-flight guard, and the LATE completion must not
    /// mutate the path shape: the tombstoned (`pendingKeystoneSigning == nil`) success pushes the
    /// Sending success over the current top WITHOUT popping (the broadcast genuinely landed), never
    /// deleting the screen the user backed onto.
    @MainActor @Test func keystoneSignRejectedWhileImmediateSubmitInFlightClearsGuardAndLateSuccessNeverPopsCurrentScreen() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.keystoneImmediateSubmitInFlight = true
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        // The user already swipe-backed off `scan` — only `keystoneSign` sits above Review.
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(store.state.keystoneImmediateSubmitInFlight == false)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)

        // The in-flight submit resolves AFTER the teardown — the tombstone branch must not pop.
        await store.send(.keystoneImmediateSubmitted(txId: "ab12"))

        #expect(store.state.path.count == 2)
        guard case .reviewTransfer = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected the Review element to survive the late success")
            return
        }
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the late success pushed on top without popping")
            return
        }
        #expect(sendingState.phase == MigrationSending.State.Phase.success)
    }

    /// Twin of the late-success test: a LATE submit FAILURE for a torn-down ceremony is dropped
    /// entirely (the user already rejected; the error is logged at the throw site) — no pops, no
    /// failure sheet, no path mutation at all.
    @MainActor @Test func lateImmediateSubmitFailureAfterRejectIsDroppedWithoutTouchingPath() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = nil
        state.keystoneImmediateSubmitInFlight = true
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.keystoneImmediateSubmitFailed) {
            $0.keystoneImmediateSubmitInFlight = false
        }

        #expect(store.state.path.count == 1)
        guard case let .reviewTransfer(reviewState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the Review element untouched")
            return
        }
        #expect(reviewState.isFailurePresented == false)
    }

    /// MOB-1513 (R8): duplicate `.foundPCZT` deliveries (a second camera frame decoded before the
    /// first delivery's `isAnythingFound` gate could flip) must be DROPPED while the submit is in
    /// flight — never a second addProofs/submit for the same ceremony.
    @MainActor @Test func foundPCZTDuplicateWhileSubmitInFlightIsDropped() async {
        let addProofsCalls = LockIsolated<Int>(0)
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let signedPczt = stampedSignedPczt(major: 3, minor: 0, build: 0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.addProofsToPCZT = { pczt in
                addProofsCalls.withValue { $0 += 1 }
                for await _ in releaseStream { break }
                return pczt
            }
            $0.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { _, _ in .success(txIds: ["ab12"]) }
            $0.sdkSynchronizer.recordImmediateMigration = { _, _ in }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signedPczt))))) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        // Duplicate delivery while the first submit is still in flight: a complete no-op.
        await store.send(.path(.element(id: 2, action: .scan(.foundPCZT(signedPczt)))))

        releaseContinuation.yield()
        releaseContinuation.finish()

        await store.receive(\.keystoneImmediateSubmitted)

        #expect(addProofsCalls.value == 1)
    }

    // MARK: - MOB-1513: minimum-firmware gate over the decode envelope's reported version

    /// Firmware strictly below the 3.0.2 floor presents the firmware-gate sheet, abandons the
    /// ceremony (no-partial-storage invariant: nothing was stored — the store/apply are never even
    /// reached), and records the detected version for the sheet's copy.
    @MainActor @Test func foundKeystoneBatchSignaturesBelowFirmwareFloorPresentsGateAndAbandonsWithoutStoring() async {
        let storeCalls = LockIsolated<Int>(0)
        let applyCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = { _, _ in
                applyCalls.withValue { $0 += 1 }
                return []
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in storeCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        let belowFloor = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 1)
        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: belowFloor))
                )
            )
        )
        await store.receive(\.keystoneScanAbandoned)

        #expect(applyCalls.value == 0)
        #expect(storeCalls.value == 0)
        #expect(store.state.isKeystoneFirmwareGatePresented == true)
        #expect(store.state.detectedKeystoneFirmwareVersion == "3.0.1")
        // Deferred pop of scan + sign back to the plan, context cleared — the user re-initiates
        // signing from the confirm button once their firmware is updated.
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (scan + sign removed)")
            return
        }
    }

    /// A decode envelope that reports NO firmware version at all is treated the same as below-floor
    /// — the batch protocol has no PCZT-embedded fallback (see `KeystoneBatchDecodeResult`'s doc) —
    /// and the gate's copy falls back to its "no version reported" variant (`nil` detected version).
    @MainActor @Test func foundKeystoneBatchSignaturesWithNilFirmwarePresentsGateAndAbandons() async {
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: nil))
                )
            )
        )
        await store.receive(\.keystoneScanAbandoned)

        #expect(store.state.isKeystoneFirmwareGatePresented == true)
        #expect(store.state.detectedKeystoneFirmwareVersion == nil)
    }

    /// Firmware exactly AT the floor (3.0.2) and comfortably above it (3.1.0) both clear the gate and
    /// proceed to apply — the floor is inclusive.
    @MainActor @Test func foundKeystoneBatchSignaturesAtOrAboveFirmwareFloorProceedsToApply() async {
        for firmware in [
            ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2),
            ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 1, build: 0)
        ] {
            let applyCalls = LockIsolated<Int>(0)
            var state = MigrationCoordFlow.State()
            state.pendingKeystoneSigning = .planCommit
            state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
            state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
            state.path.append(.scan(Scan.State.initial))
            let store = TestStore(initialState: state) {
                MigrationCoordFlow()
            } withDependencies: {
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.applyKeystoneBatchSignatures = { pczts, _ in
                    applyCalls.withValue { $0 += 1 }
                    return pczts.map { MigrationSignedTransferPczt(id: $0.id, pczt: $0.pczt) }
                }
                $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, _ in }
                $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
                $0.migrationBGScheduler.scheduleFirstWindow = { }
                $0.migrationManager.reconcile = { }
                $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
                $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
                $0.migrationManager.refreshMigrationSyncGate = { }
            }
            store.exhaustivity = .off

            // MOB-1513: `StackState`'s element ids are minted from a process-wide generator, not
            // reset per `State()` — this test's own `for` loop builds a fresh path every iteration,
            // so the literal `2` every OTHER single-iteration test in this file safely hardcodes
            // would be stale from iteration 2 onward. Read the real id back instead.
            guard let scanId = store.state.path.ids.last else {
                Issue.record("Expected a Scan element id")
                return
            }
            await store.send(
                .path(
                    .element(
                        id: scanId,
                        action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: firmware))
                    )
                )
            ) {
                if case .scan(var scanState) = $0.path[id: scanId] {
                    scanState.isKeystoneSigningInProgress = true
                    $0.path[id: scanId] = .scan(scanState)
                }
            }
            await store.receive(\.keystoneBatchSignaturesApplied)
            await store.receive(\.keystoneSigningSubmitted)
            await store.receive(\.pushHydratedPathState)
            await store.finish()

            #expect(applyCalls.value == 1, "firmware \(firmware) should have cleared the gate")
            #expect(store.state.isKeystoneFirmwareGatePresented == false)
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

    // MARK: - MOB-1513 (final review, I1 fix): keystoneSign(.delegate(.buildFailed)) abandons too
    //
    // `buildKeystoneSignBatchQRParts` throwing happens before the user ever taps "Get Signature", so
    // `.scan` was never pushed — unlike the rejected-path tests above (which land on
    // `keystoneSignRejected`), a build failure reuses `keystoneScanAbandoned` itself (handler at
    // `MigrationCoordFlowCoordinator.swift` ~line 640), taking its pop-1 path since only `keystoneSign`
    // is on top.

    @MainActor @Test func keystoneSignBuildFailedAbandonsSessionPoppingOnlyKeystoneSign() async {
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

        await store.send(.path(.element(id: 1, action: .keystoneSign(.delegate(.buildFailed)))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(storeCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .transferPlan = try? #require(store.state.path.last) else {
            Issue.record("Expected pop back to .transferPlan (keystoneSign removed, scan never pushed)")
            return
        }
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
            $0.migrationManager.setMigrationMode = { _, _ in }
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
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { _ in false }
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
    }

    /// MOB-1497 (R9-T3 fix, C1 — RED-FIRST ORDER PIN): the How-This-Works twin of
    /// `entryChoseImmediateWithTorFlagOnAndNonCustomServerPersistsBeforeForming` — same shared
    /// call-log technique, same assertion (persist strictly precedes form on the non-custom flag-on
    /// path), same underlying regression this pins against. See that test's doc for the full
    /// rationale.
    @MainActor @Test func howItWorksContinuedWithTorFlagOnAndNonCustomServerPersistsBeforeForming() async {
        enum CallLogEntry: Equatable {
            case persist(Bool)
            case form
        }
        let callLog = LockIsolated<[CallLogEntry]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
            $0.migrationManager.isSyncServerIdentityCustom = { false }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in callLog.withValue { $0.append(.persist(useTor)) } }
            $0.migrationManager.formNetworkSnapshot = { _ in callLog.withValue { $0.append(.form) } }
            $0.migrationManager.networkSnapshot = { _ in Self.someProviderNetworkSnapshot() }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { _ in false }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .howItWorks(.delegate(.continueTapped)))))
        await store.receive(\.pushNextPermissionStep)

        #expect(callLog.value == [CallLogEntry.persist(true), CallLogEntry.form])
    }

    /// MOB-1497 (R9-T3, finding 1): the How-This-Works twin of
    /// `entryChoseImmediateWithTorFlagOnAndCustomServerDetoursToTorSheet` — no such twin existed
    /// before this fix (the flag-on shortcut here was equally blind to identity-custom). Same
    /// detection/reuse (the synchronous, snapshot-free `migrationManager.isSyncServerIdentityCustom()`
    /// — R9-T3 C1 fix), same detour to the flag-off sheet below, same "no persist" outcome.
    @MainActor @Test func howItWorksContinuedWithTorFlagOnAndCustomServerDetoursToTorSheet() async {
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
            $0.migrationManager.isSyncServerIdentityCustom = { true }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in formNetworkSnapshotCalls.withValue { $0 += 1 } }
            $0.migrationManager.networkSnapshot = { _ in Self.someCustomNetworkSnapshot() }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .howItWorks(.delegate(.continueTapped)))))
        await store.receive(\.torSheetStateReady)

        #expect(store.state.isTorSheetPresented == true)
        #expect(store.state.pendingTorDestination == MigrationCoordFlow.PendingTorDestination.permissionChain)
        #expect(store.state.torSheetState.isCustomServer == true)
        #expect(store.state.torSheetState.isTorOn == false)
        #expect(store.state.torSheetState.usesFullBalanceCopy == false)
        #expect(setOptionsCalls.value.isEmpty)
        #expect(formNetworkSnapshotCalls.value == 1)
        // Nothing new pushed — `.howItWorks` is still the top element, same as the flag-off path.
        guard case .howItWorks = try? #require(store.state.path.last) else {
            Issue.record("Expected .howItWorks still on top (sheet gates the push)")
            return
        }
    }

    /// MOB-1497 (R9-T3, finding 1): chains the How-This-Works detour through to "Got it" — same
    /// shape as the immediate-lane continuation test above, proving `confirmTorSheet`'s
    /// `.permissionChain` destination reaches the same TransferPlan screen the (pre-fix) skip
    /// would have, persisting nothing along the way (finding 6).
    @MainActor @Test func howItWorksContinuedWithTorFlagOnAndCustomServerDetourThenGotItReachesTransferPlan() async {
        let setOptionsCalls = LockIsolated<[Bool]>([])
        var state = MigrationCoordFlow.State()
        state.mode = .privateScheduled
        state.path.append(.howItWorks(MigrationHowItWorks.State()))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.walletStorage = .noOp
            $0.walletStorage.exportTorSetupFlag = { true }
            $0.migrationManager.isSyncServerIdentityCustom = { true }
            $0.migrationManager.setNetworkPrivacyOptions = { useTor in setOptionsCalls.withValue { $0.append(useTor) } }
            $0.migrationManager.formNetworkSnapshot = { _ in }
            $0.migrationManager.networkSnapshot = { _ in Self.someCustomNetworkSnapshot() }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.migrationManager.isManualDelivery = { _ in false }
            $0.sdkSynchronizer = .noOp
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .howItWorks(.delegate(.continueTapped)))))
        await store.receive(\.torSheetStateReady)
        #expect(store.state.isTorSheetPresented == true)

        await store.send(.torSheet(.delegate(.gotIt)))
        await store.receive(\.pushNextPermissionStep)

        #expect(store.state.isTorSheetPresented == false)
        #expect(setOptionsCalls.value.isEmpty)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (detour -> confirm reaches the same destination the skip would have)")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.scheduled)
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
        // MOB-1497 (T2): provider — the toggle sheet variant (not the no-toggle unavailable one).
        #expect(store.state.torSheetState.isCustomServer == false)
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
            $0.migrationManager.setManualDelivery = { _, allowed in setManualDeliveryCalls.withValue { $0.append(allowed) } }
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
            $0.migrationManager.setManualDelivery = { _, _ in }
            $0.migrationBGScheduler.backgroundRefreshStatus = { .available }
            $0.userNotifications.authorizationStatus = { .notDetermined }
            $0.migrationManager.isManualDelivery = { _ in true }
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
            $0.migrationManager.isManualDelivery = { _ in false }
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
            $0.migrationManager.isManualDelivery = { _ in false }
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
            // MOB-1458 (W-E): the post-commit chain now hydrates `.scheduled` via
            // `migrationManager.migrationSummary` before pushing — harmless zero, unasserted here
            // (see the dedicated hydration tests below for the actual numbers).
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            // MOB-1513 (B4): the post-confirm first-delivery kick — see the dedicated kick tests;
            // a nil next-due keeps it a silent no-op here (`.noOp` base also covers the kick's
            // stop-sync `isSyncing` probe).
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))
        // MOB-1458 (W-E): the `.scheduled` push is now hydrated (an async peek), landing via its
        // own `pushHydratedPathState` action — see `transferPlanPostConfirmChain`'s doc.
        await store.receive(\.pushHydratedPathState)
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

    // MARK: - MOB-1458 (W-E): plan confirm -> Scheduled hydration

    /// A genuinely fresh `.scheduled` commit: `migrationManager.migrationSummary` reports nothing
    /// sent yet (a fresh schedule has no prior `sentRecords`), so the pushed state's numbers
    /// collapse to exactly the just-committed schedule's own totals — matching the B9 canvas's
    /// "Transfers 0 of 6".
    @MainActor @Test func transferPlanConfirmedInScheduledVariantHydratesScheduledStateFromCommittedScheduleAndSummary() async throws {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t0", amount: Zatoshi(500_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200),
                MigrationTransferProposal(id: "t1", amount: Zatoshi(300_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 30,
                    proposalHandle: 1
        )
        var planState = MigrationTransferPlan.State(variant: .scheduled)
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(planState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.migrationSummary = { _ in
                MigrationSummary(
                    transferred: Zatoshi.zero,
                    dust: Zatoshi(31_000),
                    transfersSent: 0,
                    transfersTotal: 2,
                    estimatedDurationHours: 30
                )
            }
            // MOB-1513 (B4): kick stubs — a nil next-due keeps the post-landing kick a silent
            // no-op (`.noOp` base also covers the kick's stop-sync `isSyncing` probe).
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))
        await store.receive(\.pushHydratedPathState)

        guard case let .scheduled(scheduledState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed")
            return
        }
        #expect(scheduledState.totalAmount == Zatoshi(800_000_000))
        #expect(scheduledState.sentCount == 0)
        #expect(scheduledState.totalCount == 2)
        #expect(scheduledState.durationHours == 30)
        #expect(scheduledState.dustAmount == Zatoshi(31_000))
    }

    /// `.recreated`: some transfers already broadcast under a PRIOR schedule for this same logical
    /// run (`summary.transferred`/`transfersSent` fold in the persisted `sentRecords`, which survive
    /// a restart per `MigrationScheduleStorage.recordCommittedSchedule`'s doc) — the pushed state
    /// must report the WHOLE run's cumulative numbers, not just the fresh schedule's own.
    @MainActor @Test func transferPlanConfirmedInRecreatedVariantHydratesScheduledStateWithCumulativeSentCount() async throws {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "t2", amount: Zatoshi(200_000_000), anchorHeight: 100, nextExecutableAfterHeight: 100, expiryHeight: 200)
            ],
            estimatedDurationHours: 12,
                    proposalHandle: 1
        )
        var planState = MigrationTransferPlan.State(variant: .recreated)
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.path.append(.transferPlan(planState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.migrationSummary = { _ in
                MigrationSummary(
                    transferred: Zatoshi(600_000_000),
                    dust: Zatoshi.zero,
                    transfersSent: 2,
                    transfersTotal: 3,
                    estimatedDurationHours: 12
                )
            }
            // MOB-1513 (B4): kick stubs — a nil next-due keeps the post-landing kick a silent
            // no-op (`.noOp` base also covers the kick's stop-sync `isSyncing` probe).
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .transferPlan(.delegate(.confirmed)))))
        await store.receive(\.pushHydratedPathState)

        guard case let .scheduled(scheduledState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed")
            return
        }
        // 600M already sent under the prior schedule + 200M in the fresh recreated schedule = 800M
        // cumulative, consistent with the cumulative "2 of 3" transfer count below.
        #expect(scheduledState.totalAmount == Zatoshi(800_000_000))
        #expect(scheduledState.sentCount == 2)
        #expect(scheduledState.totalCount == 3)
        #expect(scheduledState.durationHours == 12)
        #expect(scheduledState.dustAmount == Zatoshi.zero)
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
            estimatedDurationHours: 24,
                    proposalHandle: 1
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
            // R7 final review, Important-1: `statusProgressState` now reads this member too — see
            // `MigrationCoordFlowTests.onAppearWithStatusProgressRouteAppendsFlowRootStatusScreen`.
            $0.migrationManager.isMigrationTorHoldActive = { _ in false }
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

    /// MOB-1458 (code review — F3): "Send now" is a DELIBERATE authentication exemption (Michal),
    /// not a coverage gap — the transfer it broadcasts was already signed at the gated plan commit,
    /// and the background executor broadcasts that very same signed transfer unattended, with no
    /// authentication, the moment its window opens; a prompt on this foreground shortcut would only
    /// be friction a user bypasses by waiting for the next automatic window. `localAuthentication`
    /// is left COMPLETELY unimplemented (no `withDependencies` override at all) — unlike a test that
    /// asserts what a mock returns, this is proving nothing ever CALLS it: the case handler itself
    /// makes no other dependency call either, so a passing run here is a direct, loud pin — if a
    /// future change routes a prompt through this tap, the unimplemented `authenticate()` fails this
    /// test immediately instead of silently gating a path Michal decided must stay unauthenticated.
    @MainActor @Test func statusSendNowNeverAuthenticatesAndPushesSending() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.status(MigrationStatus.State(presentation: .resume, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .status(.delegate(.sendNow)))))
        await store.receive(\.pushHydratedPathState)

        guard case .sending = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed")
            return
        }
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
        // `localAuthentication` is intentionally left unimplemented: `requiresSigning == false`, so
        // `State.confirmRequiresAuthentication` (MOB-1458 F2: reduced to plain `requiresSigning` —
        // this screen's `isExpiredRecoveryReview` no longer factors in; see that property's own
        // doc) is false, and `confirmTapped` never calls `authenticate()` — a call here would fail
        // this test.

        await store.send(.confirmTapped)
        await store.receive(\.confirmAuthenticated)
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
            estimatedDurationHours: 24,
                    proposalHandle: 1
        )
        let restartCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): `.recreate` now gates behind device authentication before this
            // reason/vendor split even runs — see `recoveryRecreate...AuthenticationFailure...`
            // below for the refusal-side coverage; this test (and its siblings in this section)
            // only needs the gate to PASS so the pre-existing behavior it pins is reachable at all.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
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
        await store.receive(\.recoveryRecreateAuthenticated)
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
            // MOB-1458 (F2): the gate must pass for this reconcile-order pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
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
            // MOB-1458 (F2): the gate must pass for this restart-failure pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in throw RestartFailure() }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
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
            estimatedDurationHours: 24,
                    proposalHandle: 1
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
            $0.localAuthentication = .mockAuthenticationSucceeded
        }

        await store.send(.confirmTapped) {
            $0.isConfirming = true
        }
        await store.receive(\.confirmAuthenticated)
        await store.receive(\.scheduleSigned) {
            $0.isConfirming = false
        }
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

    /// MOB-1496 (W-B): software "Migrate anyway" now unlocks-then-proposes the immediate (send-max)
    /// migration — unlock-first is LOAD-BEARING (locked notes are excluded from send-max note
    /// selection), asserted here via call ORDER, not just "both were called".
    @MainActor @Test func completeMigrateAnywaySoftwareUnlocksBeforeProposingAndPushesSendingWithImmediateProposal() async {
        let callLog = LockIsolated<[String]>([])
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 5_000), amount: Zatoshi(95_000), fee: Zatoshi(5_000))
        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in
                callLog.withValue { $0.append("unlock") }
                return 1
            }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                callLog.withValue { $0.append("propose") }
                return proposal
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.pushHydratedPathState)

        #expect(callLog.value == ["unlock", "propose"])
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of .complete")
            return
        }
        #expect(sendingState.totalCount == 1)
        #expect(sendingState.immediateProposal == proposal)
        #expect(sendingState.isFailurePresented == false)
        #expect(store.state.pendingKeystoneSigning == nil)
    }

    /// Twin of the test above with an explicit software-vendor account, for symmetry with the
    /// Keystone fork below (same vendor split the entry-screen immediate lane already makes).
    @MainActor @Test func completeMigrateAnywayWithSoftwareAccountPushesSendingWithImmediateProposal() async {
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 5_000), amount: Zatoshi(95_000), fee: Zatoshi(5_000))
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: false, idByte: 24) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in 0 }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in proposal }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.pushHydratedPathState)

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .sending pushed on top of .complete")
            return
        }
        #expect(sendingState.totalCount == 1)
        #expect(sendingState.immediateProposal == proposal)
        #expect(store.state.pendingKeystoneSigning == nil)
    }

    /// Propose/unlock failure (e.g. the SDK's clean `InsufficientFunds` throw when the fee would
    /// consume the whole residual) falls back to the SAME generic Sending-screen failure sheet
    /// every other broadcast failure already uses — no new UI, and the coordinator never reaches
    /// the push-with-proposal branch. MOB-1458 (F4): also the one test in this section driven
    /// through the REAL `migrateAnywayTapped` (rather than the coordinator delegate directly), so
    /// `isMigratingAnyway` genuinely starts `true` — proving the "failure path" half of `.
    /// migrateAnywayFailed`'s clearing contract (the refusal half is covered by the dedicated F4
    /// tests below): a user who pops back to Complete from this failure sheet must find "Migrate
    /// anyway" tappable again, not permanently disabled.
    @MainActor @Test func completeMigrateAnywaySoftwareProposeFailurePushesSendingWithFailureSheet() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(dust: Zatoshi(1_000), isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in 0 }
            // The SDK's clean throw when the ZIP-317 fee would consume the whole residual.
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in throw ZcashError.rustProposeSendMaxTransfer("insufficient funds") }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.migrateAnywayTapped))))
        guard case let .complete(midState) = store.state.path.last else {
            Issue.record("Expected .complete on top after the tap")
            return
        }
        #expect(midState.isMigratingAnyway == true)

        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.migrateAnywayFailed)
        await store.receive(\.pushHydratedPathState)

        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the generic failure-sheet Sending fallback pushed")
            return
        }
        #expect(sendingState.isFailurePresented == true)
        #expect(sendingState.immediateProposal == nil)
        #expect(store.state.pendingKeystoneSigning == nil)
        guard case let .complete(afterState) = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .complete retained beneath the failure-sheet Sending push")
            return
        }
        #expect(afterState.isMigratingAnyway == false)
    }

    /// A throwing UNLOCK must never reach `proposeImmediateMigration` at all — proposing on top of
    /// a still-locked residual would silently sweep `Zatoshi.zero` instead of surfacing a failure.
    @MainActor @Test func completeMigrateAnywaySoftwareUnlockFailureNeverProposesAndPushesFailureSheet() async {
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in throw ZcashError.rustMigrationUnlockResidual("boom") }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                proposeCalls.withValue { $0 += 1 }
                return ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 0), amount: .zero, fee: .zero)
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayAuthenticated)
        // MOB-1458 (F4): clears `isMigratingAnyway` too (a no-op here — this test sends the
        // delegate directly rather than through `migrateAnywayTapped`, so the flag never went
        // `true` — but the action must still fire; see `completeMigrateAnywaySoftwareProposeFailure
        // PushesSendingWithFailureSheet` above for the from-`true` assertion).
        await store.receive(\.migrateAnywayFailed)
        await store.receive(\.pushHydratedPathState)

        #expect(proposeCalls.value == 0)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the generic failure-sheet Sending fallback pushed")
            return
        }
        #expect(sendingState.isFailurePresented == true)
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
        state.path.append(.sending(MigrationSending.State(phase: .success)))
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

    // MARK: - MOB-1496 (abandon reconciliation): keystoneScanAbandoned cancels a stray engine run
    //
    // The final engine creates a Keystone commit's WHOLE run (preps and schedule alike) the moment
    // its PCZTs are built (`proposeNoteSplitPCZTs`, called unconditionally by `proposeKeystoneBatch`),
    // and always resumes a stored non-terminal run on the next attempt, ignoring any newer preview.
    // `pendingKeystoneSigning` is only ever set once that build succeeds, so its presence when
    // `.keystoneScanAbandoned` fires means a stray run exists and must be cancelled — otherwise a
    // later re-entry would silently resume signing the same, by-then-stale PCZTs.

    @MainActor @Test func keystoneScanAbandonedWithPendingCeremonyCancelsStrayMigrationRunExactlyOnce() async {
        let restartCalls = LockIsolated<[AccountUUID]>([])
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .planCommit
        state.path.append(.transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [MigrationUnsignedTransferPczt(id: "t0", pczt: Data())])))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { accountUUID in
                restartCalls.withValue { $0.append(accountUUID) }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
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
        #expect(restartCalls.value.first == Self.defaultAccount.id)
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
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
        }
        store.exhaustivity = .off

        await store.send(.keystoneScanAbandoned)

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        #expect(restartCalls.value == 0)
    }

    // MARK: - MOB-1496 (W-B): Keystone "Migrate anyway" over Migration Complete

    /// Keystone "Migrate anyway" unlocks, proposes the immediate migration, and builds its PCZT via
    /// `createPCZTFromProposal` — the SAME ordinary-send PCZT builder
    /// `MigrationReviewTransferStore.requestKeystoneSignature` uses for the entry-screen immediate
    /// lane. Call ORDER matters (unlock-first is load-bearing) and `.immediateReview` — not a
    /// dust-specific context — is what gets armed, so the rest of the ceremony (scan -> proofs ->
    /// submit) is the SAME `.immediateReview` machinery the entry lane uses. MOB-1513 (R8): the
    /// dust producer redacts too and the pushed `keystoneSign` enters SINGLE-PCZT mode, exactly
    /// like the entry lane's delegate handler.
    @MainActor @Test func completeMigrateAnywayKeystoneUnlocksProposesRedactsAndPushesSinglePcztKeystoneSignContext() async {
        let callLog = LockIsolated<[String]>([])
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 5_000), amount: Zatoshi(12_000), fee: Zatoshi(5_000))
        let pczt = Data([0xDD])
        let redacted = Data([0xDD, 0x0F])
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 20) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in
                callLog.withValue { $0.append("unlock") }
                return 1
            }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                callLog.withValue { $0.append("propose") }
                return proposal
            }
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                callLog.withValue { $0.append("createPCZT") }
                return pczt
            }
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in
                callLog.withValue { $0.append("redact") }
                return redacted
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.migrateAnywayImmediateKeystonePCZTProposed)

        #expect(callLog.value == ["unlock", "propose", "createPCZT", "redact"])
        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.immediateReview)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed on top of .complete")
            return
        }
        #expect(signState.pczts == [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: pczt)])
        #expect(signState.redactedSinglePczt == redacted)
    }

    /// Propose/unlock (or PCZT-build) failure falls back to the SAME generic Sending-screen failure
    /// sheet the software fork uses — no new UI, and the coordinator never reaches
    /// `createPCZTFromProposal`/pushes `keystoneSign`.
    @MainActor @Test func completeMigrateAnywayKeystoneProposeFailurePushesSendingWithFailureSheet() async {
        let createPCZTCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 22) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in 0 }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in throw ZcashError.rustProposeSendMaxTransfer("insufficient funds") }
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                createPCZTCalls.withValue { $0 += 1 }
                return Data()
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayAuthenticated)
        // MOB-1458 (F4): clears `isMigratingAnyway` on the failure path — see
        // `completeMigrateAnywaySoftwareProposeFailurePushesSendingWithFailureSheet`'s doc for the
        // from-`true` version of this same assertion.
        await store.receive(\.migrateAnywayFailed)
        await store.receive(\.pushHydratedPathState)

        #expect(createPCZTCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the generic failure-sheet Sending fallback pushed")
            return
        }
        #expect(sendingState.isFailurePresented == true)
    }

    // MARK: - MOB-1458: "Migrate anyway" device-authentication gate
    //
    // The vendor-fork tests above (fixed up for the gate) already prove call ORDER and
    // failure-sheet routing survive the new authentication hop for a PASSED gate, on both vendor
    // lanes — so that coverage isn't duplicated here. This section isolates what's left: the
    // refusal itself, which must short-circuit before ANY of that body runs on EITHER lane (the
    // gate sits ahead of the vendor fork, so which vendor is selected can't matter to it — see
    // `MigrationCoordFlowCoordinator.swift`'s `.complete(.delegate(.migrateAnyway))` case), plus
    // the F4 single-flight/cancellation coverage (code review): a double-tap while the prompt is
    // genuinely in flight must run the unlock/propose/push body exactly once, and BOTH a refusal
    // and a post-gate failure must clear `MigrationComplete.State.isMigratingAnyway` again.

    /// The refusal path — `authenticate()` returning `false` must short-circuit BEFORE the vendor
    /// fork entirely: neither `unlockMigrationResidual` nor `proposeImmediateMigration` ever runs,
    /// nothing is pushed onto the path, and the Complete screen the user was already on stays
    /// exactly as it was — no alert, no toast, no navigation (the established idiom; see
    /// `MigrationCoordFlowCoordinator.swift`'s doc on `.complete(.delegate(.migrateAnyway))`, and
    /// `SendConfirmationStore.sendTapped`/`SwapAndPayCoordFlowCoordinator` for the same shape
    /// elsewhere). The default (software) account is used deliberately — the gate runs before the
    /// vendor fork, so which vendor is selected cannot affect this outcome. MOB-1458 (F4 code
    /// review): this test sends the coordinator delegate directly (not through `migrateAnywayTapped`),
    /// so `isMigratingAnyway` never goes `true` here — the refusal's `.migrateAnywayAuthenticationCancelled`
    /// clear is therefore a harmless same-value no-op in THIS test; see
    /// `completeMigrateAnywayAuthenticationFailureClearsInFlightFlagSoButtonIsLiveAgain` below for
    /// the from-`true` version of that same assertion.
    @MainActor @Test func completeMigrateAnywayAuthenticationFailureNeverUnlocksOrProposesAndLeavesCompleteScreenInPlace() async {
        let unlockCalls = LockIsolated<Int>(0)
        let proposeCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationFailed
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in
                unlockCalls.withValue { $0 += 1 }
                return 0
            }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                proposeCalls.withValue { $0 += 1 }
                return ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 0), amount: .zero, fee: .zero)
            }
        }

        await store.send(.path(.element(id: 0, action: .complete(.delegate(.migrateAnyway)))))
        await store.receive(\.migrateAnywayAuthenticationCancelled)
        await store.finish()

        #expect(unlockCalls.value == 0)
        #expect(proposeCalls.value == 0)
        #expect(store.state.path.count == 1)
        guard case .complete = try? #require(store.state.path.last) else {
            Issue.record("Expected .complete to remain the only/top path element")
            return
        }
    }

    /// MOB-1458 (F4 code review, single-flight): a second tap that lands WHILE the first tap's
    /// device-authentication prompt is still up must be a complete no-op — the child guard
    /// (`MigrationComplete.State.isMigratingAnyway`, set synchronously by `migrateAnywayTapped`)
    /// blocks the second tap from ever re-emitting `.delegate(.migrateAnyway)`, so `authenticate()`
    /// is called exactly once, `unlockMigrationResidual`/`proposeImmediateMigration` each run
    /// exactly once once that one prompt resolves, and exactly one `.sending` screen is appended.
    /// `.mockAuthenticationBlocking` holds the prompt open (same idiom as `MigrationReviewTransferTests
    /// .confirmTappedIgnoresSecondTapWhileAuthenticationInFlight`) so the second tap is proven to
    /// land genuinely mid-prompt — not merely before the first effect had a chance to start. Before
    /// this fix (pre-existing at base `7c1189b9`, not introduced by F2/F3's gates in this same
    /// series): `MigrationComplete.State` carried no in-flight flag at all, so on a passcode-less
    /// device or the simulator (`authenticate()` resolving instantly with NO visible sheet) two
    /// fast taps both got through — two unlock+propose runs and two `.sending` pushes.
    @MainActor @Test func completeMigrateAnywayDoubleTapWhileAuthenticationInFlightRunsUnlockProposeAndPushExactlyOnce() async {
        let authenticateCalls = LockIsolated<Int>(0)
        let unlockCalls = LockIsolated<Int>(0)
        let proposeCalls = LockIsolated<Int>(0)
        let (releaseStream, releaseContinuation) = AsyncStream<Void>.makeStream()
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 5_000), amount: Zatoshi(95_000), fee: Zatoshi(5_000))

        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(dust: Zatoshi(1_000), isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationBlocking(authenticateCalls, releaseStream: releaseStream)
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in
                unlockCalls.withValue { $0 += 1 }
                return 0
            }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in
                proposeCalls.withValue { $0 += 1 }
                return proposal
            }
        }
        store.exhaustivity = .off

        // First tap: `MigrationComplete.migrateAnywayTapped` sets `isMigratingAnyway` synchronously
        // and forwards `.delegate(.migrateAnyway)`, which the coordinator gates — `authenticate()`
        // blocks on `releaseStream`.
        await store.send(.path(.element(id: 0, action: .complete(.migrateAnywayTapped))))
        guard case let .complete(midState) = store.state.path.last else {
            Issue.record("Expected .complete on top after the first tap")
            return
        }
        #expect(midState.isMigratingAnyway == true)

        // Second tap while the prompt is still up: `migrateAnywayTapped`'s own guard makes this a
        // no-op — no second `.delegate(.migrateAnyway)`, so no second `authenticate()` call.
        await store.send(.path(.element(id: 0, action: .complete(.migrateAnywayTapped))))

        releaseContinuation.yield()
        releaseContinuation.finish()

        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.pushHydratedPathState)
        await store.finish()

        #expect(authenticateCalls.value == 1)
        #expect(unlockCalls.value == 1)
        #expect(proposeCalls.value == 1)
        #expect(store.state.path.count == 2)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected exactly one .sending pushed on top of .complete")
            return
        }
        #expect(sendingState.immediateProposal == proposal)
    }

    /// MOB-1458 (F4 code review): a refusal must clear `isMigratingAnyway` too, not just the
    /// post-gate failure path (`completeMigrateAnywaySoftwareProposeFailurePushesSendingWithFailureSheet`
    /// above) — otherwise a user who declines Face ID/Touch ID/passcode once would find "Migrate
    /// anyway" permanently disabled. Unlike `completeMigrateAnywayAuthenticationFailureNeverUnlocksOrProposesAndLeavesCompleteScreenInPlace`
    /// above (which sends the coordinator delegate directly, so the flag is never `true` to begin
    /// with), this one drives through the REAL tap first so the flag genuinely starts `true`.
    @MainActor @Test func completeMigrateAnywayAuthenticationFailureClearsInFlightFlagSoButtonIsLiveAgain() async {
        var state = MigrationCoordFlow.State()
        state.path.append(.complete(MigrationComplete.State(dust: Zatoshi(1_000), isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationFailed
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.migrateAnywayTapped))))
        guard case let .complete(midState) = store.state.path.last else {
            Issue.record("Expected .complete on top after the tap")
            return
        }
        #expect(midState.isMigratingAnyway == true)

        await store.receive(\.migrateAnywayAuthenticationCancelled)

        guard case let .complete(afterState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .complete to remain the only/top path element")
            return
        }
        #expect(afterState.isMigratingAnyway == false)
    }

    // MARK: - MOB-1458 (dead-button fix): dust-lane Keystone ceremony exits clear isMigratingAnyway
    //
    // Code-review finding: `beginImmediateKeystoneCeremony` only ever APPENDS `keystoneSign` (and,
    // once "Get Signature" is tapped, `scan`) on top of whatever screen requested the ceremony — for
    // the dust lane that is a still-live `.complete` element, not popped or replaced. The two
    // pre-existing clear sites above (`.migrateAnywayAuthenticationCancelled`/`.migrateAnywayFailed`)
    // key off the tap-time id and never fire once the ceremony is under way; the ceremony's own three
    // terminal exits (`.keystoneSignRejected`, `.keystoneScanAbandoned`, `.keystoneImmediateSubmitFailed`)
    // pop POSITIONALLY and, before this fix, cleared nothing — stranding
    // `MigrationComplete.State.isMigratingAnyway` at `true` forever, which `migrateAnywayTapped`'s own
    // single-flight guard then reads as "still in flight", permanently disabling the button. The three
    // tests below drive the REAL tap-to-ceremony wiring for a Keystone account through each exit in
    // turn; the fourth proves the fix (`clearMigrateAnywayInFlight`, in the coordinator) is a genuine
    // no-op on the non-dust lanes that share these same three exits.

    /// `.keystoneSignRejected` fires directly off `MigrationKeystoneSignView`'s plain destructive
    /// Reject button, with no scan ever involved — the most trivially reachable of the three exits,
    /// and the one the code review used to demonstrate the bug.
    @MainActor @Test func completeMigrateAnywayKeystoneSignRejectedClearsIsMigratingAnywayOnCompleteBeneath() async {
        let authenticateCalls = LockIsolated<Int>(0)
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 5_000), amount: Zatoshi(12_000), fee: Zatoshi(5_000))
        let pczt = Data([0xDD])
        let redacted = Data([0xDD, 0x0F])
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 50) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationCounting(authenticateCalls)
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in 0 }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in proposal }
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in pczt }
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in redacted }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.migrateAnywayTapped))))
        guard case let .complete(midState) = store.state.path.last else {
            Issue.record("Expected .complete on top after the tap")
            return
        }
        #expect(midState.isMigratingAnyway == true)

        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.migrateAnywayImmediateKeystonePCZTProposed)

        guard let signId = store.state.path.ids.last else {
            Issue.record("Expected a KeystoneSign element id")
            return
        }
        await store.send(.path(.element(id: signId, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(authenticateCalls.value == 1)
        #expect(store.state.path.count == 1)
        guard case let .complete(afterState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign popped, .complete remaining as the only path element")
            return
        }
        #expect(afterState.isMigratingAnyway == false)
    }

    /// `.keystoneScanAbandoned`'s pop-1 shape — a `keystoneSign` build failure
    /// (`MigrationKeystoneSign.Delegate.buildFailed`) abandons before `scan` is ever pushed, so only
    /// `keystoneSign` itself gets popped. Twin of
    /// `keystoneSignBuildFailedAbandonsSessionPoppingOnlyKeystoneSign` (which seeds `.transferPlan`)
    /// for the dust lane's `.complete`.
    @MainActor @Test func completeMigrateAnywayKeystoneScanAbandonedBeforeScanPushedClearsIsMigratingAnywayOnCompleteBeneath() async {
        let authenticateCalls = LockIsolated<Int>(0)
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 5_000), amount: Zatoshi(12_000), fee: Zatoshi(5_000))
        let pczt = Data([0xDD])
        let redacted = Data([0xDD, 0x0F])
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 51) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationCounting(authenticateCalls)
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in 0 }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in proposal }
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in pczt }
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in redacted }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.migrateAnywayTapped))))
        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.migrateAnywayImmediateKeystonePCZTProposed)

        guard let signId = store.state.path.ids.last else {
            Issue.record("Expected a KeystoneSign element id")
            return
        }
        await store.send(.path(.element(id: signId, action: .keystoneSign(.delegate(.buildFailed)))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(authenticateCalls.value == 1)
        #expect(store.state.path.count == 1)
        guard case let .complete(afterState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign popped, .complete remaining as the only path element")
            return
        }
        #expect(afterState.isMigratingAnyway == false)
    }

    /// `.keystoneScanAbandoned`'s pop-2 shape — `scan` IS pushed by the time the ceremony abandons
    /// (here, an unstamped signed PCZT fails the production firmware gate, mirroring
    /// `foundPCZTUnstampedPresentsGateAndAbandons`'s `.reviewTransfer` fixture), so both `scan` and
    /// `keystoneSign` get popped together.
    @MainActor @Test func completeMigrateAnywayKeystoneScanAbandonedAfterScanPushedClearsIsMigratingAnywayOnCompleteBeneath() async {
        let authenticateCalls = LockIsolated<Int>(0)
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 5_000), amount: Zatoshi(12_000), fee: Zatoshi(5_000))
        let pczt = Data([0xDD])
        let redacted = Data([0xDD, 0x0F])
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 52) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationCounting(authenticateCalls)
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in 0 }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in proposal }
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in pczt }
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in redacted }
            // Pushing `scan` resets the shared BC-UR fountain decoder, so the pop-2 shapes touch
            // `keystoneHandler` where the pop-1 shapes above never do.
            $0.keystoneHandler.resetQRDecoder = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.migrateAnywayTapped))))
        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.migrateAnywayImmediateKeystonePCZTProposed)

        guard let signId = store.state.path.ids.last else {
            Issue.record("Expected a KeystoneSign element id")
            return
        }
        await store.send(.path(.element(id: signId, action: .keystoneSign(.delegate(.getSignature)))))

        guard let scanId = store.state.path.ids.last else {
            Issue.record("Expected a Scan element id")
            return
        }
        await store.send(.path(.element(id: scanId, action: .scan(.foundPCZT(Data([0xD0, 0xD1, 0xD2]))))))
        await store.receive(\.keystoneScanAbandoned)

        #expect(authenticateCalls.value == 1)
        #expect(store.state.isKeystoneFirmwareGatePresented == true)
        #expect(store.state.path.count == 1)
        guard case let .complete(afterState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scan + .keystoneSign popped, .complete remaining as the only path element")
            return
        }
        #expect(afterState.isMigratingAnyway == false)
    }

    /// `.keystoneImmediateSubmitFailed` — the post-scan proofs+submit leg fails (device rejects the
    /// broadcast). Its own fallback pushes `.sending` with a failure sheet OVER the retained
    /// `.complete` (the same generic failure UX the software vendor fork's propose failure already
    /// uses, since a dust "Migrate anyway" ceremony has no `.reviewTransfer`/`.transferPlan` of its
    /// own to arm instead) — asserts the clear on the `.complete` element still one level beneath the
    /// pushed `.sending`. This call site is not user-visible today (closing `.sending` ends the flow
    /// before `.complete` could reappear) but is covered anyway per `clearMigrateAnywayInFlight`'s doc.
    @MainActor @Test func completeMigrateAnywayKeystoneImmediateSubmitFailedClearsIsMigratingAnywayOnCompleteBeneathSending() async {
        let authenticateCalls = LockIsolated<Int>(0)
        let proposal = ImmediateMigrationProposal(proposal: .testOnlyFakeProposal(totalFee: 5_000), amount: Zatoshi(12_000), fee: Zatoshi(5_000))
        let pczt = Data([0xDD])
        let redacted = Data([0xDD, 0x0F])
        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 53) }
        state.path.append(.complete(MigrationComplete.State(isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationCounting(authenticateCalls)
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.unlockMigrationResidual = { _ in 0 }
            $0.sdkSynchronizer.proposeImmediateMigration = { _ in proposal }
            $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in pczt }
            $0.sdkSynchronizer.redactPCZTForSigner = { _ in redacted }
            $0.sdkSynchronizer.addProofsToPCZT = { proofed in proofed }
            $0.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { _, _ in .failure(txIds: [], code: -1, description: "rejected") }
            // This lane reaches the submit leg through `scan`, whose push resets the shared BC-UR
            // fountain decoder — so it touches `keystoneHandler` where the pop-1 shapes never do.
            $0.keystoneHandler.resetQRDecoder = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .complete(.migrateAnywayTapped))))
        await store.receive(\.migrateAnywayAuthenticated)
        await store.receive(\.migrateAnywayImmediateKeystonePCZTProposed)

        guard let signId = store.state.path.ids.last else {
            Issue.record("Expected a KeystoneSign element id")
            return
        }
        await store.send(.path(.element(id: signId, action: .keystoneSign(.delegate(.getSignature)))))

        guard let scanId = store.state.path.ids.last else {
            Issue.record("Expected a Scan element id")
            return
        }
        await store.send(.path(.element(id: scanId, action: .scan(.foundPCZT(stampedSignedPczt(major: 3, minor: 0, build: 0)))))) {
            if case .scan(var scanState) = $0.path[id: scanId] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: scanId] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneImmediateSubmitFailed)

        #expect(authenticateCalls.value == 1)
        #expect(store.state.path.count == 2)
        guard case let .sending(sendingState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the generic failure-sheet Sending fallback pushed over .complete")
            return
        }
        #expect(sendingState.isFailurePresented == true)
        guard case let .complete(afterState) = try? #require(store.state.path[id: 0]) else {
            Issue.record("Expected .complete retained beneath the failure-sheet Sending push")
            return
        }
        #expect(afterState.isMigratingAnyway == false)
    }

    /// Regression guard: `clearMigrateAnywayInFlight` scans `state.path.ids` for a `.complete` element
    /// on EVERY `.keystoneSignRejected`, including the non-dust `.reviewTransfer`/`.transferPlan` lanes
    /// that reach this exact same handler (`.transferPlan` is already covered by
    /// `keystoneSignRejectedPopsBackToUnsignedTransferPlanConfirmingScreenUntouched`/
    /// `keystoneSignRejectedNeverCallsStore`) — this is the fix's own regression risk. Proves the scan
    /// is a genuine no-op when no `.complete` exists on the path (the normal case for this lane) by
    /// asserting the retained `.reviewTransfer` element is byte-for-byte EQUAL to what was seeded, not
    /// merely "still `.reviewTransfer`".
    @MainActor @Test func keystoneSignRejectedWithReviewTransferBeneathLeavesReviewTransferStateByteForByteUntouched() async {
        let seededReviewState = MigrationReviewTransfer.State(mode: .immediate)
        var state = MigrationCoordFlow.State()
        state.pendingKeystoneSigning = .immediateReview
        state.path.append(.reviewTransfer(seededReviewState))
        state.path.append(
            .keystoneSign(
                MigrationKeystoneSign.State(
                    pczts: [MigrationUnsignedTransferPczt(id: MigrationReviewTransfer.immediateKeystonePcztId, pczt: Data([0xDD]))],
                    redactedSinglePczt: Data([0xDD, 0x0F])
                )
            )
        )
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        guard let signId = store.state.path.ids.last else {
            Issue.record("Expected a KeystoneSign element id")
            return
        }
        await store.send(.path(.element(id: signId, action: .keystoneSign(.delegate(.rejected)))))
        await store.receive(\.keystoneSignRejected)

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case let .reviewTransfer(afterState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign popped, .reviewTransfer remaining on top")
            return
        }
        #expect(afterState == seededReviewState)
    }

    // MARK: - MOB-1496 (W6 §6): Keystone recovery — recreate routes through the PCZT batch session

    /// MOB-1458 (Task 2): the `.invalidTransfer` (`.notesSpent`) recovery lane keeps the pre-Task-2
    /// restart behavior. Recovery -> `.recreate` -> `restartCurrentMigrationStep` -> re-created plan
    /// -> confirm: for a Keystone account this must route through the SAME PCZT batch session the
    /// fresh-entry plan uses (`MigrationTransferPlanStore.confirmTapped` already forks on vendor
    /// before signing — this proves the COORDINATOR side of that round trip, from the recreated
    /// plan's `keystoneSignRequested` delegate through to a committed, scheduled store). The
    /// `.transferExpired` lane refreshes instead — covered by the refresh-lane tests below.
    @MainActor @Test func recoveryRecreateForKeystoneAccountRoutesThroughKeystoneBatchSessionToStoreAndSchedule() async {
        let restartCalls = LockIsolated<Int>(0)
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let recordCommittedScheduleCalls = LockIsolated<[MigrationSchedule]>([])
        let restartedSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "r0", amount: Zatoshi(2_000_000), anchorHeight: 300, nextExecutableAfterHeight: 300, expiryHeight: 400)
            ],
            estimatedDurationHours: 12,
                    proposalHandle: 1
        )
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "r0", pczt: Data([0x11]))]
        let signed: [Data] = [Data([0x11, 0x99])]
        let expectedStored: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "r0", pczt: Data([0x11, 0x99]))
        ]

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 30) }
        state.path.append(.recovery(MigrationRecovery.State(reason: .notesSpent, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass for this Keystone routing pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return restartedSchedule
            }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            // MOB-1513 (B4): kick stubs — a nil next-due keeps the post-landing kick a silent no-op.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in nil }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordCommittedSchedule = { _, schedule in recordCommittedScheduleCalls.withValue { $0.append(schedule) } }
            // MOB-1458 (W-E): the post-commit chain now hydrates `.scheduled` via
            // `migrationManager.migrationSummary` before pushing — harmless zero, unasserted here.
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
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
        await store.send(
            .path(
                .element(
                    id: scanId,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: scanId] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: scanId] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        // MOB-1458 (W-E): see `transferPlanPostConfirmChain`'s doc — the `.scheduled` push is now
        // hydrated (an async peek), landing via its own action rather than synchronously here.
        await store.receive(\.pushHydratedPathState)
        await store.finish()

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
            estimatedDurationHours: 12,
                    proposalHandle: 1
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
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            $0.sdkSynchronizer.storeSignedNoteSplits = { _, signed in
                storeSignedNoteSplitCalls.withValue { $0.append(signed) }
            }
            // MOB-1513 (B4): the preps broadcast via the post-landing kick's next-due lane now.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "split-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, _ in }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
        }
        store.exhaustivity = .off

        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: 2] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: 2] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.deferredKeystoneScheduleStored)

        #expect(storeCalls.value == [[MigrationSignedTransferPczt(id: "r0", pczt: Data([0x11, 0x99]))]])
        #expect(storeSignedNoteSplitCalls.value == [[MigrationSignedTransferPczt(id: "p0", pczt: Data([0x22, 0x99]))]])
    }

    // MARK: - MOB-1458 (Task 2): expired-recovery refresh-first lane (software + Keystone)

    /// `.transferExpired` recovery, SOFTWARE account: rebuilds the expired transfers IN PLACE via
    /// `refreshStaleMigrationTransfers` with a NON-nil usk (the engine re-signs each rebuilt row),
    /// does NOT call `restartCurrentMigrationStep`, records + reconciles the returned schedule
    /// immediately (record-before-navigation: the SDK already re-signed in place by the time the
    /// refresh returns), and — MOB-1513 (C7, Figma Error & Recovery row 3) — pushes the SAME Confirm
    /// Transfer Plan review screen the design now specifies, rather than landing straight on
    /// Scheduled: `requiresSigning: false` (nothing left to sign) and `isExpiredRecoveryReview: true`
    /// (the routing discriminator its OWN Confirm reads — see
    /// `expiredRecoverySoftwareReviewConfirmedPushesScheduledInsteadOfFlowFinished` right below).
    @MainActor @Test func expiredRecoverySoftwareRefreshesInPlaceAndPushesConfirmReviewWithReturnedSchedule() async {
        let refreshedSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "s0", amount: Zatoshi(3_000_000), anchorHeight: 500, nextExecutableAfterHeight: 500, expiryHeight: 600)
            ],
            estimatedDurationHours: 8,
                    proposalHandle: 1
        )
        let refreshUskNonNil = LockIsolated<[Bool]>([])
        let restartCalls = LockIsolated<Int>(0)
        let reconcileCalls = LockIsolated<Int>(0)
        let recordCommittedScheduleCalls = LockIsolated<[MigrationSchedule]>([])

        // The suite's `init()` selects a software account (`Self.defaultAccount`, zcash vendor,
        // zip32 index 0), so the software lane runs without setting an account here.
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass for this refresh-ordering pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, usk in
                refreshUskNonNil.withValue { $0.append(usk != nil) }
                return refreshedSchedule
            }
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            // Software-lane USK derivation deps — same set as `recreatedPlanConfirmDoesSign`
            // (a real `UnifiedSpendingKey` has no public initializer; it must be derived).
            $0.derivationTool = .liveValue
            $0.mnemonic = .mock
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            $0.migrationManager.recordCommittedSchedule = { _, schedule in recordCommittedScheduleCalls.withValue { $0.append(schedule) } }
            $0.migrationManager.reconcile = { reconcileCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
        await store.receive(\.pushHydratedPathState)
        await store.finish()

        #expect(refreshUskNonNil.value == [true])
        #expect(restartCalls.value == 0)
        // record + reconcile ran BEFORE the review screen appears — both driven by the same single
        // effect, so these counters being right proves the ordering the doc above describes.
        #expect(reconcileCalls.value == 1)
        // The RETURNED schedule is persisted as the committed truth — otherwise the app renders the
        // STALE pre-refresh schedule (duration/timing) from `committedSchedule`.
        #expect(recordCommittedScheduleCalls.value == [refreshedSchedule])
        #expect(store.state.path.count == 2)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the Confirm Transfer Plan review screen pushed on top of .recovery")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.recreated)
        #expect(planState.requiresSigning == false)
        #expect(planState.isExpiredRecoveryReview == true)
        #expect(planState.injectedSchedule == refreshedSchedule)
        #expect(planState.pendingKeystoneRecoveryBatch == nil)
        guard case .recovery = try? #require(store.state.path.first) else {
            Issue.record("Expected .recovery retained beneath the review screen")
            return
        }
    }

    /// MOB-1513 (C7, Figma Error & Recovery row 3): the expired-recovery review screen's OWN
    /// Confirm — unlike the RESCHEDULED variant's identical `requiresSigning == false`
    /// (`rescheduledPlanConfirmedInCoordinatorFinishesFlowWithoutPushingScheduled` above) — pushes
    /// `.scheduled` (hydrated from the schedule the refresh already recorded), rather than finishing
    /// the flow outright. `isExpiredRecoveryReview` is what tells the two `requiresSigning == false`
    /// confirms apart; this screen's Confirm never re-signs, re-proposes, or re-records (nothing
    /// beyond hydrate-and-push runs here).
    @MainActor @Test func expiredRecoverySoftwareReviewConfirmedPushesScheduledInsteadOfFlowFinished() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "s0", amount: Zatoshi(3_000_000), anchorHeight: 500, nextExecutableAfterHeight: 500, expiryHeight: 600)
            ],
            estimatedDurationHours: 8,
                    proposalHandle: 1
        )
        var planState = MigrationTransferPlan.State(variant: .recreated, requiresSigning: false)
        planState.isExpiredRecoveryReview = true
        planState.schedule = schedule
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        state.path.append(.transferPlan(planState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .transferPlan(.delegate(.confirmed)))))
        await store.receive(\.pushHydratedPathState)

        #expect(store.state.path.count == 3)
        guard case let .scheduled(scheduledState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled pushed, not .flowFinished")
            return
        }
        // summary.transferred (zero) + this schedule's own transfer sum.
        #expect(scheduledState.totalAmount == Zatoshi(3_000_000))
        guard case .transferPlan = try? #require(store.state.path[id: 1]) else {
            Issue.record("Expected the review .transferPlan retained beneath .scheduled")
            return
        }
    }

    /// `.transferExpired` recovery, KEYSTONE account: refreshes with a NIL usk (rebuilt rows return
    /// UNSIGNED), then proposes the rebuilt batch off the RETURNED schedule (echoed into
    /// `proposeMigrationPCZTs`). MOB-1513 (C7, Figma Error & Recovery row 3): the ceremony no longer
    /// starts as soon as the propose succeeds — it pushes the SAME Confirm Transfer Plan review
    /// screen the software lane gets, with the already-proposed batch riding the pushed screen's
    /// OWN `pendingKeystoneRecoveryBatch` (not coordinator state — a pop-back without confirming
    /// then discards it for free). See `expiredRecoveryKeystoneReviewConfirmedStartsCeremony` for
    /// the screen's OWN Confirm actually starting the ceremony.
    @MainActor @Test func expiredRecoveryKeystoneRefreshesWithNilUskAndPushesConfirmReviewWithProposedBatch() async {
        let refreshedSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "k0", amount: Zatoshi(4_000_000), anchorHeight: 700, nextExecutableAfterHeight: 700, expiryHeight: 800)
            ],
            estimatedDurationHours: 10,
                    proposalHandle: 1
        )
        let refreshUskNonNil = LockIsolated<[Bool]>([])
        let restartCalls = LockIsolated<Int>(0)
        let proposeScheduleArgs = LockIsolated<[MigrationSchedule]>([])
        let scheduleUnsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "k0", pczt: Data([0x44]))]

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 40) }
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass for this Keystone refresh/propose pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, usk in
                refreshUskNonNil.withValue { $0.append(usk != nil) }
                return refreshedSchedule
            }
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _, _ in [] }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, schedule in
                proposeScheduleArgs.withValue { $0.append(schedule) }
                return scheduleUnsigned
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
        await store.receive(\.recoveryRefreshKeystonePCZTProposed)
        await store.finish()

        #expect(refreshUskNonNil.value == [false])
        #expect(restartCalls.value == 0)
        #expect(proposeScheduleArgs.value == [refreshedSchedule])
        // The ceremony hasn't started yet — it only arms once the review screen's OWN Confirm fires.
        #expect(store.state.pendingKeystoneSigning == nil)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected the Confirm Transfer Plan review screen pushed, not .keystoneSign")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.recreated)
        #expect(planState.requiresSigning == false)
        #expect(planState.isExpiredRecoveryReview == true)
        #expect(planState.injectedSchedule == refreshedSchedule)
        #expect(
            planState.pendingKeystoneRecoveryBatch ==
            MigrationTransferPlan.State.PendingKeystoneRecoveryBatch(pczts: scheduleUnsigned, schedule: refreshedSchedule)
        )
    }

    /// MOB-1513 (C7): the expired-recovery review screen's Confirm, KEYSTONE lane — the batch was
    /// already proposed before this screen ever showed (`recoveryRefreshKeystonePCZTProposed`) and
    /// rides on the screen's own `pendingKeystoneRecoveryBatch`; Confirm is what actually arms
    /// `.recoveryRefresh(schedule:)` and starts the QR ceremony now, not the propose landing.
    @MainActor @Test func expiredRecoveryKeystoneReviewConfirmedStartsCeremony() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "k0", amount: Zatoshi(4_000_000), anchorHeight: 700, nextExecutableAfterHeight: 700, expiryHeight: 800)
            ],
            estimatedDurationHours: 10,
                    proposalHandle: 1
        )
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "k0", pczt: Data([0x44]))]
        let account = walletAccount(keystone: true, idByte: 44)
        var planState = MigrationTransferPlan.State(variant: .recreated, requiresSigning: false)
        planState.isExpiredRecoveryReview = true
        planState.injectedSchedule = schedule
        planState.pendingKeystoneRecoveryBatch = MigrationTransferPlan.State.PendingKeystoneRecoveryBatch(pczts: unsigned, schedule: schedule)

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        state.path.append(.transferPlan(planState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 1, action: .transferPlan(.delegate(.confirmed)))))

        #expect(store.state.pendingKeystoneSigning == MigrationCoordFlow.KeystoneSigningContext.recoveryRefresh(schedule: schedule))
        #expect(store.state.pendingKeystoneSigningAccountUUID == account.id)
        guard case let .keystoneSign(signState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .keystoneSign pushed by the review screen's Confirm")
            return
        }
        #expect(signState.pczts == unsigned)
        guard case .transferPlan = try? #require(store.state.path[id: 1]) else {
            Issue.record("Expected the review .transferPlan retained beneath .keystoneSign")
            return
        }
    }

    /// MOB-1513 (C7): backing out of the Keystone review screen WITHOUT confirming discards the
    /// already-proposed batch for free — it rides on the screen's own `pendingKeystoneRecoveryBatch`
    /// (not coordinator state), so popping the element (TCA's own stack teardown) is all it takes;
    /// no ceremony ever starts (`pendingKeystoneSigning` stays nil throughout), matching
    /// `keystoneScanAbandoned`'s no-partial-state guarantee for every other point this same ceremony
    /// can be abandoned.
    @MainActor @Test func expiredRecoveryKeystoneReviewPopBackDiscardsProposedBatchWithoutStartingCeremony() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "k0", amount: Zatoshi(4_000_000), anchorHeight: 700, nextExecutableAfterHeight: 700, expiryHeight: 800)
            ],
            estimatedDurationHours: 10,
                    proposalHandle: 1
        )
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "k0", pczt: Data([0x44]))]
        var planState = MigrationTransferPlan.State(variant: .recreated, requiresSigning: false)
        planState.isExpiredRecoveryReview = true
        planState.injectedSchedule = schedule
        planState.pendingKeystoneRecoveryBatch = MigrationTransferPlan.State.PendingKeystoneRecoveryBatch(pczts: unsigned, schedule: schedule)

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 45) }
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        state.path.append(.transferPlan(planState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        }
        store.exhaustivity = .off

        await store.send(.path(.popFrom(id: 1)))

        #expect(store.state.pendingKeystoneSigning == nil)
        #expect(store.state.path.count == 1)
        guard case .recovery = try? #require(store.state.path.last) else {
            Issue.record("Expected .recovery back on top after popping the review screen")
            return
        }
    }

    /// `.transferExpired` recovery, KEYSTONE account, full ceremony: proposes, then — MOB-1513 (C7)
    /// — the Confirm Transfer Plan review screen's OWN Confirm starts the ceremony, whose QR
    /// round-trip stores ONLY the rebuilt rows (`storeSignedMigrationTransactions`), records the
    /// RETURNED schedule as the committed truth, and lands on the Scheduled screen (mirroring the
    /// software lane — the review screen, not a re-signing consent screen, and recovery both
    /// retained beneath).
    @MainActor @Test func expiredRecoveryKeystoneCeremonyStoresRebuiltRowsRecordsReturnedScheduleAndSchedules() async {
        let refreshedSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "k0", amount: Zatoshi(4_000_000), anchorHeight: 700, nextExecutableAfterHeight: 700, expiryHeight: 800)
            ],
            estimatedDurationHours: 10,
                    proposalHandle: 1
        )
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let recordCommittedScheduleCalls = LockIsolated<[MigrationSchedule]>([])
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "k0", pczt: Data([0x44]))]
        let signed: [Data] = [Data([0x44, 0x99])]
        let expectedStored: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "k0", pczt: Data([0x44, 0x99]))
        ]

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 41) }
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass for this full-ceremony pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.applyKeystoneBatchSignatures = stubApply(signed)
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, _ in refreshedSchedule }
            $0.sdkSynchronizer.proposeNoteSplitPCZTs = { _, _ in [] }
            $0.sdkSynchronizer.proposeMigrationPCZTs = { _, _ in unsigned }
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordCommittedSchedule = { _, schedule in recordCommittedScheduleCalls.withValue { $0.append(schedule) } }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
        await store.receive(\.recoveryRefreshKeystonePCZTProposed)

        // MOB-1513 (C7): the review screen shows FIRST — its own Confirm is what starts the
        // ceremony now (see `expiredRecoveryKeystoneReviewConfirmedStartsCeremony`).
        guard let planId = store.state.path.ids.last else {
            Issue.record("Expected the Confirm Transfer Plan review screen's element id")
            return
        }
        await store.send(.path(.element(id: planId, action: .transferPlan(.delegate(.confirmed)))))

        guard let signId = store.state.path.ids.last else {
            Issue.record("Expected a KeystoneSign element id")
            return
        }
        await store.send(.path(.element(id: signId, action: .keystoneSign(.delegate(.getSignature)))))
        guard let scanId = store.state.path.ids.last else {
            Issue.record("Expected a Scan element id")
            return
        }
        await store.send(
            .path(
                .element(
                    id: scanId,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: Self.validKeystoneMigrationFirmware))
                )
            )
        ) {
            if case .scan(var scanState) = $0.path[id: scanId] {
                scanState.isKeystoneSigningInProgress = true
                $0.path[id: scanId] = .scan(scanState)
            }
        }
        await store.receive(\.keystoneBatchSignaturesApplied)
        await store.receive(\.keystoneSigningSubmitted)
        await store.receive(\.pushHydratedPathState)
        await store.finish()

        #expect(storeCalls.value == [expectedStored])
        #expect(recordCommittedScheduleCalls.value == [refreshedSchedule])
        #expect(store.state.path.count == 3)
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled after the Keystone recovery ceremony")
            return
        }
        guard case .transferPlan = try? #require(store.state.path[id: planId]) else {
            Issue.record("Expected the review .transferPlan retained beneath .scheduled")
            return
        }
        guard case .recovery = try? #require(store.state.path.first) else {
            Issue.record("Expected .recovery retained beneath the review screen")
            return
        }
    }

    /// A refresh throw (e.g. a funding note spent outside the migration / ZRUST0116) surfaces the
    /// restart-or-cancel alert and navigates nowhere — no automatic retry.
    @MainActor @Test func expiredRecoverySoftwareRefreshFailureShowsRestartAlertAndDoesNotNavigate() async {
        struct RefreshFailure: Error { }
        let restartCalls = LockIsolated<Int>(0)

        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass for this refresh-failure pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, _ in throw RefreshFailure() }
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.derivationTool = .liveValue
            $0.mnemonic = .mock
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
        await store.receive(\.recoveryRefreshFailed)
        await store.finish()

        #expect(store.state.alert != nil)
        #expect(restartCalls.value == 0)
        #expect(store.state.path.count == 1)
        guard case .recovery = try? #require(store.state.path.last) else {
            Issue.record("Expected .recovery still on top — no navigation on a refresh failure")
            return
        }
    }

    /// The refresh-failure alert's primary action restarts the step through the EXISTING restart path
    /// (`restartCurrentMigrationStep` -> reconcile -> re-created plan screen).
    @MainActor @Test func expiredRecoveryRefreshFailureAlertRestartRestartsStepAndPushesPlan() async {
        struct RefreshFailure: Error { }
        let restartCalls = LockIsolated<Int>(0)
        let restartedSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "r0", amount: Zatoshi(1_000_000), anchorHeight: 10, nextExecutableAfterHeight: 10, expiryHeight: 20)
            ],
            estimatedDurationHours: 5,
                    proposalHandle: 1
        )

        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass for this refresh-failure-then-restart pin to be
            // reachable. `.recoveryRestartRequested` (the alert's own follow-up below) is a
            // DIFFERENT action from `.recovery(.delegate(.recreate))` and stays ungated — only the
            // initial tap gates.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, _ in throw RefreshFailure() }
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return restartedSchedule
            }
            $0.derivationTool = .liveValue
            $0.mnemonic = .mock
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
        await store.receive(\.recoveryRefreshFailed)
        #expect(store.state.alert != nil)

        await store.send(.alert(.presented(.restartRequested)))
        await store.receive(\.recoveryRestartRequested)
        await store.receive(\.pushHydratedPathState)
        await store.finish()

        #expect(restartCalls.value == 1)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed after the alert's restart action")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.recreated)
        #expect(planState.injectedSchedule == restartedSchedule)
    }

    /// Cancelling the refresh-failure alert dismisses it and makes no further calls (no restart, no
    /// navigation) — no automatic retry loop.
    @MainActor @Test func expiredRecoveryRefreshFailureAlertCancelMakesNoFurtherCalls() async {
        struct RefreshFailure: Error { }
        let restartCalls = LockIsolated<Int>(0)

        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass for this alert-cancel pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, _ in throw RefreshFailure() }
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.derivationTool = .liveValue
            $0.mnemonic = .mock
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
        await store.receive(\.recoveryRefreshFailed)
        #expect(store.state.alert != nil)

        await store.send(.alert(.dismiss))
        await store.finish()

        #expect(restartCalls.value == 0)
        #expect(store.state.alert == nil)
        #expect(store.state.path.count == 1)
    }

    /// Regression: `.invalidTransfer` (`.notesSpent`) recovery keeps the pre-Task-2 restart behavior
    /// and NEVER refreshes — `refreshStaleMigrationTransfers` is a spontaneous-call hazard for this
    /// lane specifically.
    @MainActor @Test func invalidTransferRecoveryStillRestartsAndNeverRefreshes() async {
        let restartCalls = LockIsolated<Int>(0)
        let refreshCalls = LockIsolated<Int>(0)
        let restartedSchedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "r0", amount: Zatoshi(1_000_000), anchorHeight: 10, nextExecutableAfterHeight: 10, expiryHeight: 20)
            ],
            estimatedDurationHours: 5,
                    proposalHandle: 1
        )

        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(reason: .notesSpent, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass for this `.notesSpent` restart pin to be reachable.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return restartedSchedule
            }
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, _ in
                refreshCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.receive(\.recoveryRecreateAuthenticated)
        await store.receive(\.recoveryRestartRequested)
        await store.receive(\.pushHydratedPathState)
        await store.finish()

        #expect(restartCalls.value == 1)
        #expect(refreshCalls.value == 0)
        guard case let .transferPlan(planState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .transferPlan pushed (restart lane)")
            return
        }
        #expect(planState.variant == MigrationTransferPlan.State.Variant.recreated)
        #expect(planState.injectedSchedule == restartedSchedule)
    }

    // MARK: - MOB-1458 (final review): C1 abandon-never-cancels, I2 deferred-store, I3 single-flight

    /// C1: abandoning a `.recoveryRefresh` Keystone ceremony (here via a below-floor firmware gate)
    /// pops back to Recovery and clears the context like any abandon — but must NOT
    /// `restartCurrentMigrationStep`, because that ceremony operates on the long-committed run the
    /// expired-transfer refresh rebuilt in place (it did not create it). Cancelling would discard the
    /// user's committed run without consent.
    @MainActor @Test func expiredRecoveryKeystoneCeremonyAbandonDoesNotCancelTheCommittedRun() async {
        let restartCalls = LockIsolated<Int>(0)
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "k0", amount: Zatoshi(4_000_000), anchorHeight: 700, nextExecutableAfterHeight: 700, expiryHeight: 800)
            ],
            estimatedDurationHours: 10,
                    proposalHandle: 1
        )
        let unsigned: [MigrationUnsignedTransferPczt] = [MigrationUnsignedTransferPczt(id: "k0", pczt: Data([0x44]))]

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = walletAccount(keystone: true, idByte: 42) }
        state.pendingKeystoneSigning = .recoveryRefresh(schedule: schedule)
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: unsigned)))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
        }
        store.exhaustivity = .off

        // Below-floor firmware → gate fails → `.keystoneScanAbandoned`.
        await store.send(
            .path(
                .element(
                    id: 2,
                    action: .scan(.foundKeystoneBatchSignatures(data: Data(), firmwareVersion: nil))
                )
            )
        )
        await store.receive(\.keystoneScanAbandoned)
        await store.finish()

        #expect(restartCalls.value == 0)
        #expect(store.state.pendingKeystoneSigning == nil)
        guard case .recovery = try? #require(store.state.path.last) else {
            Issue.record("Expected .recovery back on top after abandon (scan + keystoneSign popped)")
            return
        }
    }

    /// I2 (defensive): a `.recoveryRefresh` resume with a non-nil `pendingKeystoneScheduleStore` (as
    /// a preps-carrying refresh would leave) must run the first-delivery kick — broadcasting the prep
    /// and running the deferred `storeSignedMigrationTransactions` + `recordCommittedSchedule` — not
    /// drop them while the UI reports success.
    @MainActor @Test func recoveryRefreshResumeWithDeferredScheduleStoreRunsTheKickAndRecordsSchedule() async {
        let schedule = MigrationSchedule(
            transfers: [
                MigrationTransferProposal(id: "k0", amount: Zatoshi(4_000_000), anchorHeight: 700, nextExecutableAfterHeight: 700, expiryHeight: 800)
            ],
            estimatedDurationHours: 10,
                    proposalHandle: 1
        )
        let scheduleEntries: [MigrationSignedTransferPczt] = [MigrationSignedTransferPczt(id: "k0", pczt: Data([0x44, 0x99]))]
        let storeCalls = LockIsolated<[[MigrationSignedTransferPczt]]>([])
        let recordCommittedScheduleCalls = LockIsolated<[MigrationSchedule]>([])
        let account = walletAccount(keystone: true, idByte: 43)
        let stash = MigrationCoordFlow.PendingScheduleStore(
            accountUUID: account.id,
            scheduleEntries: scheduleEntries,
            schedule: schedule
        )

        var state = MigrationCoordFlow.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.pendingKeystoneSigning = .recoveryRefresh(schedule: schedule)
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [])))
        state.path.append(.scan(Scan.State.initial))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.storeSignedMigrationTransactions = { _, stored in storeCalls.withValue { $0.append(stored) } }
            // A prep broadcast lands, so the deferred schedule store runs.
            $0.sdkSynchronizer.executeNextPendingMigrationTransfer = { _, _ in MigrationTransferResult.success(txId: "prep-tx") }
            $0.migrationBGScheduler.scheduleFirstWindow = { }
            $0.migrationManager.reconcile = { }
            $0.migrationManager.recordTransferBroadcast = { _, _ in }
            $0.migrationManager.recordCommittedSchedule = { _, schedule in recordCommittedScheduleCalls.withValue { $0.append(schedule) } }
            $0.migrationManager.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager.migrationNetworkOptions = { _ in Self.defaultNetworkPrivacyOptions }
            $0.migrationManager.refreshMigrationSyncGate = { }
        }
        store.exhaustivity = .off

        await store.send(.keystoneSigningSubmitted(context: .recoveryRefresh(schedule: schedule), pendingScheduleStore: stash))
        await store.receive(\.pushHydratedPathState)
        await store.receive(\.deferredKeystoneScheduleStored)
        await store.finish()

        #expect(storeCalls.value == [scheduleEntries])
        #expect(recordCommittedScheduleCalls.value == [schedule])
        guard case .scheduled = try? #require(store.state.path.last) else {
            Issue.record("Expected .scheduled after the recovery-refresh resume ran the deferred store")
            return
        }
    }

    /// I3: a second Recovery `.recreate` that arrives while one is already in flight
    /// (`isRecovering == true`) is a no-op — no second refresh/restart, no duplicate navigation.
    @MainActor @Test func recoveryRecreateWhileAlreadyRecoveringIsNoOp() async {
        let refreshCalls = LockIsolated<Int>(0)
        let restartCalls = LockIsolated<Int>(0)

        var recoveryState = MigrationRecovery.State(reason: .expired, isFlowRoot: true)
        recoveryState.isRecovering = true
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(recoveryState))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, _ in
                refreshCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.sdkSynchronizer.restartCurrentMigrationStep = { _ in
                restartCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        await store.finish()

        #expect(refreshCalls.value == 0)
        #expect(restartCalls.value == 0)
        #expect(store.state.path.count == 1)
    }

    /// I3: the coordinator SETS `isRecovering` on the recovery element synchronously when handling
    /// `.recreate` (button disables / spinner), and CLEARS it on the failure alert so Cancel/Restart
    /// leave a usable button.
    @MainActor @Test func recoveryRefreshSetsIsRecoveringAndClearsItOnFailure() async {
        struct RefreshFailure: Error { }

        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            // MOB-1458 (F2): the gate must pass so `isRecovering` (set BEFORE the prompt, per the
            // doc above) survives through to the downstream refresh failure this test pins.
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, _ in throw RefreshFailure() }
            $0.derivationTool = .liveValue
            $0.mnemonic = .mock
            $0.walletStorage = .noOp
            $0.zcashSDKEnvironment = .testnet
            $0.migrationManager.reconcile = { }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        // Set synchronously by the handler — the async gate/refresh failure is buffered until
        // received below.
        guard case let .recovery(midState) = store.state.path.last else {
            Issue.record("Expected .recovery on top after .recreate")
            return
        }
        #expect(midState.isRecovering == true)

        await store.receive(\.recoveryRecreateAuthenticated)
        await store.receive(\.recoveryRefreshFailed)
        #expect(store.state.alert != nil)
        guard case let .recovery(afterState) = store.state.path.last else {
            Issue.record("Expected .recovery still on top under the alert")
            return
        }
        #expect(afterState.isRecovering == false)
    }

    // MARK: - MOB-1458 (code review — F2): device-authentication gate on .recovery(.delegate(.recreate))

    /// A refusal must short-circuit BEFORE either vendor's rebuild/re-sign body runs: nothing is
    /// refreshed, nothing is recorded, and `isRecovering` (set synchronously before the prompt —
    /// see `recoveryRefreshSetsIsRecoveringAndClearsItOnFailure` above for the same set/clear shape
    /// around a downstream failure instead of a refusal) is cleared again so the recovery screen's
    /// Continue button is tappable. The `.expired`/software account/reason combination is used
    /// deliberately — the gate runs before BOTH the vendor fork and the reason split (see
    /// `MigrationCoordFlowCoordinator.swift`'s `.recovery(.delegate(.recreate))` case), so neither
    /// can affect this outcome; the OTHER recovery tests in this file already pin that the gate,
    /// once passed, reaches both vendors and both reasons unchanged.
    @MainActor @Test func recoveryRecreateAuthenticationFailureNeverRefreshesOrRecordsAndClearsIsRecovering() async {
        let refreshCalls = LockIsolated<Int>(0)
        let recordCommittedScheduleCalls = LockIsolated<Int>(0)
        var state = MigrationCoordFlow.State()
        state.path.append(.recovery(MigrationRecovery.State(reason: .expired, isFlowRoot: true)))
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationFailed
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.refreshStaleMigrationTransfers = { _, _ in
                refreshCalls.withValue { $0 += 1 }
                return MigrationSchedule(transfers: [], estimatedDurationHours: 0, proposalHandle: 0)
            }
            $0.migrationManager.recordCommittedSchedule = { _, _ in recordCommittedScheduleCalls.withValue { $0 += 1 } }
        }
        store.exhaustivity = .off

        await store.send(.path(.element(id: 0, action: .recovery(.delegate(.recreate)))))
        guard case let .recovery(midState) = store.state.path.last else {
            Issue.record("Expected .recovery on top after .recreate")
            return
        }
        #expect(midState.isRecovering == true)

        await store.receive(\.recoveryRecreateAuthenticationCancelled)

        #expect(refreshCalls.value == 0)
        #expect(recordCommittedScheduleCalls.value == 0)
        #expect(store.state.path.count == 1)
        guard case let .recovery(afterState) = try? #require(store.state.path.last) else {
            Issue.record("Expected .recovery to remain the only/top path element")
            return
        }
        #expect(afterState.isRecovering == false)
    }
}

// MARK: - MOB-1496 (W6 §2)/MOB-1513: sentinel split + firmware floor — pure function table

/// `MigrationCoordFlow.splitKeystoneBatch` is a small, dependency-free pure function (see its doc in
/// `MigrationCoordFlowCoordinator.swift`) — tested directly here rather than only indirectly through
/// the coordinator reducer, per the brief's "small pure function (testable table)" ask. No
/// shared/global state, so unserialized.
///
/// MOB-1513: `rePairedKeystoneBatch` (app-side re-pairing of the device's scanned bytes against the
/// original unsigned batch) and `firstUnsupportedKeystoneFirmwareVersion` (a per-PCZT firmware-stamp
/// scan) are both REMOVED — the real SDK bridge does the pairing itself
/// (`applyKeystoneBatchSignatures`) and reports firmware once, on the decode envelope
/// (`KeystoneBatchDecodeResult.firmwareVersion`), not per PCZT. The floor comparison itself is now
/// just `ZcashLightClientKit.KeystoneFirmwareVersion`'s own `Comparable` conformance against
/// `MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware` — covered below directly, and via the
/// coordinator-level gate tests in `MigrationCoordFlowTests`.
@Suite struct MigrationCoordFlowPureFunctionTests {
    // MARK: - MOB-1513: the migration batch-signing firmware floor is 3.0.2

    @Test func keystoneMigrationBatchMinimumFirmwareIs302() {
        #expect(MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware == ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2))
    }

    @Test func firmwareBelowFloorComparesLess() {
        let belowFloor = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 1)
        #expect(!(belowFloor >= MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware))
    }

    @Test func firmwareAtOrAboveFloorComparesGreaterOrEqual() {
        let atFloor = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2)
        let aboveFloor = ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 1, build: 0)
        #expect(atFloor >= MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware)
        #expect(aboveFloor >= MigrationCoordFlow.keystoneMigrationBatchMinimumFirmware)
    }

    @Test func versionStringFormatsDotted() {
        #expect(ZcashLightClientKit.KeystoneFirmwareVersion(major: 3, minor: 0, build: 2).versionString == "3.0.2")
    }

    // MARK: - MOB-1513 (R8 finding 1): sentinel-id sanitization around the batch apply

    /// Only sentinel-prefixed ids are rewritten (down to the bare engine id the SDK FFI can
    /// digest); schedule entries and their bytes pass through untouched, order preserved.
    @Test func sanitizedForBatchApplyStripsOnlySentinelPrefixes() {
        let pczts: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#7", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "12", pczt: Data([0xAA]))
        ]

        let sanitized = MigrationCoordFlow.sanitizedForBatchApply(pczts)

        #expect(sanitized == [
            MigrationUnsignedTransferPczt(id: "7", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "12", pczt: Data([0xAA]))
        ])
    }

    /// The apply result comes back positionally (input order, by the SDK contract) — the
    /// ceremony's ORIGINAL ids, sentinel prefixes included, are re-attached so every downstream
    /// consumer (`splitKeystoneBatch`, the stores) sees exactly the ids it always has.
    @Test func reattachOriginalIdsRestoresSentinelIdsPositionally() {
        let originals: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#7", pczt: Data([0x01])),
            MigrationUnsignedTransferPczt(id: "12", pczt: Data([0xAA]))
        ]
        let signed: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "7", pczt: Data([0x01, 0xFF])),
            MigrationSignedTransferPczt(id: "12", pczt: Data([0xAA, 0xFF]))
        ]

        let reattached = MigrationCoordFlow.reattachOriginalIds(from: originals, onto: signed)

        #expect(reattached == [
            MigrationSignedTransferPczt(id: "note-split#7", pczt: Data([0x01, 0xFF])),
            MigrationSignedTransferPczt(id: "12", pczt: Data([0xAA, 0xFF]))
        ])
    }

    /// Defensive: a count mismatch would mean the SDK broke its input-order/input-count apply
    /// contract — the helper then returns the SDK's result untouched rather than zip-truncating
    /// entries away.
    @Test func reattachOriginalIdsOnCountMismatchReturnsSignedUnchanged() {
        let originals: [MigrationUnsignedTransferPczt] = [
            MigrationUnsignedTransferPczt(id: "note-split#7", pczt: Data([0x01]))
        ]
        let signed: [MigrationSignedTransferPczt] = [
            MigrationSignedTransferPczt(id: "7", pczt: Data([0x01, 0xFF])),
            MigrationSignedTransferPczt(id: "8", pczt: Data([0x02, 0xFF]))
        ]

        let reattached = MigrationCoordFlow.reattachOriginalIds(from: originals, onto: signed)

        #expect(reattached == signed)
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
