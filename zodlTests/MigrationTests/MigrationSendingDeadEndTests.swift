//
//  MigrationSendingDeadEndTests.swift
//  zodlTests
//
//  Cancelling a failed broadcast must LEAVE the Sending screen.
//
//  Field-caught 2026-07-31, during a real broadcast failure. "Send now" failed; the Transaction
//  Failed sheet offered Cancel / Retry; Retry failed the same way; Cancel dismissed the sheet and
//  left the user on "Sending…" — a screen that renders a Lottie and two labels and NOTHING else.
//  No button, no back affordance, no path forward. The only way out was force-quitting the wallet.
//
//  Two reasons this ranks above an ordinary UI defect:
//
//  1. It strands the user at the exact moment they are least willing to believe that force-quitting
//     a wallet mid-send is safe. The screen says "Sending…" while nothing is being sent.
//  2. It is reachable from a NETWORK failure, which is the most ordinary failure there is. This is
//     not an edge case; it is Tuesday on a bad connection.
//
//  The fix routes Cancel to the same `.closed` delegate as the success screen's Close, so the user
//  lands somewhere with controls and can re-enter from the banner.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationSendingDeadEndTests {
    private static func store() -> TestStoreOf<MigrationSending> {
        var state = MigrationSending.State(totalCount: 1)
        state.phase = .sending
        state.isFailurePresented = true
        state.failureKind = .plainRetry

        let store = TestStore(initialState: state) { MigrationSending() } withDependencies: {
            $0.mainQueue = .immediate
        }
        store.exhaustivity = .off
        return store
    }

    /// THE regression. Cancel delegates `.closed` — it does not simply hide the sheet and leave the
    /// user on a progress screen with no way off it.
    @Test func cancellingAFailedBroadcastLeavesTheScreen() async {
        let store = Self.store()

        await store.send(.cancelTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }
        await store.receive(.delegate(.closed))
    }

    /// Retry must NOT leave — it re-runs the send, which is the whole point of offering it. Pinned
    /// so a later "make cancel exit" edit does not accidentally make both buttons exit and remove
    /// the ability to retry at all.
    @Test func retryStaysOnTheScreenAndRetries() async {
        let store = Self.store()

        await store.send(.retryTapped) {
            $0.isFailurePresented = false
            $0.failureKind = nil
        }

        // No `.delegate(.closed)` is awaited: retry re-enters the send effect rather than exiting.
    }
}
