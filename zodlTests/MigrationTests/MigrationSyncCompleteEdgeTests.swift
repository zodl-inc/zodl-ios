//
//  MigrationSyncCompleteEdgeTests.swift
//  zodlTests
//
//  The sync-complete edge must run the migration sweeps on a wallet that HAS an account.
//
//  Field-caught 2026-07-31, and the most consequential defect of the session. `Root`'s
//  `.synchronizerStateChanged` case built `migrationReconcileEffect` on the edge into `.upToDate` —
//  prove sweep, reconcile, notification arming — and then returned it from
//  exactly ONE path:
//
//      guard let account = state.selectedWalletAccount else {
//          return migrationReconcileEffect     // the ONLY return that carried it
//      }
//
//  Every later `return` in that case discarded it. So the entire migration edge ran only when NO
//  account was selected — precisely the case with nothing to migrate — and never on a real wallet.
//
//  What that looked like on a device: the engine asked to prove preparation (0,0) at every open,
//  forever; nothing proved it, so nothing was ever broadcast; a committed run sat at 0-of-12 with
//  all four preparations reading "Ready now". A migration that could not take its first step.
//
//  Note what this did NOT look like: an error. No throw, no failed call, no red anything. An effect
//  was constructed and dropped, which is invisible from every angle except the absence of work.
//  Giving the sweeps their callers (board A24/A28) was necessary and not sufficient — the callers
//  existed and their effect was thrown away one line later.
//
//  So the tests below assert the sweeps RUN, on the path that matters (an account IS selected), and
//  do not assert anything about what they return. Reaching them was the whole bug.
//
//  MOB-1466 (2026-08-02): the edge no longer hand-sequences prove-sweep/reconcile/re-arm. It calls
//  `migrationManager.advance(.afterSync)`, which asks the engine what the run needs and discharges
//  exactly that — the prove sweep is what it does when the answer is `.prove`, which on a healthy
//  run at the tip it usually is. These tests moved to that seam with their claims intact, and gained
//  one: the PHASE is now pinned too. `.afterSync` at this edge is a privacy property, not a detail —
//  it is the only phase allowed to prove, and the one forbidden from broadcasting, because this
//  session has already been on the wire.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct MigrationSyncCompleteEdgeTests {
    private static func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func upToDateState() -> RedactableSynchronizerState {
        var state = SynchronizerState.zero
        state.syncStatus = .upToDate
        state.latestBlockHeight = 4_200_000
        return state.redacted
    }

    /// Records every driver call and the phase it ran at. The phase matters as much as the count:
    /// a `.beforeSync` call at this edge would mean a session that has already synced was about to
    /// be allowed to broadcast, which is the exact correlation ZIP 318 forbids.
    private struct SweepSpy: Sendable {
        let phases = LockIsolated<[MigrationOpenPhase]>([])
        /// Event signal for the waits below: `advance` yields every phase it records, so a test
        /// suspends until the call actually happens instead of polling against a wall-clock
        /// deadline. The old 10 s `waitUntil` budget raced work scheduled on the globally shared
        /// concurrency pool, which CI load can starve long past any fixed deadline (trivial tests
        /// have taken 20-35 s on loaded runners) even when nothing is wrong.
        private let signal = AsyncStream.makeStream(of: MigrationOpenPhase.self)

        var afterSyncCalls: Int { phases.value.filter { $0 == .afterSync }.count }

        func install(_ values: inout DependencyValues) {
            var client = MigrationManagerClient.noOp
            client.recordSyncCompleted = { }
            client.advance = { phase in
                phases.withValue { $0.append(phase) }
                signal.continuation.yield(phase)
                return .proved(count: 0)
            }
            client.armNextWindowNotifications = { _ in }
            values.migrationManager = client
        }

        /// Suspends until the first `.afterSync` advance is recorded — event-driven, no deadline.
        /// A call that genuinely never comes is recorded by the suite's `.timeLimit` backstop
        /// instead of a budget here.
        func firstAfterSync() async {
            for await phase in signal.stream where phase == .afterSync {
                return
            }
        }
    }

    // MARK: - The regression

    /// THE test. An account is selected — the ordinary case, and the one that was broken — and sync
    /// reaches the tip. Both must run. (The invalidation sweep used to be pinned here too; both of
    /// its jobs are the engine's now, recorded/promoted on every `migrationAdvanceStep` read.)
    @Test func theSweepsRunWhenAnAccountIsSelected() async {
        let spy = SweepSpy()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = Self.walletAccount(idByte: 90) }

        let store = Store(initialState: initialState) { Root() } withDependencies: {
            baseMigrationEdgeDependencies(&$0)
            spy.install(&$0)
        }

        store.send(.synchronizerStateChanged(Self.upToDateState()))
        await spy.firstAfterSync()

        #expect(spy.afterSyncCalls == 1, "the edge is where the engine gets asked what the run needs next")
        #expect(
            !spy.phases.value.contains(.beforeSync),
            "a session that has already synced must never reach the phase that may broadcast"
        )
    }

    /// The edge fires ONCE per arrival at the tip, not on every tick while already synced — the
    /// property the `wasSyncUpToDateForMigration` latch exists for. Pinned alongside the fix so
    /// "make sure it runs" cannot quietly become "run it constantly", which would storm the engine
    /// with proving work at the tip.
    @Test func theSweepsDoNotRerunWhileAlreadySynced() async {
        let spy = SweepSpy()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = Self.walletAccount(idByte: 91) }

        let store = Store(initialState: initialState) { Root() } withDependencies: {
            baseMigrationEdgeDependencies(&$0)
            spy.install(&$0)
        }

        store.send(.synchronizerStateChanged(Self.upToDateState()))
        await spy.firstAfterSync()
        store.send(.synchronizerStateChanged(Self.upToDateState()))
        store.send(.synchronizerStateChanged(Self.upToDateState()))
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(spy.afterSyncCalls == 1, "three ticks at the tip, one arrival")
    }

    /// The path that always worked keeps working — no account, still swept. Kept so the fix reads as
    /// "carried to every return" rather than "moved from one return to another".
    @Test func theSweepsStillRunWithNoAccountSelected() async {
        let spy = SweepSpy()
        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = nil }

        let store = Store(initialState: initialState) { Root() } withDependencies: {
            baseMigrationEdgeDependencies(&$0)
            spy.install(&$0)
        }

        store.send(.synchronizerStateChanged(Self.upToDateState()))
        await spy.firstAfterSync()

        #expect(spy.afterSyncCalls == 1)
    }
}

private func baseMigrationEdgeDependencies(_ values: inout DependencyValues) {
    values.audioServices = AudioServicesClient(systemSoundVibrate: { })
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mainQueue = .immediate
    values.mnemonic = .mock
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}
