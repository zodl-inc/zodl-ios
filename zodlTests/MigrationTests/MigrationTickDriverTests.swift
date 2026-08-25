//
//  MigrationTickDriverTests.swift
//  zodlTests
//
//  MOB-1466 — the `.tick` phase's DRIVER-side mechanics, exercised against a real
//  `MigrationManagerImpl` with a stubbed SDK rather than the pure decision table
//  (`MigrationStepPlanTests` already pins that a tick's `.broadcast` column matches `.beforeSync`'s).
//  Three properties live only here, in the executor:
//
//   - THE MODE BELT. A tick may broadcast for a `.privateScheduled` run and must not for an
//     `.immediate` one — `.immediate` still gets its one delivery from the open lanes, and ticking
//     it too would send the moment Ironwood activates rather than at the user's chosen pace.
//   - THE SINGLE-FLIGHT LATCH. A `.tick` arriving while another `advance` is in flight must yield
//     (`.skipped`) WITHOUT touching the engine — ticks fire every 30s and must never queue up behind
//     a slower `.beforeSync`/`.afterSync` call, or behind each other. A `.beforeSync`/`.afterSync`
//     caller, by contrast, always waits its turn and runs — an app-open's own driver call must never
//     be silently dropped for arriving mid-tick.
//   - THE PRIVACY-BUFFER FAST PATH. A tick that arrives while the buffer holds must say so cheaply,
//     without spending a per-account engine read to learn what the buffer already knew.
//
//  Arming hygiene (quiet ticks must not re-arm notifications) is pinned here too, at the driver
//  level, per this feature's own spec — arming is `advance`'s business, not Root's.
//

import Foundation
import Testing
@_spi(Testing) @testable @preconcurrency import ZcashLightClientKit
import ComposableArchitecture
@testable import zodl_internal

