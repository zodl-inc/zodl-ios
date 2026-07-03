//
//  SmartBannerMigrationTests.swift
//  zodlTests
//
//  MOB-1466: covers the `priorityMigration` wiring added to `SmartBannerStore.swift` — the
//  `PriorityContent.rank` ordering (below priority1/priority2, above everything else), the
//  `.evaluatePriorityMigration` walk step slotted between priority2 and priority3, the
//  `migrationStateStream()` reactive trigger (`.migrationStateChanged`/`.migrationVariantUpdated`),
//  and the `.migrationScreenRequested` tap leaf action. `.serialized`: state touches the
//  process-global `@Shared(.inMemory(.selectedWalletAccount))`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct SmartBannerMigrationTests {
    private func walletAccount(idByte: UInt8) -> WalletAccount {
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

    // MARK: - Rank interplay

    @MainActor @Test func migrationRequestIsRejectedWhilePriority1Shows() async {
        var state = SmartBanner.State()
        state.priorityContent = .priority1
        state.priorityContentRequested = .priority1
        state.isOpen = true
        let store = TestStore(initialState: state) { SmartBanner() }

        await store.send(.triggerPriority(.priorityMigration)) {
            $0.priorityContentRequested = .priorityMigration
        }
        // Guard rejects: priorityMigration.rank (1.5) >= priority1.rank (0) — no further effects.
        await store.receive(\.openBannerRequest)
    }

    @MainActor @Test func migrationRequestIsRejectedWhilePriority2Shows() async {
        var state = SmartBanner.State()
        state.priorityContent = .priority2
        state.priorityContentRequested = .priority2
        state.isOpen = true
        let store = TestStore(initialState: state) { SmartBanner() }

        await store.send(.triggerPriority(.priorityMigration)) {
            $0.priorityContentRequested = .priorityMigration
        }
        // Guard rejects: priorityMigration.rank (1.5) >= priority2.rank (1) — no further effects.
        await store.receive(\.openBannerRequest)
    }

    @MainActor @Test func priority1RequestReplacesAShowingMigrationBanner() async {
        var state = SmartBanner.State()
        state.priorityContent = .priorityMigration
        state.priorityContentRequested = .priorityMigration
        state.isOpen = true
        let store = TestStore(initialState: state) { SmartBanner() }
        store.dependencies.mainQueue = .immediate

        await store.send(.triggerPriority(.priority1)) {
            $0.priorityContentRequested = .priority1
        }
        // priority1.rank (0) < priorityMigration.rank (1.5) — allowed; banner is open, so it closes
        // (non-clean) first, then re-requests, then re-opens with the new priority.
        await store.receive(\.openBannerRequest)
        await store.receive(\.closeBanner) {
            $0.isOpen = false
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContent = .priority1
        }
        await store.receive(\.openBanner) {
            $0.delay = 1.0
            $0.isOpen = true
        }
    }

    @MainActor @Test func migrationRequestReplacesAShowingPriority3Banner() async {
        var state = SmartBanner.State()
        state.priorityContent = .priority3
        state.priorityContentRequested = .priority3
        state.isOpen = true
        let store = TestStore(initialState: state) { SmartBanner() }
        store.dependencies.mainQueue = .immediate

        await store.send(.triggerPriority(.priorityMigration)) {
            $0.priorityContentRequested = .priorityMigration
        }
        // priorityMigration.rank (1.5) < priority3.rank (2) — allowed.
        await store.receive(\.openBannerRequest)
        await store.receive(\.closeBanner) {
            $0.isOpen = false
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContent = .priorityMigration
        }
        await store.receive(\.openBanner) {
            $0.delay = 1.0
            $0.isOpen = true
        }
    }

    @MainActor @Test func migrationRequestReplacesAShowingPriority9Banner() async {
        var state = SmartBanner.State()
        state.priorityContent = .priority9
        state.priorityContentRequested = .priority9
        state.isOpen = true
        let store = TestStore(initialState: state) { SmartBanner() }
        store.dependencies.mainQueue = .immediate

        await store.send(.triggerPriority(.priorityMigration)) {
            $0.priorityContentRequested = .priorityMigration
        }
        // priorityMigration.rank (1.5) < priority9.rank (10) — allowed.
        await store.receive(\.openBannerRequest)
        await store.receive(\.closeBanner) {
            $0.isOpen = false
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContent = .priorityMigration
        }
        await store.receive(\.openBanner) {
            $0.delay = 1.0
            $0.isOpen = true
        }
    }

    @MainActor @Test func priority3RequestIsRejectedWhileMigrationShows() async {
        var state = SmartBanner.State()
        state.priorityContent = .priorityMigration
        state.priorityContentRequested = .priorityMigration
        state.isOpen = true
        let store = TestStore(initialState: state) { SmartBanner() }

        await store.send(.triggerPriority(.priority3)) {
            $0.priorityContentRequested = .priority3
        }
        // Guard rejects: priority3.rank (2) >= priorityMigration.rank (1.5) — no further effects.
        await store.receive(\.openBannerRequest)
    }

    @MainActor @Test func priority9RequestIsRejectedWhileMigrationShows() async {
        var state = SmartBanner.State()
        state.priorityContent = .priorityMigration
        state.priorityContentRequested = .priorityMigration
        state.isOpen = true
        let store = TestStore(initialState: state) { SmartBanner() }

        await store.send(.triggerPriority(.priority9)) {
            $0.priorityContentRequested = .priority9
        }
        // Guard rejects: priority9.rank (10) >= priorityMigration.rank (1.5) — no further effects.
        await store.receive(\.openBannerRequest)
    }

    // MARK: - Walk step

    @MainActor @Test func priority2WalkDownReachesEvaluatePriorityMigration() async {
        let store = TestStore(initialState: SmartBanner.State()) {
            SmartBanner()
        } withDependencies: {
            $0.migrationManager.bannerVariant = { _ in nil }
        }
        // A nil variant lets the walk continue all the way to priority9 (untouched, unrelated
        // steps) — only priority2 -> evaluatePriorityMigration -> priority3 is under test here.
        store.exhaustivity = .off

        await store.send(.evaluatePriority2)
        await store.receive(\.evaluatePriorityMigration)
        // Falls through with a nil variant — verified in detail below; here we only assert the
        // walk actually reaches the new step rather than jumping straight to priority3.
        await store.receive(\.migrationVariantLoaded)
        await store.receive(\.evaluatePriority3)
    }

    @MainActor @Test func evaluatePriorityMigrationWithNonNilVariantTriggersMigration() async {
        let account = walletAccount(idByte: 3)
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        let store = TestStore(initialState: state) {
            SmartBanner()
        } withDependencies: {
            $0.migrationManager.bannerVariant = { accountUUID in
                #expect(accountUUID == account.id)
                return MigrationBannerVariant.complete
            }
        }
        store.dependencies.mainQueue = .immediate

        await store.send(.evaluatePriorityMigration)
        await store.receive(\.migrationVariantLoaded) {
            // `.complete`, not the `State()` default (`.required`), so the assignment is an
            // observable change — proves the loaded variant actually lands in state.
            $0.migrationBannerVariant = MigrationBannerVariant.complete
        }
        await store.receive(\.triggerPriority) {
            $0.priorityContentRequested = .priorityMigration
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContent = .priorityMigration
        }
        await store.receive(\.openBanner) {
            $0.delay = 1.0
            $0.isOpen = true
        }
    }

    @MainActor @Test func evaluatePriorityMigrationWithNilVariantFallsThroughToPriority3() async {
        let store = TestStore(initialState: SmartBanner.State()) {
            SmartBanner()
        } withDependencies: {
            $0.migrationManager.bannerVariant = { _ in nil }
        }
        // A nil variant lets the walk continue all the way to priority9 (untouched, unrelated
        // steps) — only the migration -> priority3 hop is under test here.
        store.exhaustivity = .off

        await store.send(.evaluatePriorityMigration)
        await store.receive(\.migrationVariantLoaded)
        await store.receive(\.evaluatePriority3)
        // walletStatus defaults to `.none` — priority3 (restoring) itself is a no-op walk-through.
        await store.receive(\.evaluatePriority4)
    }

    // MARK: - Reactive trigger: variant-only update while showing

    @MainActor @Test func migrationStateChangedWithNonNilVariantWhileShowingOnlyUpdatesState() async {
        let account = walletAccount(idByte: 5)
        var state = SmartBanner.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.priorityContent = .priorityMigration
        state.priorityContentRequested = .priorityMigration
        state.isOpen = true
        state.migrationBannerVariant = MigrationBannerVariant.inProgress(done: 2, total: 5)
        let store = TestStore(initialState: state) {
            SmartBanner()
        } withDependencies: {
            $0.migrationManager.bannerVariant = { accountUUID in
                #expect(accountUUID == account.id)
                return MigrationBannerVariant.inProgress(done: 3, total: 5)
            }
        }

        await store.send(.migrationStateChanged(MigrationState.inProgress(
            MigrationProgress(
                completedTransfers: 3,
                totalTransfers: 5,
                remainingOrchard: Zatoshi.zero,
                nextTransferReadyAtHeight: nil
            )
        )))
        await store.receive(\.migrationVariantUpdated) {
            $0.migrationBannerVariant = MigrationBannerVariant.inProgress(done: 3, total: 5)
        }
        // No `.triggerPriority`/`.closeAndCleanupBanner` follow-up — content re-renders live from
        // the state mutation alone, banner stays open on the same priority.
        #expect(store.state.priorityContent == .priorityMigration)
        #expect(store.state.isOpen)
    }

    @MainActor @Test func migrationStateChangedWithNonNilVariantWhileNotShowingTriggers() async {
        let store = TestStore(initialState: SmartBanner.State()) {
            SmartBanner()
        } withDependencies: {
            $0.migrationManager.bannerVariant = { _ in MigrationBannerVariant.complete }
        }
        store.dependencies.mainQueue = .immediate

        await store.send(.migrationStateChanged(MigrationState.notStarted))
        await store.receive(\.migrationVariantUpdated) {
            // `.complete`, not the `State()` default (`.required`) — see the analogous comment in
            // `evaluatePriorityMigrationWithNonNilVariantTriggersMigration` above.
            $0.migrationBannerVariant = MigrationBannerVariant.complete
        }
        await store.receive(\.triggerPriority) {
            $0.priorityContentRequested = .priorityMigration
        }
        await store.receive(\.openBannerRequest) {
            $0.priorityContent = .priorityMigration
        }
        await store.receive(\.openBanner) {
            $0.delay = 1.0
            $0.isOpen = true
        }
    }

    // MARK: - Reactive trigger: variant nil while migration showing

    @MainActor @Test func migrationStateChangedWithNilVariantWhileMigrationShowingClosesAndRewalks() async {
        var state = SmartBanner.State()
        state.priorityContent = .priorityMigration
        state.priorityContentRequested = .priorityMigration
        state.isOpen = true
        let store = TestStore(initialState: state) {
            SmartBanner()
        } withDependencies: {
            $0.migrationManager.bannerVariant = { _ in nil }
        }
        store.exhaustivity = .off

        await store.send(.migrationStateChanged(MigrationState.complete))
        await store.receive(\.migrationVariantUpdated)
        await store.receive(\.closeBanner) {
            $0.isOpen = false
            $0.priorityContentRequested = nil
            $0.priorityContent = nil
        }
        await store.receive(\.openBannerRequest)
        await store.receive(\.evaluatePriority1)
        // The re-walk continues (evaluatePriority2 -> evaluatePriorityMigration -> ...); with the
        // same `nil`-returning override it walks all the way down without re-triggering migration.
        #expect(store.state.priorityContent == nil)
    }

    @MainActor @Test func migrationStateChangedWithNilVariantWhileNotShowingIsANoOp() async {
        var state = SmartBanner.State()
        state.priorityContent = .priority6
        state.priorityContentRequested = .priority6
        state.isOpen = true
        let store = TestStore(initialState: state) {
            SmartBanner()
        } withDependencies: {
            $0.migrationManager.bannerVariant = { _ in nil }
        }

        await store.send(.migrationStateChanged(MigrationState.complete))
        await store.receive(\.migrationVariantUpdated)
        // Nil while some other priority (not migration) is showing: nothing else happens.
        #expect(store.state.priorityContent == .priority6)
        #expect(store.state.isOpen)
    }

    // MARK: - Tap

    @MainActor @Test func smartBannerContentTappedWithMigrationShowingRequestsMigrationScreen() async {
        var state = SmartBanner.State()
        state.priorityContent = .priorityMigration
        let store = TestStore(initialState: state) { SmartBanner() }

        await store.send(.smartBannerContentTapped)
        await store.receive(\.migrationScreenRequested)
    }

    @MainActor @Test func migrationScreenRequestedProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: SmartBanner.State()) { SmartBanner() }

        await store.send(.migrationScreenRequested)
    }
}
