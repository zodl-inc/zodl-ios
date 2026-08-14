//
//  MigrationBannerResetTests.swift
//  zodlTests
//
//  Restart Migration must leave the Smart Banner with NO memory of the run it cancelled
//  (MOB-1466, Lukas 2026-08-07).
//
//  THE FIELD REPORT: "once I finish restart migration, we need to reset smart banner.. because it
//  renders me 2 of 11 transactions done.. aka previous state.. we must reset the smart banner AND
//  it must offer us Migration required."
//
//  Cancelling the run in the engine does not touch this reducer's own cached answers, and there are
//  five of them — the painted variant, the SB-D1 dwell queue behind it, an answer held back by a
//  pending session verdict (R3), the checking-dwell flag, and slot ownership. Any one left standing
//  re-paints a run that no longer exists, either immediately or when its timer fires.
//

import Foundation
import Testing
import ComposableArchitecture
@testable import zodl_internal

@MainActor
@Suite struct MigrationBannerResetTests {
    /// Every piece of migration memory, set to something stale, then reset. Written as one test
    /// over ALL of them rather than five small ones because the bug is precisely "we cleared four
    /// and forgot the fifth" — a partial reset still paints the dead run.
    @Test func resetClearsEveryCachedMigrationAnswer() async {
        var state = SmartBanner.State()
        state.migrationBannerVariant = .inProgress(done: 2, total: 11, round: nil, totalRounds: nil)
        state.migrationVariantQueue = [.transferSending(number: 3), .idleCounts(done: 3, total: 11)]
        state.isMigrationVariantDwelling = true
        state.isMigrationCheckDwelling = true
        state.heldMigrationVariant = .inProgress(done: 3, total: 11, round: nil, totalRounds: nil)
        state.hasHeldMigrationVariant = true
        state.priorityContent = .priorityMigration

        let store = TestStore(initialState: state) { SmartBanner() }
        store.exhaustivity = .off

        await store.send(.migrationRunReset) {
            $0.migrationBannerVariant = .required
            $0.migrationVariantQueue = []
            $0.isMigrationVariantDwelling = false
            $0.isMigrationCheckDwelling = false
            $0.heldMigrationVariant = nil
            $0.hasHeldMigrationVariant = false
            $0.priorityContent = nil
        }

        // The ladder re-runs from the top — this is what re-asks the manager and lands on the real
        // answer. Without it the banner would sit on the placeholder set above, which would be
        // right by luck today and wrong the moment the manager's derivation changes.
        await store.receive(\.evaluatePriority1)
    }

    /// The reset must NOT evict a banner migration does not own. A restart is a migration-scoped
    /// event; if some higher-priority content (a shielding prompt, a wallet-backup nag) holds the
    /// slot at that moment, taking it away here would be a second bug wearing this fix's clothes.
    @Test func resetLeavesAnotherPrioritysSlotAlone() async {
        var state = SmartBanner.State()
        state.priorityContent = .priority1
        state.migrationBannerVariant = .inProgress(done: 2, total: 11, round: nil, totalRounds: nil)

        let store = TestStore(initialState: state) { SmartBanner() }
        store.exhaustivity = .off

        await store.send(.migrationRunReset) {
            $0.migrationBannerVariant = .required
        }

        #expect(store.state.priorityContent == .priority1, "a slot migration does not own must survive its reset")

        await store.receive(\.evaluatePriority1)
    }

    /// THE STICKY LATCH. `.idle` is the run's termination state and `resolvingIdleTermination`
    /// keeps it for the rest of the session on purpose — so after a restart it would keep asserting
    /// the quiet notify line over a run that no longer exists. Clearing the variant is what drops
    /// it: the latch lives in `migrationBannerVariant` itself, not in a separate flag.
    @Test func resetDropsTheIdleTerminationLatch() async {
        var state = SmartBanner.State()
        state.migrationBannerVariant = .idle
        state.priorityContent = .priorityMigration

        let store = TestStore(initialState: state) { SmartBanner() }
        store.exhaustivity = .off

        await store.send(.migrationRunReset) {
            $0.migrationBannerVariant = .required
            $0.priorityContent = nil
        }

        // Proof the latch is gone: a counts answer now passes through instead of being rewritten
        // to `.idle`, which is exactly what the latch would have done.
        let counts = MigrationBannerVariant.idleCounts(done: 0, total: 4)
        #expect(
            SmartBanner.resolvingIdleTermination(counts, previous: store.state.migrationBannerVariant) == counts
        )

        await store.receive(\.evaluatePriority1)
    }
}
