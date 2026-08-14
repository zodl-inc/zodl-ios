//
//  MigrationImmediateRetryLaneTests.swift
//  zodlTests
//
//  RETRY MUST RE-ATTEMPT WHAT FAILED.
//
//  The Keystone IMMEDIATE lane broadcasts inside the coordinator, right after the signature comes
//  back (`submitImmediateKeystoneTransaction`). On failure, `.keystoneImmediateSubmitFailed` pops
//  the scan/sign pair and arms the Review element's commit-failure sheet, whose Retry re-runs the
//  whole ceremony from a fresh PCZT + redact. That is the designed remedy, and it is correct.
//
//  Its FALLBACK — taken when the user backed past the Review element before the submit answered,
//  so there is no sheet to arm — used to push a Sending screen with `isFailurePresented: true`.
//  That screen carries no `immediateProposal`, so its Retry ran the Sending store's scheduled-run
//  delivery branch: crank the engine for a `.broadcast` instruction and submit it. An
//  ENGINE-EXTERNAL immediate sweep had failed, and Retry silently drove the SCHEDULED lane
//  instead — a different lane than the failure came from, with no surface saying so.
//
//  The defect PREDATES this branch: upstream's fallback had the same shape through
//  `executeNextPendingMigrationTransfer`.
//
//  The fix converges the fallback on the primary path's remedy: push a FRESH immediate Review
//  carrying the same commit-failure sheet. `.immediate` re-proposes for itself on appear (the
//  idiom `.migrateAnywayUnlocked` already uses), so Retry re-runs the ceremony that failed.
//
//  These tests pin both arms of that handler, and — the other half of the same ruling — that the
//  Sending screen can no longer drive the engine at all.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: installs the process-global `@Shared(.inMemory(.selectedWalletAccount))` the
// coordinator and the Sending store both read.
@Suite(.serialized) @MainActor struct MigrationImmediateRetryLaneTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x0C, count: 16))

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

    /// The path shape at the moment the immediate submit answers: `bottom` beneath the
    /// `keystoneSign` + `scan` pair the handler pops. Whatever `bottom` is becomes the element the
    /// handler finds (or does not find) underneath.
    private static func makeState(bottom: MigrationCoordFlow.Path.State) -> MigrationCoordFlow.State {
        var state = MigrationCoordFlow.State()
        state.path.append(bottom)
        state.path.append(.keystoneSign(MigrationKeystoneSign.State(pczts: [])))
        state.path.append(.scan(Scan.State.initial))
        state.pendingKeystoneSigning = .immediateReview
        state.pendingKeystoneSigningAccountUUID = accountUUID
        state.keystoneImmediateSubmitInFlight = true
        return state
    }

    private static func coordinatorStore(
        bottom: MigrationCoordFlow.Path.State
    ) -> TestStoreOf<MigrationCoordFlow> {
        let store = TestStore(initialState: makeState(bottom: bottom)) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            var client = MigrationManagerClient.noOp
            client.migrationSummary = { _ in MigrationSummary.zero }
            $0.migrationManager = client
            $0.sdkSynchronizer = .mocked()
        }
        store.exhaustivity = .off
        return store
    }

    // MARK: - The handler's two arms

    /// THE PRIMARY PATH, unchanged: the Review element survived the pop, so its own commit-failure
    /// sheet is armed IN PLACE and nothing is pushed. Retry there re-runs the ceremony.
    @Test func aSurvivingReviewIsArmedInPlace() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        let store = Self.coordinatorStore(bottom: .reviewTransfer(MigrationReviewTransfer.State(mode: .immediate)))

        await store.send(.keystoneImmediateSubmitFailed)

        let path = store.state.path
        #expect(path.count == 1, "the scan/sign pair pops and nothing is pushed, got \(path.count) element(s)")
        guard case .reviewTransfer(let reviewState) = path.last else {
            Issue.record("expected the surviving Review element, got \(String(describing: path.last))")
            return
        }
        #expect(reviewState.isFailurePresented, "the surviving Review's own sheet is armed")
        #expect(reviewState.failureReason == .commit, "and it is the COMMIT failure, not a propose failure")
        #expect(!reviewState.isConfirming, "the spinner it was left spinning is cleared")
    }

    /// THE FALLBACK, fixed: the Review element is gone, so a FRESH immediate Review is pushed
    /// carrying the same commit-failure sheet — NOT a Sending screen. This is the whole regression:
    /// the Sending screen it used to push had no proposal, so its Retry drove the scheduled lane.
    @Test func aLostReviewPushesAFreshImmediateReviewNotSending() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        let store = Self.coordinatorStore(bottom: .transferPlan(MigrationTransferPlan.State(variant: .scheduled)))

        await store.send(.keystoneImmediateSubmitFailed)

        let path = store.state.path
        #expect(
            !path.contains { if case .sending = $0 { return true } else { return false } },
            "the fallback must never push the Sending screen — its Retry drives the wrong lane"
        )
        guard case .reviewTransfer(let reviewState) = path.last else {
            Issue.record("expected a fresh Review element on top, got \(String(describing: path.last))")
            return
        }
        #expect(reviewState.mode == .immediate, "immediate mode is what re-proposes on appear")
        #expect(reviewState.isFailurePresented, "the commit-failure sheet is armed on the fresh element")
        #expect(reviewState.failureReason == .commit)
        #expect(
            reviewState.immediateProposal == nil,
            "no proposal is carried: `.immediate`'s own onAppear proposes, which is what makes Retry re-run the ceremony"
        )
    }

    /// The tombstone check is untouched by the fix: a ceremony the user already abandoned drops the
    /// late failure silently rather than pushing anything at all.
    @Test func anAbandonedCeremonyDropsTheLateFailure() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        var state = Self.makeState(bottom: .transferPlan(MigrationTransferPlan.State(variant: .scheduled)))
        state.pendingKeystoneSigning = nil
        let store = TestStore(initialState: state) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
            $0.sdkSynchronizer = .mocked()
        }
        store.exhaustivity = .off

        await store.send(.keystoneImmediateSubmitFailed)

        #expect(store.state.path.count == 3, "nothing pops and nothing pushes for an abandoned ceremony")
    }

    // MARK: - The Sending screen no longer drives the engine

    /// THE PORTED SEMANTICS of the deleted scheduled-run delivery branch. That branch was the only
    /// consumer of `MigrationManagerClient.nextBroadcastInstruction`, and both are gone: a Sending
    /// screen with no `immediateProposal` now has nothing to submit and says so, WITHOUT cranking
    /// the engine or broadcasting.
    ///
    /// The `.mocked` synchronizer's `migrationAdvanceStep` and `performMigrationBroadcast` are
    /// counted rather than left unimplemented, so a reintroduced drive fails loudly here instead of
    /// silently working.
    @Test func retryOnAProposallessSendingScreenNeverConsultsTheDrive() async {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        $selectedWalletAccount.withLock { $0 = Self.account() }

        let cranks = LockIsolated<Int>(0)
        let broadcasts = LockIsolated<Int>(0)

        var state = MigrationSending.State(totalCount: 1)
        state.isFailurePresented = true
        state.failureKind = .plainRetry

        let store = TestStore(initialState: state) { MigrationSending() } withDependencies: {
            $0.mainQueue = .immediate
            $0.migrationManager = MigrationManagerClient.noOp
            $0.sdkSynchronizer = .mocked(
                migrationAdvanceStep: { _ in
                    cranks.withValue { $0 += 1 }
                    return nil
                },
                performMigrationBroadcast: { _, _, _ in
                    broadcasts.withValue { $0 += 1 }
                    return .success(txId: "must-not-run")
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(\.transferResult) {
            $0.isFailurePresented = true
        }

        #expect(cranks.value == 0, "a Retry on this screen must never crank the engine")
        #expect(broadcasts.value == 0, "and must never broadcast a scheduled transfer")
    }
}