// Serialized: every test here installs the wallet-wide candidate account set
// (`@Shared(.inMemory(.selectedWalletAccount))` / `.walletAccounts`) that
// `MigrationDerivations.candidateAccountUUIDs` reads off `MigrationManagerImpl` — the same
// process-global state `MigrationSyncCompleteEdgeTests`/`RootMigrationGateRefusalTests` serialize
// their own suites over.
@Suite(.serialized) struct MigrationTickDriverTests {
    // MARK: - Fixtures

    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x07, count: 16))
    /// Testnet NU6.3, mirroring `MigrationBannerEntryTests`'s fixture — the tip sits above it, as it
    /// does on any wallet that can see Ironwood at all.
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000

    private static func activatedState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        return state
    }

    /// `activatedState()` at `.upToDate` — the follow-mode shape the at-tip tick prove keys off.
    /// (`SynchronizerState.zero`'s own status is NOT up-to-date, which is what keeps every other
    /// test in this suite exercising the off-tip column without saying so.)
    private static func atTipState() -> SynchronizerState {
        var state = activatedState()
        state.syncStatus = .upToDate
        return state
    }

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// Installs `accountUUID` as the sole candidate — selected AND the whole wallet-account list —
    /// via the same shared in-memory keys `MigrationManagerImpl.advance` reads. Every test calls
    /// this first; `.serialized` (above) is what makes doing so from several tests safe.
    private static func installCandidateAccount() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $selectedWalletAccount.withLock { $0 = Self.account() }
        $walletAccounts.withLock { $0 = [Self.account()] }
    }

    /// A single pending `.transfer` row at `scheduledHeight` — proved, not yet on the wire — the
    /// minimal fixture `armNextWindowNotifications`'s row-derived send-window candidate needs.
    /// Mirrors `MigrationArmingTests.status(...)`'s shape; this suite only ever needs
    /// this one kind/state combination, so the fuller helper's extra parameters are inlined away.
    private static func pendingTransferStatus(scheduledHeight: BlockHeight) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: 1,
            kind: .transfer(crossing: 0),
            state: .proved,
            scheduledHeight: scheduledHeight,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    /// A freshly-scoped, isolated schedule storage (own `UserDefaults` suite, never `.standard`) —
    /// `MigrationManagerImpl`'s own default (`MigrationScheduleStorage()`) falls back to `.standard`,
    /// which PERSISTS on a simulator across separate `xcodebuild test` invocations. The P4 fold
    /// tests below need `committedSchedule(for: accountUUID) == nil` (so `migrationTransfers`' W1
    /// statuses-only fallback derives the fabricated row) — a fact `.standard` cannot guarantee once
    /// any other suite has ever committed a schedule for this file's hardcoded `accountUUID` on this
    /// same simulator. Mirrors `freshGateStorage` right below.
    private static func freshScheduleStorage() -> MigrationScheduleStorage {
        let suiteName = "MigrationTickDriverTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        return MigrationScheduleStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
    }

    /// A freshly-scoped, isolated gate storage (own `UserDefaults` suite, never `.standard`) with
    /// `accountUUID`'s mode pre-set.
    private static func freshGateStorage(mode: MigrationMode) -> MigrationGateStorage {
        let suiteName = "MigrationTickDriverTests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let storage = MigrationGateStorage(userDefaults: UserDefaults(suiteName: suiteName)!)
        storage.setMigrationMode(mode, for: accountUUID)
        return storage
    }

    private static func isHeld(_ verdict: MigrationStepVerdict) -> Bool {
        if case .held = verdict { return true }
        return false
    }

    /// `armNextWindowNotifications` — reached by every SUBSTANTIVE verdict below, and by every
    /// `.beforeSync`/`.afterSync` call regardless of verdict (arming there is unconditional,
    /// unchanged by this feature) — has three members with no macro-supplied default, so
    /// `@Dependency(\.userNotifications)` has no test implementation at all. No existing suite
    /// exercises the real `advance(phase:)` end to end (every other one spies on the whole
    /// `migrationManager.advance` closure instead), so there is no established stub to mirror; this
    /// is a plain, fully inert client.
    private static func stubUserNotifications(_ values: inout DependencyValues) {
        values.userNotifications = UserNotificationsClient(
            authorizationStatus: { .authorized },
            requestAuthorization: { true },
            scheduleMigrationNotification: { _, _, _ in },
            cancelMigrationNotifications: { _ in },
            clearDeliveredMigrationNotifications: { },
            pendingMigrationNotifications: { [] }
        )
    }

    /// Short, repeated real-time polling for a condition driven by a concurrently-running `Task` —
    /// mirrors `MigrationSyncCompleteEdgeTests`'s `waitUntil`, needed here to know a blocked
    /// `advance` call has genuinely reached (and is parked inside) its engine read before this test
    /// starts a second, concurrent call and makes claims about what that second call did or didn't do.
    private static func waitUntil(
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - The mode belt

    /// An `.immediate` run gets its one delivery from the open lanes — a tick must hold it, and must
    /// never reach the actual submission call to do so.
    @Test func tickHoldsAnImmediateModeRunWithoutInvokingTheBroadcastLane() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
                performMigrationBroadcast: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .success(txId: "should-never-run")
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .immediate))
            return await manager.advance(phase: .tick)
        }

        #expect(Self.isHeld(verdict), "expected .held for an immediate-mode run, got \(verdict)")
        #expect(submissionCalls.value == 0, "the broadcast lane must never submit for an immediate-mode tick")
    }

    /// The mirror: a `.privateScheduled` run's due transfer is exactly what a tick exists to send.
    @Test func tickBroadcastsAPrivateScheduledRunsDueTransfer() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
                performMigrationBroadcast: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .success(txId: "abcd")
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .broadcast(id: 9))
        #expect(submissionCalls.value == 1, "the broadcast lane must submit exactly once")
    }

    // MARK: - One-clock dispatch (AUD-1, 2026-08-05)

    // `beforeSyncWaitingButEstimateDueRoutesToTheBroadcastLane` was deleted 2026-08-07 with the
    // AUD-1 tiebreaker it pinned — see the tick-half note further down for why the wedge it cured
    // no longer has a mechanism. Its quiet mirror below survives unchanged: `.waiting` still
    // means idle, which is now simply the whole story rather than half of it.

    /// The quiet mirror: `.waiting` with nothing due by the estimate stays `.idle` and never
    /// touches the broadcast lane — the one-clock consult is a second opinion from the gate's own
    /// clock, not a new source of sends.
    @Test func beforeSyncWaitingWithNothingDueByTheEstimateStaysIdle() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .waiting, next: nil) },
                performMigrationBroadcast: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .success(txId: "must-not-run")
                },
                hasOverdueMigrationTransfers: { _, _ in false }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            // R0: the open lane needs a live session — pinned via the seam, never the global trace.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .immediate),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .beforeSync)
        }

        #expect(verdict == .idle, "nothing due by either clock — the open arms wake-ups and rests, got \(verdict)")
        #expect(submissionCalls.value == 0, "the broadcast lane must never run")
    }

    // MARK: - Kind-aware preparation delivery (AUD-3)

    /// A status row whose kind marks the id as a note-PREPARATION — the discriminator every
    /// AUD-3 policy site (plan's afterSync cell, mode belt, manual hold, buffer, visit) keys off.
    private static func preparationStatus(id: UInt32) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: id,
            kind: .preparation(layer: 0, index: 0),
            state: .proved,
            scheduledHeight: 4_134_100,
            expiryHeight: nil,
            isReady: true,
            nextAction: .broadcast,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    /// F2: "a preparation is broadcast as soon as it is proved" (the engine's own contract) — a
    /// proved prep offered at the sync edge goes out AT that edge instead of costing the user a
    /// whole extra open. ZIP 318 exempts preps from the sync/broadcast separation.
    @Test func afterSyncDeliversAProvedPreparationAtTheEdge() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
                migrationTransactionStatuses: { _ in [Self.preparationStatus(id: 9)] },
                performMigrationBroadcast: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .success(txId: "prep-at-edge")
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .broadcast(id: 9), "a proved prep is delivered at the edge that proved it, got \(verdict)")
        #expect(submissionCalls.value == 1)
    }

    /// The transfer half of the same cell stands: a TRANSFER broadcast at the sync edge still
    /// defers to the next open (ZIP 318's session separation is exactly about transfers).
    @Test func afterSyncStillDefersATransferBroadcastToTheNextOpen() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
                migrationTransactionStatuses: { _ in [] },
                performMigrationBroadcast: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .success(txId: "must-not-run")
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .deferredToPhase, "a transfer at the edge waits for the next open, got \(verdict)")
        #expect(submissionCalls.value == 0)
    }

    /// 2026-08-07 REVERSAL PIN. A transfer broadcast used to be HELD here: a sync had just
    /// completed, and the app's post-sync privacy buffer refused any send for 600 s after one.
    /// That buffer is deleted — a fixed sync->broadcast delay is an identifiable pattern rather
    /// than a defense against one, the same ruling that removed the SDK's post-broadcast buffer —
    /// so the very same setup must now DELIVER. If a timed hold ever comes back, this goes red.
    ///
    /// (Its sibling, `beforeSyncPreparationDeliveryBypassesThePrivacyBuffer`, pinned AUD-3's
    /// carve-out exempting preparations from that buffer. With nothing left to be exempt from,
    /// there is no distinction to pin and the test went with it.)
    @Test func beforeSyncTransferBroadcastIsNotHeldByARecentSync() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
                migrationTransactionStatuses: { _ in [] },
                performMigrationBroadcast: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .success(txId: "transfer-right-after-a-sync")
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let storage = Self.freshGateStorage(mode: .privateScheduled)
            let manager = MigrationManagerImpl(gateStorage: storage, sessionOrdinalProvider: { 1 })
            return await manager.advance(phase: .beforeSync)
        }

        #expect(verdict == .broadcast(id: 9), "a just-completed sync must not hold a transfer, got \(verdict)")
        #expect(submissionCalls.value == 1)
    }

    /// F4: the mode belt is transfer pacing — an `.immediate` run's due PREPARATION still
    /// tick-delivers (the existing immediate-mode test pins the transfer arm's hold).
    @Test func tickDeliversAnImmediateRunsDuePreparation() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
                migrationTransactionStatuses: { _ in [Self.preparationStatus(id: 9)] },
                performMigrationBroadcast: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .success(txId: "prep-on-tick")
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .immediate))
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .broadcast(id: 9), "an immediate-mode run's prep still tick-delivers, got \(verdict)")
        #expect(submissionCalls.value == 1)
    }

    // MARK: - The txid seam: a proved preparation goes out in the same pass (kris, 2026-08-07)

    /// A PREPARATION PROVED THIS PASS IS SUBMITTED IN THIS PASS, through the txid seam — and NOT
    /// through the engine's delivery ceremony. Quoting the ruling: a proved preparation is a
    /// complete PCZT, preparations are ZIP 318-exempt, and the engine's own contract is that one
    /// is broadcast as soon as it is proved, so its submission is the app's ordinary path.
    ///
    /// This supersedes the interim "a prove pass ends at the proof, for every kind" pin: the prove
    /// return now NAMES the preparations it proved, so the same-pass delivery D2 asked for needs
    /// no second crank and no app-side kind judgement — the SDK's return and its preparation gate
    /// carry both.
    ///
    /// The mock keeps the old TRAP: `performMigrationBroadcast` stands ready to answer any
    /// post-prove read, so an implementation that re-cranked and delivered through the ceremony
    /// would be betrayed by `ceremonyCalls`.
    @Test func provePassSubmitsThePreparationsItProvedThroughTheSeam() async {
        Self.installCandidateAccount()
        let ceremonyCalls = LockIsolated<Int>(0)
        let retrievedTxids = LockIsolated<[Data]>([])
        let submitted = LockIsolated<[PreparedMigrationTransfer]>([])
        let engineMarks = LockIsolated<[(UInt32, MigrationTransferResult)]>([])
        let stepReads = LockIsolated<Int>(0)
        let preparationTxid = Data(repeating: 0x2A, count: 32)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    let read = stepReads.withValue { $0 += 1; return $0 }
                    return read == 1
                        ? MigrationAdvance(
                            step: .prove(transactions: [MigrationProveTarget(id: 2, kind: .preparation(layer: 0, index: 0))]),
                            next: nil
                        )
                        : MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 2)), next: nil)
                },
                migrationTransactionStatuses: { _ in [] },
                performMigrationBroadcast: { _, _, _ in
                    ceremonyCalls.withValue { $0 += 1 }
                    return .success(txId: "must-not-run")
                },
                proveMigrationTransactions: { _, _, _ in
                    MigrationProveOutcome(totalProved: 1, preparationTxids: [preparationTxid])
                },
                takeMigrationPreparation: { _, txid in
                    retrievedTxids.withValue { $0.append(txid) }
                    return PreparedMigrationTransfer(id: 2, txid: txid, pczt: Data([0xDE, 0xAD]))
                },
                submitMigrationPreparation: { prepared in
                    submitted.withValue { $0.append(prepared) }
                    return .success(txIds: [prepared.txid.toHexStringTxId()])
                },
                recordMigrationPreparationBroadcast: { _, prepared, result in
                    engineMarks.withValue { $0.append((prepared.id, result)) }
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .proved(count: 1), "the verdict still reports the proof count, got \(verdict)")
        #expect(
            retrievedTxids.value == [preparationTxid],
            "exactly the txid the prove return named is retrieved, got \(retrievedTxids.value)"
        )
        #expect(submitted.value.count == 1, "the retrieved preparation is submitted once, got \(submitted.value.count)")
        #expect(submitted.value.first?.id == 2, "the engine transfer id rides along for the record path")
        #expect(submitted.value.first?.pczt == Data([0xDE, 0xAD]), "the finalized bytes go out as-is")
        #expect(ceremonyCalls.value == 0, "a preparation must never travel the engine's delivery ceremony")
        #expect(engineMarks.value.count == 1, "the loop closes on the engine exactly once")
        #expect(engineMarks.value.first?.0 == 2, "the mark is keyed by the retrieval DTO's engine transfer id")
        #expect(
            engineMarks.value.first?.1 == .success(txId: preparationTxid.toHexStringTxId()),
            "the landed outcome reaches the engine, got \(String(describing: engineMarks.value.first?.1))"
        )
    }

    /// A PERMANENT REJECTION IS RECORDED (2026-08-08). A server that answers the submit RPC with a
    /// non-duplicate, non-expiry rejection has issued a VERDICT about the transaction, not a
    /// transport hiccup — the engine must be told (`.invalidNote`), so its next crank
    /// re-adjudicates and can raise attention. Recording nothing here — the pre-fix behavior —
    /// left the row re-servable, and every prove pass and 30-second tick re-took and re-submitted
    /// the same doomed preparation until ZIP 203 expiry.
    @Test func provePassRecordsAPermanentRejectionOnTheEngine() async {
        Self.installCandidateAccount()
        let engineMarks = LockIsolated<[MigrationTransferResult]>([])
        let submissions = LockIsolated<Int>(0)
        let preparationTxid = Data(repeating: 0x3B, count: 32)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(
                        step: .prove(transactions: [MigrationProveTarget(id: 3, kind: .preparation(layer: 0, index: 0))]),
                        next: nil
                    )
                },
                migrationTransactionStatuses: { _ in [] },
                proveMigrationTransactions: { _, _, _ in
                    MigrationProveOutcome(totalProved: 1, preparationTxids: [preparationTxid])
                },
                takeMigrationPreparation: { _, txid in
                    PreparedMigrationTransfer(id: 3, txid: txid, pczt: Data([0xAA]))
                },
                submitMigrationPreparation: { _ in
                    submissions.withValue { $0 += 1 }
                    return .failure(txIds: [], code: -25, description: "bad-txns-inputs-spent")
                },
                recordMigrationPreparationBroadcast: { _, _, result in
                    engineMarks.withValue { $0.append(result) }
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .proved(count: 1), "a rejected submission is not a failure of the pass, got \(verdict)")
        #expect(submissions.value == 1, "the submission was attempted")
        #expect(
            engineMarks.value == [.invalidNote],
            "a permanent rejection is recorded as the real verdict, got \(engineMarks.value)"
        )
    }

    /// THE MARKER WINDOW (2026-08-08). While a preparation's bytes are on the wire the app must
    /// READ BUSY — the keep-open banner map and the re-entry route's `isMigrationWorkInFlight`
    /// short-circuit hang off the same in-flight markers `runBroadcastSession` sets, and the
    /// prep-submit lane used to set none of them, so backgrounding mid-submit stalled the split.
    /// Pinned through `isMigrationWorkInFlight`: true DURING the submit, false again after the
    /// pass (cleared on every exit).
    @Test func provePassWearsInFlightMarkersAroundThePreparationSubmit() async {
        Self.installCandidateAccount()
        let managerBox = LockIsolated<MigrationManagerImpl?>(nil)
        let inFlightDuringSubmit = LockIsolated<Bool?>(nil)
        let preparationTxid = Data(repeating: 0x5C, count: 32)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(
                        step: .prove(transactions: [MigrationProveTarget(id: 7, kind: .preparation(layer: 0, index: 0))]),
                        next: nil
                    )
                },
                migrationTransactionStatuses: { _ in [] },
                proveMigrationTransactions: { _, _, _ in
                    MigrationProveOutcome(totalProved: 1, preparationTxids: [preparationTxid])
                },
                takeMigrationPreparation: { _, txid in
                    PreparedMigrationTransfer(id: 7, txid: txid, pczt: Data([0xEE]))
                },
                submitMigrationPreparation: { prepared in
                    inFlightDuringSubmit.setValue(managerBox.value?.isMigrationWorkInFlight)
                    return .success(txIds: [prepared.txid.toHexStringTxId()])
                },
                recordMigrationPreparationBroadcast: { _, _, _ in }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            managerBox.setValue(manager)
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .proved(count: 1))
        #expect(
            inFlightDuringSubmit.value == true,
            "the in-flight markers must be set before the bytes go on the wire, got \(String(describing: inFlightDuringSubmit.value))"
        )
        #expect(
            managerBox.value?.isMigrationWorkInFlight == false,
            "the markers must be cleared once the pass's submission window closes"
        )
    }

    /// ONE BAD PREPARATION DOES NOT ABORT THE PASS. A retrieval that is refused — a txid whose row
    /// is no longer servable, the seam's own readiness gate — is skipped and logged; the rest of
    /// the pass's preparations still go out, and the verdict still reports what was proved. The
    /// proofs are already durable and the engine re-offers whatever did not ship.
    @Test func provePassSkipsAPreparationItCannotRetrieveAndKeepsGoing() async {
        Self.installCandidateAccount()
        let refusedTxid = Data(repeating: 0x01, count: 32)
        let servableTxid = Data(repeating: 0x02, count: 32)
        let submitted = LockIsolated<[Data]>([])
        let marked = LockIsolated<[Data]>([])

        struct StubRetrievalRefusal: Error {}

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(
                        step: .prove(transactions: [
                            MigrationProveTarget(id: 1, kind: .preparation(layer: 0, index: 0)),
                            MigrationProveTarget(id: 2, kind: .preparation(layer: 0, index: 1))
                        ]),
                        next: nil
                    )
                },
                migrationTransactionStatuses: { _ in [] },
                proveMigrationTransactions: { _, _, _ in
                    MigrationProveOutcome(totalProved: 2, preparationTxids: [refusedTxid, servableTxid])
                },
                takeMigrationPreparation: { _, txid in
                    guard txid != refusedTxid else { throw StubRetrievalRefusal() }
                    return PreparedMigrationTransfer(id: 2, txid: txid, pczt: Data([0xBE, 0xEF]))
                },
                submitMigrationPreparation: { prepared in
                    submitted.withValue { $0.append(prepared.txid) }
                    return .success(txIds: [prepared.txid.toHexStringTxId()])
                },
                recordMigrationPreparationBroadcast: { _, prepared, _ in
                    marked.withValue { $0.append(prepared.txid) }
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .proved(count: 2), "the refusal is not a failure of the pass, got \(verdict)")
        #expect(
            submitted.value == [servableTxid],
            "the refused preparation is skipped and the next one still ships, got \(submitted.value)"
        )
        #expect(
            marked.value == [servableTxid],
            "only what actually shipped is marked on the engine, got \(marked.value)"
        )
    }

    /// The same rule from the transfer side: a TRANSFER's `.prove` never broadcasts. The pass
    /// proves it and ends — the transfer waits for its own broadcast session (ZIP 318's separation
    /// is exactly about transfers), so the one-transfer-per-open law holds. The mock is a TRAP: it
    /// stands ready to answer `.broadcast(4)` to any post-prove read, so if the discharge ever
    /// consulted the engine again and acted on it, the submission count would betray it.
    @Test func provePassNeverBroadcastsAfterProvingATransfer() async {
        Self.installCandidateAccount()
        let submissionCalls = LockIsolated<Int>(0)
        let retrievals = LockIsolated<Int>(0)
        let marks = LockIsolated<Int>(0)
        let stepReads = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    let read = stepReads.withValue { $0 += 1; return $0 }
                    return read == 1
                        ? MigrationAdvance(step: .prove(transactions: [MigrationProveTarget(id: 4, kind: .transfer(crossing: 0))]), next: nil)
                        : MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 4)), next: nil)
                },
                migrationTransactionStatuses: { _ in [] },
                performMigrationBroadcast: { _, _, _ in
                    submissionCalls.withValue { $0 += 1 }
                    return .success(txId: "must-not-run")
                },
                proveMigrationTransactions: { _, _, _ in
                    MigrationProveOutcome(totalProved: 1, preparationTxids: [])
                },
                takeMigrationPreparation: { _, _ in
                    retrievals.withValue { $0 += 1 }
                    return PreparedMigrationTransfer(id: 4, txid: Data(), pczt: Data())
                },
                recordMigrationPreparationBroadcast: { _, _, _ in
                    marks.withValue { $0 += 1 }
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .proved(count: 1), "a transfer's prove pass ends at the proof, got \(verdict)")
        #expect(submissionCalls.value == 0, "a transfer must never be delivered from a prove pass")
        #expect(retrievals.value == 0, "the prove return named no preparation, so nothing is retrieved")
        #expect(marks.value == 0, "and nothing is marked: a transfer's outcome is the broadcast lane's to record")
    }

    /// A SUBMISSION THAT THROWS is skipped like a refused retrieval: the pass survives, nothing is
    /// marked on the engine, and the remaining preparations still ship. (`submitMigrationPreparation`
    /// throws when the transaction guard refuses or is cancelled — the submit itself reports
    /// failure by RETURNING, not throwing.)
    @Test func provePassSurvivesASubmissionThatThrows() async {
        Self.installCandidateAccount()
        let throwingTxid = Data(repeating: 0x04, count: 32)
        let servableTxid = Data(repeating: 0x05, count: 32)
        let marked = LockIsolated<[Data]>([])

        struct StubSubmitFailure: Error {}

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(
                        step: .prove(transactions: [MigrationProveTarget(id: 1, kind: .preparation(layer: 0, index: 0))]),
                        next: nil
                    )
                },
                migrationTransactionStatuses: { _ in [] },
                proveMigrationTransactions: { _, _, _ in
                    MigrationProveOutcome(totalProved: 2, preparationTxids: [throwingTxid, servableTxid])
                },
                takeMigrationPreparation: { _, txid in
                    PreparedMigrationTransfer(id: 1, txid: txid, pczt: Data([0xCC]))
                },
                submitMigrationPreparation: { prepared in
                    guard prepared.txid != throwingTxid else { throw StubSubmitFailure() }
                    return .success(txIds: [prepared.txid.toHexStringTxId()])
                },
                recordMigrationPreparationBroadcast: { _, prepared, _ in
                    marked.withValue { $0.append(prepared.txid) }
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .proved(count: 2), "a throwing submit is not a failure of the pass, got \(verdict)")
        #expect(marked.value == [servableTxid], "only the submission that landed is marked, got \(marked.value)")
    }

    /// A TRANSPORT FAILURE on every server (`.grpcFailure`) is the same non-acceptance as a
    /// server rejection: no engine mark. Pinned separately from the `.failure` case because the
    /// two arrive through different result cases and only the mapping unites them.
    @Test func provePassDoesNotMarkTheEngineOnATransportFailure() async {
        Self.installCandidateAccount()
        let engineMarks = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(
                        step: .prove(transactions: [MigrationProveTarget(id: 6, kind: .preparation(layer: 0, index: 0))]),
                        next: nil
                    )
                },
                migrationTransactionStatuses: { _ in [] },
                proveMigrationTransactions: { _, _, _ in
                    MigrationProveOutcome(totalProved: 1, preparationTxids: [Data(repeating: 0x06, count: 32)])
                },
                takeMigrationPreparation: { _, txid in
                    PreparedMigrationTransfer(id: 6, txid: txid, pczt: Data([0xDD]))
                },
                submitMigrationPreparation: { _ in .grpcFailure(txIds: [], reason: .timeout) },
                recordMigrationPreparationBroadcast: { _, _, _ in
                    engineMarks.withValue { $0 += 1 }
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(verdict == .proved(count: 1))
        #expect(engineMarks.value == 0, "an unreachable-servers outcome must never be marked as broadcast")
    }

    /// THE OUTCOME MAPPING, arm by arm — including `.partial`, which `submitProvedPreparations`
    /// cannot reach (it submits ONE transaction, and `.partial` needs both an acceptance and a
    /// failure) and which therefore has no other pin.
    @Test func transferResultMapsEverySubmissionOutcome() {
        #expect(
            MigrationManagerImpl.transferResult(from: .success(txIds: ["abc", "def"]))
                == .success(txId: "abc"),
            "an acceptance reports the first txid the submission returned"
        )
        #expect(
            MigrationManagerImpl.transferResult(from: .partial(txIds: ["abc"], statuses: ["ok"]))
                == .success(txId: "abc"),
            "an acceptance is an acceptance even when a sibling failed"
        )
        #expect(
            MigrationManagerImpl.transferResult(from: .success(txIds: [])) == .success(txId: ""),
            "an acceptance with no txid still reports success, with an empty id"
        )
        #expect(
            MigrationManagerImpl.transferResult(from: .failure(txIds: [], code: -25, description: "bad-txns-inputs-spent"))
                == .invalidNote,
            "a server rejection is a verdict about the transaction — the default rejection class is invalidNote"
        )
        #expect(
            MigrationManagerImpl.transferResult(
                from: .failure(txIds: ["abc"], code: -27, description: "transaction already in block chain")
            ) == .success(txId: "abc"),
            "the duplicate-submission CODE means the transaction landed on an earlier attempt"
        )
        #expect(
            MigrationManagerImpl.transferResult(
                from: .failure(txIds: ["abc"], code: -26, description: "18: txn-already-in-mempool")
            ) == .success(txId: "abc"),
            "a duplicate-submission MESSAGE identifies the same landed transaction without the code"
        )
        #expect(
            MigrationManagerImpl.transferResult(
                from: .failure(txIds: [], code: -26, description: "tx-expiring-soon: expiry height is too close")
            ) == .expired,
            "an expiry-class rejection reports expired, the engine's own vocabulary for it"
        )
        #expect(
            MigrationManagerImpl.transferResult(from: .grpcFailure(txIds: [], reason: .timeout))
                == .networkError(retryable: true),
            "a transport failure carries no server verdict — retryable, records nothing"
        )
    }

    // MARK: - The unconditional tick prove (FIND-5, 2026-08-05)

    /// A tick runs the sweep whenever the engine says `.prove` — at the tip (the 2026-08-02
    /// follow-mode case this lane was born for) and equally OFF it. The at-tip gate that stood
    /// here starved the marathon session: broadcast churn plus the sync gate's ready-broadcast
    /// hold kept `syncStatus` off `.upToDate` for 50+ minutes, ticks deferred every prove while
    /// no edge was coming, and throughput collapsed to one sweep per app-REOPEN under a "Keep
    /// Zodl open" banner. This is the driver half of `MigrationStepPlanTests`'
    /// `tickProvesUnconditionally`.
    @Test func tickRunsTheProveSweepAtTheTip() async {
        Self.installCandidateAccount()
        let sweepCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(step: .prove(transactions: [MigrationProveTarget(id: 4, kind: .transfer(crossing: 0))]), next: nil)
                },
                proveMigrationTransactions: { _, _, _ in
                    sweepCalls.withValue { $0 += 1 }
                    return MigrationProveOutcome(totalProved: 1, preparationTxids: [])
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .proved(count: 1), "an at-tip tick must run the sweep, got \(verdict)")
        #expect(sweepCalls.value == 1, "the sweep must run exactly once")
    }

    /// The marathon pin: OFF the tip (`SynchronizerState.zero`'s status is not `.upToDate`) the
    /// tick proves all the same. The engine's `.prove` is scanned-frame truth; "wait until the
    /// wallet reads up-to-date" was the exact condition send churn never let come true.
    @Test func tickRunsTheProveSweepOffTheTipToo() async {
        Self.installCandidateAccount()
        let sweepCalls = LockIsolated<Int>(0)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(step: .prove(transactions: [MigrationProveTarget(id: 4, kind: .transfer(crossing: 0))]), next: nil)
                },
                proveMigrationTransactions: { _, _, _ in
                    sweepCalls.withValue { $0 += 1 }
                    return MigrationProveOutcome(totalProved: 1, preparationTxids: [])
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .proved(count: 1), "an off-tip tick must run the sweep too, got \(verdict)")
        #expect(sweepCalls.value == 1, "the sweep must run exactly once")
    }

    // The two ONE-CLOCK DISPATCH tick tests were deleted 2026-08-07 with the AUD-1 tiebreaker
    // they pinned (`tickWaitingButEstimateDueRoutesToTheBroadcastLane`, and its mode-belt
    // sibling). The FIND-5 marathon wedge they cured is closed at the ROOT now: the crank applies
    // the wall-clock estimate itself, so a `.waiting` answer is `.waiting` on the same clock the
    // gate uses and the frozen-scanned-frame divergence cannot arise. There is no second clock to
    // reconcile and nothing to synthesise a delivery out of — the queue peek that fed them is
    // gone from the SDK too. The mode belt they guarded is still pinned by the tick tests above.

    // MARK: - Held accounts must not starve their siblings (audit 2026-08-03, #4)

    private static let secondAccountUUID = AccountUUID(id: [UInt8](repeating: 0x0C, count: 16))

    private static func secondAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: secondAccountUUID,
                name: "Keystone",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(1),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// The starvation shape: the SELECTED account is `.immediate` with a permanently-due
    /// broadcast (the mode belt holds it on every tick), the second account is `.privateScheduled`
    /// with its own due transfer. The first hold used to end the discharge loop — account B's
    /// delivery never ran, on every tick, for as long as A stayed due.
    @Test func aHeldAccountDoesNotStarveTheNextAccountsDelivery() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $selectedWalletAccount.withLock { $0 = Self.account() }
        $walletAccounts.withLock { $0 = [Self.account(), Self.secondAccount()] }

        let submittedFor = LockIsolated<[AccountUUID]>([])
        let storage = Self.freshGateStorage(mode: .immediate)
        storage.setMigrationMode(.privateScheduled, for: Self.secondAccountUUID)

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { accountUUID in
                    accountUUID == Self.secondAccountUUID
                        ? MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 7)), next: nil)
                        : MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 1)), next: nil)
                },
                performMigrationBroadcast: { accountUUID, _, _ in
                    submittedFor.withValue { $0.append(accountUUID) }
                    return .success(txId: "efgh")
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: storage)
            return await manager.advance(phase: .tick)
        }

        #expect(verdict == .broadcast(id: 7), "the second account's due transfer must discharge past the first's hold, got \(verdict)")
        #expect(submittedFor.value == [Self.secondAccountUUID], "exactly one submission, for the scheduled account")
    }

    // MARK: - A broadcast verdict means a broadcast LANDED (audit 2026-08-03, #5)

    /// `runBroadcastSession` used to return `true` unconditionally — a disagreement between the
    /// step and the executor (and every failure) read as `.broadcast(id:)` upstream, making a
    /// permanently-failing run indistinguishable in the log from a healthy one.
    ///
    /// 2026-08-07: the disagreement this pinned used to arrive as a `.nothingDue` OUTCOME. With an
    /// instruction in hand that outcome cannot exist, so its successor is the STALE-INSTRUCTION
    /// throw — the row went un-servable between crank and submit. Same property, current mechanism:
    /// nothing was sent, so the verdict must be `.held`, never `.broadcast`.
    @Test func aStaleInstructionAnswersHeldNotBroadcast() async {
        Self.installCandidateAccount()

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 9)), next: nil) },
                performMigrationBroadcast: { _, _, _ in
                    throw ZcashError.rustMigrationTakeBroadcastTransaction("transaction 9 is not proved-and-servable")
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        guard case .held = verdict else {
            Issue.record("a stale instruction submitted nothing, so the verdict must be .held, got \(verdict)")
            return
        }
    }

    // MARK: - A blocked run arms a wake-up (audit 2026-08-03, #13)

    /// A `.needsUser` verdict has no prove or send window of its own, so the arming pass used to
    /// retire the poke entirely — a backgrounded wallet NEVER learned it was waiting on the user.
    /// The blocker now contributes a near-term poke candidate.
    @Test func aNeedsUserVerdictArmsANearTermPoke() async {
        Self.installCandidateAccount()
        let scheduled = LockIsolated<[(MigrationNotification, Date?)]>([])

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .replan, next: nil) },
                migrationTransactionStatuses: { _ in [] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            $0.userNotifications = UserNotificationsClient(
                authorizationStatus: { .authorized },
                requestAuthorization: { true },
                scheduleMigrationNotification: { notification, date, _ in
                    scheduled.withValue { $0.append((notification, date)) }
                },
                cancelMigrationNotifications: { _ in },
                clearDeliveredMigrationNotifications: { },
                pendingMigrationNotifications: { [] }
            )
        } operation: {
            // R0: open-lane drives need a live session — pinned via the seam, never the global trace.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )
            // `.afterSync` — `.replan` answers `.needsUser(runNeedsReplan)` at any phase; the
            // edge is simply where this test drives it.
            return await manager.advance(phase: .afterSync)
        }

        guard case .needsUser = verdict else {
            Issue.record("replan at .afterSync must land on .needsUser, got \(verdict)")
            return
        }
        #expect(scheduled.value.count == 1, "the blocked run must arm exactly one poke")
        if let date = scheduled.value.first?.1 {
            #expect(date.timeIntervalSinceNow < 120, "the blocker poke is near-term, not a window projection")
        } else {
            Issue.record("the blocker poke must carry a date")
        }
    }

    // MARK: - Reevaluate is "sync, then do nothing" (nuttycom, 2026-08-08)

    /// THE PRIVACY PROPERTY, pinned at the driver. nuttycom, reviewing the split at SDK
    /// `93a11081`: *"this does reintroduce the sync-then-possibly-send identifiable behavior that
    /// we don't want. I would prefer that `reevaluate` operate as `sync, then do nothing`."*
    ///
    /// A reevaluate is discharged at `.beforeSync` and its whole content is "let this session
    /// sync". The engine that answered it will very often want a BROADCAST once the scan catches
    /// up — which is precisely what must not happen on this open, because a sync followed seconds
    /// later by a submission is one correlatable pattern on one wire. The mock below is built to
    /// tempt exactly that: its second answer IS a broadcast. The session must still stop.
    @MainActor @Test func aReevaluateSessionSyncsAndThenDoesNothing() async {
        Self.installCandidateAccount()
        let asks = LockIsolated<Int>(0)
        // Flipped once the pre-sync drive is done, standing in for the scan catching up: from then
        // on the engine offers the BROADCAST that reevaluating was blocking. Reaching it in this
        // same session is the regression.
        let syncCaughtUp = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    asks.withValue { $0 += 1 }
                    return syncCaughtUp.value
                        ? MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 4)), next: nil)
                        : MigrationAdvance(step: .reevaluate, next: nil)
                },
                migrationTransactionStatuses: { _ in [] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            $0.userNotifications = UserNotificationsClient(
                authorizationStatus: { .authorized },
                requestAuthorization: { true },
                scheduleMigrationNotification: { _, _, _ in },
                cancelMigrationNotifications: { _ in },
                clearDeliveredMigrationNotifications: { },
                pendingMigrationNotifications: { [] }
            )
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )

            let before = await manager.advance(phase: .beforeSync)
            #expect(before == MigrationStepVerdict.reevaluating)

            // The sync happens, and now the engine would serve the broadcast.
            syncCaughtUp.withValue { $0 = true }
            let asksBeforeTheEdge = asks.value

            // The sync-completion edge of the SAME open. The lane is spent, so it yields without
            // reading the engine at all — the broadcast is left for a session with no sync
            // attached to it. (The count is compared RELATIVELY: how many reads the pre-sync pass
            // itself makes is an implementation detail, that the edge adds none is the property.)
            let after = await manager.advance(phase: .afterSync)
            #expect(
                after == MigrationStepVerdict.skipped,
                "a reevaluate session must not drive after its sync, got \(after)"
            )
            #expect(
                asks.value == asksBeforeTheEdge,
                "the post-sync edge must not ask the engine again — it would be offered the broadcast"
            )
        }
    }

    // MARK: - Step-read failure honesty (audit 2026-08-03, P1)

    /// A THROWN engine read must never flatten into `.noRun` — that verdict self-cancels the tick
    /// loop, so one contended read (a prove sweep holding the wallet DB) used to kill the tick
    /// lane for the rest of the session. The honest answer is `.failed`, which the loop survives.
    @Test func aThrowingStepReadAnswersFailedNotNoRun() async {
        Self.installCandidateAccount()

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    struct ReadFailure: Error { }
                    throw ReadFailure()
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))
            return await manager.advance(phase: .tick)
        }

        guard case .failed = verdict else {
            Issue.record("a thrown step read must answer .failed, got \(verdict)")
            return
        }
    }

    // MARK: - Arming scope (audit 2026-08-03, P1)

    /// Every notification cancel the arming pass makes is SCOPED to the account being armed —
    /// the wallet-wide sweep this used to be erased the OTHER account's just-armed poke on every
    /// per-account pass, leaving a two-account wallet with no armed wake-up at all.
    @Test func armingCancelsOnlyTheArmedAccountsScope() async {
        Self.installCandidateAccount()
        let cancelScopes = LockIsolated<[String?]>([])

        _ = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .waiting, next: nil) },
                migrationTransactionStatuses: { _ in [] }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            $0.userNotifications = UserNotificationsClient(
                authorizationStatus: { .authorized },
                requestAuthorization: { true },
                scheduleMigrationNotification: { _, _, _ in },
                cancelMigrationNotifications: { scope in cancelScopes.withValue { $0.append(scope) } },
                clearDeliveredMigrationNotifications: { },
                pendingMigrationNotifications: { [] }
            )
        } operation: {
            // R0: open-lane drives need a live session — pinned via the seam, never the global trace.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .beforeSync)
        }

        let expectedScope = Data(Self.accountUUID.id).hexEncodedString()
        #expect(!cancelScopes.value.isEmpty, "the arming pass cancels before it arms")
        #expect(
            cancelScopes.value.allSatisfy { $0 == expectedScope },
            "every cancel must carry the armed account's scope, never the wallet-wide nil — got \(cancelScopes.value)"
        )
    }

    // MARK: - Single-flight

    /// A `.tick` arriving mid-advance yields immediately: `.skipped`, and it must never have touched
    /// the engine to make that decision.
    @Test func tickDuringAnInFlightAdvanceSkipsWithoutReadingTheEngine() async {
        Self.installCandidateAccount()
        let engineReadCount = LockIsolated<Int>(0)
        let firstReadStarted = LockIsolated<Bool>(false)
        let releaseFirstRead = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    engineReadCount.withValue { $0 += 1 }
                    firstReadStarted.setValue(true)
                    while !releaseFirstRead.value {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    return MigrationAdvance(step: .waiting, next: nil)
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            // R0: open-lane drives need a live session — pinned via the seam, never the global trace.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )

            let firstTask = Task { await manager.advance(phase: .beforeSync) }
            await Self.waitUntil { firstReadStarted.value }

            let tickVerdict = await manager.advance(phase: .tick)
            #expect(tickVerdict == .skipped)
            #expect(engineReadCount.value == 1, "a skipped tick must not read the engine at all")

            releaseFirstRead.setValue(true)
            _ = await firstTask.value
        }
    }

    /// The mirror: a `.beforeSync`/`.afterSync` caller arriving mid-advance WAITS its turn (FIFO)
    /// rather than skipping, and actually runs once the in-flight call releases the latch.
    @Test func beforeSyncDuringAnInFlightAdvanceWaitsThenRuns() async {
        Self.installCandidateAccount()
        let engineReadCount = LockIsolated<Int>(0)
        let firstReadStarted = LockIsolated<Bool>(false)
        let releaseFirstRead = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    let thisRead = engineReadCount.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    if thisRead == 1 {
                        firstReadStarted.setValue(true)
                        while !releaseFirstRead.value {
                            try? await Task.sleep(nanoseconds: 5_000_000)
                        }
                    }
                    return MigrationAdvance(step: .waiting, next: nil)
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            // R0: open-lane drives need a live session — pinned via the seam, never the global
            // trace. The two lanes hold INDEPENDENT credits, so both first drives run under one
            // ordinal and the FIFO property stays the thing this test pins.
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )

            let firstTask = Task { await manager.advance(phase: .beforeSync) }
            await Self.waitUntil { firstReadStarted.value }

            let secondTask = Task { await manager.advance(phase: .afterSync) }
            // The second call must be genuinely PARKED, not running concurrently — prove it has not
            // read the engine a moment later, mirroring `MigrationSyncCompleteEdgeTests`'
            // `theSweepsDoNotRerunWhileAlreadySynced`'s identical real-time "still hasn't" check.
            try? await Task.sleep(nanoseconds: 100_000_000)
            #expect(engineReadCount.value == 1, "the second call must be parked behind the latch, not running concurrently")

            releaseFirstRead.setValue(true)
            let firstVerdict = await firstTask.value
            let secondVerdict = await secondTask.value

            #expect(firstVerdict == .idle)
            #expect(secondVerdict == .idle)
            // `>=`, not `==` (field 2026-08-05, order-dependence caught by a suite-composition
            // shift): the notification-arming lane issues its own async `migrationAdvanceStep`
            // reads after a drive, and whether they fire here depends on the arming dedup's
            // process-global signature — earlier tests in a full run can leave it pre-armed
            // (reads skipped, count 2), while an isolated run arms fresh (count 4). The FIFO
            // property this test pins is only that the PARKED call eventually ran its own read:
            // the parked-check above already proved nothing ran concurrently, and any count
            // below 2 here would mean the second drive never read at all.
            #expect(engineReadCount.value >= 2, "the second call must run its own engine read once the first released the latch")
        }
    }

    // MARK: - Arming hygiene

    /// A quiet tick verdict must not re-arm notifications — arming reflects the run's ROWS, and a
    /// quiet tick changed none of them. `migrationSyncWakeups` is called from nowhere but
    /// `armNextWindowNotifications`, so counting it is a direct proxy for "did arming run".
    @Test func consecutiveQuietTicksDoNotReArmNotifications() async {
        Self.installCandidateAccount()
        let armingProbeCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .waiting, next: nil) },
                migrationSyncWakeups: { _ in
                    armingProbeCalls.withValue { $0 += 1 }
                    return []
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))

            let first = await manager.advance(phase: .tick)
            let second = await manager.advance(phase: .tick)
            let third = await manager.advance(phase: .tick)

            #expect(first == .idle)
            #expect(second == .idle)
            #expect(third == .idle)
            #expect(armingProbeCalls.value == 0, "a quiet tick verdict must skip arming entirely")
        }
    }

    // MARK: - stateEvents liveness (the progress screen reloads live)

    /// A tick-phase broadcast must poke `stateEvents` the same way `runBroadcastSession` already
    /// does for an open — proving a screen subscribed to it reloads live while the tick's headless
    /// submission is in flight, not only after the driver returns.
    @Test func tickBroadcastPokesStateEventsLive() async {
        Self.installCandidateAccount()

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.activatedState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in MigrationAdvance(step: .broadcast(MigrationBroadcastInstruction(id: 3)), next: nil) },
                performMigrationBroadcast: { _, _, _ in (.success(txId: "abcd")) }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(gateStorage: Self.freshGateStorage(mode: .privateScheduled))

            let received = LockIsolated<[MigrationState]>([])
            let cancellable = manager.stateEvents(accountUUID: Self.accountUUID).sink { state in
                received.withValue { $0.append(state) }
            }

            _ = await manager.advance(phase: .tick)

            #expect(!received.value.isEmpty, "a subscriber must see at least one emission during/after the tick broadcast")
            cancellable.cancel()
        }
    }

    // MARK: - P4: the engine outlook arms the poke (driver pass-through)

    /// P4: the outlook is a real arming candidate — a `.waiting` run with no wake-up, no pending
    /// row and no blocker would retire the poke today; the outlook arms it instead.
    ///
    /// Pinned to the outlook's OWN window, not merely "some concrete date": `.mocked`'s default
    /// `estimatedMigrationChainTip` is `{ 0 }`, which makes `MigrationChainClock.secondsUntil`
    /// degenerate to 0 for EVERY height (`tip > 0` fails), so an unstubbed clock would arm at
    /// `now + notificationBuffer` regardless of the outlook height — a tautology this test used to
    /// pass by accident. Stubbing the tip to `Self.tip` (the same fixture `atTipState()` already
    /// reports) makes the clock real, so the assertion below can only pass if the height is honored.
    @Test func anOutlookArmsThePokeWhereTodayWouldRetireIt() async {
        Self.installCandidateAccount()
        let scheduled = LockIsolated<[(MigrationNotification, Date?)]>([])
        let secondsPerBlock = MigrationChainClock.targetSecondsPerBlock
        let notificationBuffer = max(2 * secondsPerBlock, 150)
        let outlookHeight = Self.tip + 200
        let beforeDrive = Date()

        _ = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(
                        step: .waiting,
                        next: MigrationNextWork(height: outlookHeight, kind: .prove)
                    )
                },
                migrationTransactionStatuses: { _ in [] },
                migrationSyncWakeups: { _ in [] },
                estimatedMigrationChainTip: { Self.tip },
                estimatedMigrationSecondsPerBlock: { secondsPerBlock }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            $0.userNotifications = UserNotificationsClient(
                authorizationStatus: { .authorized },
                requestAuthorization: { true },
                scheduleMigrationNotification: { notification, date, _ in
                    scheduled.withValue { $0.append((notification, date)) }
                },
                cancelMigrationNotifications: { _ in },
                clearDeliveredMigrationNotifications: { },
                pendingMigrationNotifications: { [] }
            )
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        #expect(!scheduled.value.isEmpty, "the outlook must arm the poke a candidate-less arm would retire")
        let armedDate = scheduled.value.first?.1
        #expect(armedDate != nil, "armed at a concrete date, not a placeholder")

        // 200 blocks out at the measured rate, plus the two-block notification slack — the
        // outlook's own window (`MigrationChainClock.notificationDate`), not the buffer-only floor
        // a degenerate clock would produce. `beforeDrive` predates the arm's own `Date()`, so the
        // true offset from it is always >= `expectedOffset`; the ±60s band absorbs execution slack.
        let expectedOffset = 200 * secondsPerBlock + notificationBuffer
        let lowerBound = beforeDrive.addingTimeInterval(expectedOffset - 60)
        let upperBound = beforeDrive.addingTimeInterval(expectedOffset + 60)
        if let armedDate {
            #expect(armedDate >= lowerBound, "armed date must not be earlier than the outlook's window")
            #expect(armedDate <= upperBound, "armed date must not default to the notificationBuffer-only floor")
        }
    }

    /// P4: the outlook is advisory — it feeds arming only, never the verdict. Same drive as the
    /// plain `.waiting` cases, now with an outlook riding along.
    @Test func anOutlookPerturbsNoVerdict() async {
        Self.installCandidateAccount()

        let verdict = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(
                        step: .waiting,
                        next: MigrationNextWork(height: Self.activationHeight + 200, kind: .broadcast)
                    )
                },
                migrationTransactionStatuses: { _ in [] },
                migrationSyncWakeups: { _ in [] },
                // Height-blindness is harmless here — this test pins the VERDICT, not the armed
                // date — but stubbed anyway for consistency with the sibling test above, which
                // does depend on it (see that test's doc for why `.mocked`'s default degrades it).
                estimatedMigrationChainTip: { Self.tip }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            Self.stubUserNotifications(&$0)
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        // Pinned to the exact verdict `beforeSyncDuringAnInFlightAdvanceWaitsThenRuns` asserts for
        // the identical step/phase pair (`.waiting` @ `.afterSync`): `MigrationStepAction.armWakeups`
        // discharges to `.idle` unconditionally (`MigrationStepDriver.execute`) — the one-clock
        // dispatch that could otherwise redirect `.waiting` only fires for `.beforeSync`/`.tick`, so
        // `.afterSync` has no path off `.idle` for this step to begin with.
        #expect(verdict == .idle, "an advisory outlook must not hold or otherwise change the verdict")
    }

    // MARK: - P4: the outlook joins the min-fold, in both directions

    /// P4: the fold's other half — finding-1's sibling test above only pins the outlook WINNING
    /// (no row, no wake-up, nothing else armed). That leaves the min-fold itself unpinned: a row
    /// already gives the arm a real send window, and a far-future outlook must not override it.
    @Test func anOutlookLaterThanTheRowWindowLeavesTheArmedDateAlone() async {
        Self.installCandidateAccount()
        let scheduled = LockIsolated<[(MigrationNotification, Date?)]>([])
        let secondsPerBlock = MigrationChainClock.targetSecondsPerBlock
        let notificationBuffer = max(2 * secondsPerBlock, 150)
        let rowHeight = Self.tip + 400
        let outlookHeight = Self.tip + 100_000
        let beforeDrive = Date()

        _ = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(step: .waiting, next: MigrationNextWork(height: outlookHeight, kind: .prove))
                },
                migrationTransactionStatuses: { _ in [Self.pendingTransferStatus(scheduledHeight: rowHeight)] },
                migrationSyncWakeups: { _ in [] },
                estimatedMigrationChainTip: { Self.tip },
                estimatedMigrationSecondsPerBlock: { secondsPerBlock }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            $0.userNotifications = UserNotificationsClient(
                authorizationStatus: { .authorized },
                requestAuthorization: { true },
                scheduleMigrationNotification: { notification, date, _ in
                    scheduled.withValue { $0.append((notification, date)) }
                },
                cancelMigrationNotifications: { _ in },
                clearDeliveredMigrationNotifications: { },
                pendingMigrationNotifications: { [] }
            )
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        let armedDate = scheduled.value.first?.1
        #expect(armedDate != nil, "the row's own send window must still arm a poke")

        // The row's window: 400 blocks out at the measured rate, run through the row derivation's
        // MINUTES rounding (`MigrationETA.minutesFromNow`) then back to seconds by the arm — a
        // clean 400 * 75s = 30000s = 500 minutes, so no rounding slop enters — plus the two-block
        // notification slack. The outlook sits ~86 days further out (100,000 blocks) and, if the
        // fold were broken (e.g. folding on the OUTLOOK unconditionally), would pull the armed
        // date out to roughly `beforeDrive + 7,500,150s` — far outside this band.
        let rowExpectedOffset = 500.0 * 60 + notificationBuffer
        let lowerBound = beforeDrive.addingTimeInterval(rowExpectedOffset - 60)
        let upperBound = beforeDrive.addingTimeInterval(rowExpectedOffset + 60)
        if let armedDate {
            #expect(armedDate >= lowerBound, "armed date must not be earlier than the row's own window")
            #expect(armedDate <= upperBound, "a later outlook must not pull the armed date away from the row")
        }
    }

    /// P4: the fold's WINNING direction for a row-bearing run — `outlookCandidateDate`'s own doc
    /// promises the outlook "can only make the poke EARLIER, never later"; this is that promise
    /// exercised through the full arm, not just the pure helper `MigrationArmingTests`
    /// already pins.
    @Test func anOutlookEarlierThanTheRowWindowWins() async {
        Self.installCandidateAccount()
        let scheduled = LockIsolated<[(MigrationNotification, Date?)]>([])
        let secondsPerBlock = MigrationChainClock.targetSecondsPerBlock
        let notificationBuffer = max(2 * secondsPerBlock, 150)
        let rowHeight = Self.tip + 400
        let outlookHeight = Self.tip + 10
        let beforeDrive = Date()

        _ = await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.atTipState() },
                isSyncing: { false },
                migrationAdvanceStep: { _ in
                    MigrationAdvance(step: .waiting, next: MigrationNextWork(height: outlookHeight, kind: .prove))
                },
                migrationTransactionStatuses: { _ in [Self.pendingTransferStatus(scheduledHeight: rowHeight)] },
                migrationSyncWakeups: { _ in [] },
                estimatedMigrationChainTip: { Self.tip },
                estimatedMigrationSecondsPerBlock: { secondsPerBlock }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
            $0.userNotifications = UserNotificationsClient(
                authorizationStatus: { .authorized },
                requestAuthorization: { true },
                scheduleMigrationNotification: { notification, date, _ in
                    scheduled.withValue { $0.append((notification, date)) }
                },
                cancelMigrationNotifications: { _ in },
                clearDeliveredMigrationNotifications: { },
                pendingMigrationNotifications: { [] }
            )
        } operation: {
            let manager = MigrationManagerImpl(
                gateStorage: Self.freshGateStorage(mode: .privateScheduled),
                scheduleStorage: Self.freshScheduleStorage(),
                sessionOrdinalProvider: { 1 }
            )
            return await manager.advance(phase: .afterSync)
        }

        let armedDate = scheduled.value.first?.1
        #expect(armedDate != nil, "the outlook must still arm a poke")

        // The outlook's window: 10 blocks out — far sooner than the row's 400-block window. Two
        // independent checks: the armed date lands in the OUTLOOK's own band, and it is strictly
        // below the ROW window's band floor — the fold picked the earlier candidate, not merely
        // "a" concrete date that happens to be less than the row's (which a bug clamping to some
        // other unrelated earlier value could also satisfy).
        let outlookExpectedOffset = 10 * secondsPerBlock + notificationBuffer
        let outlookLowerBound = beforeDrive.addingTimeInterval(outlookExpectedOffset - 60)
        let outlookUpperBound = beforeDrive.addingTimeInterval(outlookExpectedOffset + 60)
        let rowExpectedOffset = 500.0 * 60 + notificationBuffer
        let rowLowerBound = beforeDrive.addingTimeInterval(rowExpectedOffset - 60)

        if let armedDate {
            #expect(armedDate >= outlookLowerBound, "armed date must not be earlier than the outlook's own window")
            #expect(armedDate <= outlookUpperBound, "armed date must land at the outlook's window, not the row's")
            #expect(armedDate < rowLowerBound, "the earlier outlook must win the fold over the later row window")
        }
    }
}
