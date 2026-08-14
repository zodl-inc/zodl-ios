//
//  MigrationCoordFlowReentryRevealTests.swift
//  zodlTests
//
//  FIELD BUG (2026-08-06): a re-entry with a committed run that resolves to a PUSH destination
//  (e.g. the status screen) showed the entry fork — "migrate privately, or manually?" — as the
//  visible base layer beneath the pushed screen, permanently: `pushHydratedPathState` used to
//  append the path element AND set `isReentryResolved = true` in the SAME mutation, so the root's
//  reveal condition was satisfied with the destination merely stacked on top of it. Reachable from
//  the banner: tap it, and the fork sat there under whatever the (fast) SDK reads resolved to.
//
//  THE CONTRACT this suite pins: the fork reveals IFF routing itself chose it as the destination
//  (`reentryRoute()` resolving to `.entry`, i.e. `reentryPathState` returning `nil`). A resolved
//  PUSH destination must never flip `isReentryResolved` — the root stays hidden for that stack's
//  whole life, so a pushed screen always renders over a neutral, permanently-hidden root rather
//  than a tappable fork offering a choice the committed run already made.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationCoordFlowReentryRevealTests {
    /// Re-entry that resolves to a PUSH destination: the element is appended and the fork stays
    /// hidden — `isReentryResolved` remains false, permanently.
    @Test func aPushDestinationKeepsTheForkHidden() async {
        let store = TestStore(initialState: MigrationCoordFlow.State.initial) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            // `statusProgressState` reads this off the sdkSynchronizer for the footer's minutes
            // copy — `.mock` answers every member benignly (0 duration included), unlike the
            // dependency's own `testValue`, which is `unimplemented` here.
            $0.sdkSynchronizer = .mock
            var client = MigrationManagerClient.noOp
            client.reentryRoute = { .statusProgress }
            $0.migrationManager = client
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushHydratedPathState, timeout: .seconds(5))

        #expect(store.state.path.count == 1, "a resolved push destination must land exactly one path element")
        guard case .status(_)? = store.state.path.last else {
            Issue.record("expected the push to land a .status element, got \(String(describing: store.state.path.last))")
            return
        }
        #expect(!store.state.isReentryResolved, "a pushed re-entry destination must keep the fork hidden — it never reveals")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// Re-entry that resolves to the FORK (route .entry): no push, and the fork reveals via
    /// .reentryResolved.
    @Test func aForkDestinationRevealsWithoutPushing() async {
        let store = TestStore(initialState: MigrationCoordFlow.State.initial) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            var client = MigrationManagerClient.noOp
            client.reentryRoute = { .entry }
            $0.migrationManager = client
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.reentryResolved, timeout: .seconds(5))

        #expect(store.state.path.isEmpty, "the fork IS the destination — nothing should be pushed")
        #expect(store.state.isReentryResolved, "routing chose the fork, so it must reveal")

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)
    }

    /// A re-appear with a non-empty path leaves the flag untouched (both prior values) — the
    /// old branch force-flipped it true, which re-revealed the fork beneath a pushed stack.
    @Test func aReappearWithANonEmptyPathLeavesTheFlagAlone() async {
        var pathPresentState = MigrationCoordFlow.State.initial
        pathPresentState.path.append(.status(MigrationStatus.State(presentation: .resume)))

        // Prior == false: the regression case. The old branch force-flipped this to true, which
        // is exactly the re-reveal this suite exists to forbid — an exhaustive send with no
        // trailing closure asserts NO state change at all.
        var hiddenPriorState = pathPresentState
        hiddenPriorState.isReentryResolved = false
        let hiddenPriorStore = TestStore(initialState: hiddenPriorState) {
            MigrationCoordFlow()
        }
        await hiddenPriorStore.send(.onAppear)

        // Prior == true: pinned too, so a future change can't silently start flipping it false
        // on a re-appear either.
        var revealedPriorState = pathPresentState
        revealedPriorState.isReentryResolved = true
        let revealedPriorStore = TestStore(initialState: revealedPriorState) {
            MigrationCoordFlow()
        }
        await revealedPriorStore.send(.onAppear)
    }

    /// FIELD BUG (2026-08-06, whole-branch review): with the reveal gated off, a pushed re-entry
    /// stack is exactly one element over a permanently-hidden spinner root. An interactive
    /// back-swipe (live in this app despite hidden back buttons — see
    /// `MigrationTransferPlanStore.backTapped`'s own KNOWN LIMITATION, and the scan-ceremony
    /// tombstones this same coordinator already carries for it) pops that element down to an
    /// empty path with nothing to land on. Leaving the flow is what the gesture meant, so the
    /// coordinator finishes it instead. The counterpart guards ordinary navigation: once the fork
    /// IS the revealed root, popping back onto it is just an ordinary pop.
    @Test func aBackSwipeThatEmptiesAnUnrevealedStackFinishesTheFlow() async {
        // Re-entry push, reusing test 1's setup: the fork never reveals, so the pushed element is
        // the whole stack.
        let store = TestStore(initialState: MigrationCoordFlow.State.initial) {
            MigrationCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.sdkSynchronizer = .mock
            var client = MigrationManagerClient.noOp
            client.reentryRoute = { .statusProgress }
            $0.migrationManager = client
        }
        store.exhaustivity = .off

        await store.send(.onAppear)
        await store.receive(\.pushHydratedPathState, timeout: .seconds(5))

        guard let pushedId = store.state.path.ids.first else {
            Issue.record("expected a pushed path element to pop")
            return
        }

        await store.send(.path(.popFrom(id: pushedId)))
        await store.receive(\.flowFinished, timeout: .seconds(5))

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)

        // Counterpart guard: the fork IS the revealed root, with something pushed over it via
        // ordinary navigation — popping back onto an already-revealed root must stay an ordinary
        // pop. Exhaustive store: no `.flowFinished` may be produced, and the only expected state
        // change is the pop itself.
        var forkOriginState = MigrationCoordFlow.State.initial
        forkOriginState.path.append(.status(MigrationStatus.State(presentation: .resume)))
        forkOriginState.isReentryResolved = true
        let poppedId = forkOriginState.path.ids[0]

        let forkOriginStore = TestStore(initialState: forkOriginState) {
            MigrationCoordFlow()
        }
        await forkOriginStore.send(.path(.popFrom(id: poppedId))) {
            $0.path.removeAll()
        }
    }
}
