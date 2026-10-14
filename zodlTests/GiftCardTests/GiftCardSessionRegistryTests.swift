import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

actor GiftCardTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

struct RegistryTestSession: GiftCardSession {
    let closed = LockIsolated(0)
    var closeStarted: GiftCardTestGate?
    var closeRelease: GiftCardTestGate?
    func status() async throws -> zodl_internal.GiftCardStatus { .empty }
    func sendAll(to address: String, recordIn mainWallet: GiftCardClaimDestination?) async throws -> GiftCardSweep {
        throw GiftCardClientError.redeemFailed
    }
    func reopen() async throws -> any GiftCardSession { throw GiftCardClientError.redeemFailed }
    func close() async {
        closed.withValue { $0 += 1 }
        await closeStarted?.open()
        await closeRelease?.wait()
    }
}

@Suite struct GiftCardSessionRegistryTests {
    @Test func reservationOrderWinsOverDelayedSessionCreation() async {
        let registry = GiftCardSessionRegistry()
        let first = await registry.reserve()
        let second = await registry.reserve()
        let newer = RegistryTestSession()
        let newerHandle = await registry.insert(newer, ownership: second)
        let older = RegistryTestSession()
        let olderHandle = await registry.insert(older, ownership: first)
        #expect(await registry.session(for: newerHandle) != nil)
        #expect(await registry.session(for: olderHandle) == nil)
        #expect(older.closed.value == 1)
        #expect(newer.closed.value == 0)
        await registry.closeAll()
    }

    @Test func cancelledReservationDoesNotCloseTheCurrentSession() async {
        let registry = GiftCardSessionRegistry()
        let current = RegistryTestSession()
        let handle = await registry.insert(current)
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let task = Task {
            await entered.open()
            await release.wait()
            return await registry.reserve()
        }
        await entered.wait()
        task.cancel()
        await release.open()
        let cancelled = await task.value
        #expect(!(await registry.isCurrent(cancelled)))
        #expect(await registry.session(for: handle) != nil)
        #expect(current.closed.value == 0)
        await registry.closeAll()
    }

    @Test func closeAllInvalidatesAnInsertionWaitingForPreviousCleanup() async {
        let registry = GiftCardSessionRegistry()
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        _ = await registry.insert(RegistryTestSession(closeStarted: entered, closeRelease: release))
        let incoming = RegistryTestSession()
        let task = Task { await registry.insert(incoming) }
        await entered.wait()
        await registry.closeAll()
        await release.open()
        let handle = await task.value
        #expect(await registry.session(for: handle) == nil)
        #expect(incoming.closed.value == 1)
    }

    @Test func cancelledInsertionClosesItsSession() async {
        let registry = GiftCardSessionRegistry()
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        let previous = RegistryTestSession(closeStarted: entered, closeRelease: release)
        _ = await registry.insert(previous)
        let incoming = RegistryTestSession()
        let task = Task { await registry.insert(incoming) }
        await entered.wait()
        task.cancel()
        await release.open()
        let handle = await task.value
        #expect(await registry.session(for: handle) == nil)
        #expect(incoming.closed.value == 1)
        #expect(previous.closed.value == 1)
        await registry.closeAll()
    }

    @Test func newerInsertionCannotBeDisplacedByOlderSuspendedInsertion() async {
        let registry = GiftCardSessionRegistry()
        let entered = GiftCardTestGate()
        let release = GiftCardTestGate()
        _ = await registry.insert(RegistryTestSession(closeStarted: entered, closeRelease: release))
        let older = RegistryTestSession()
        let newer = RegistryTestSession()
        let task = Task { await registry.insert(older) }
        await entered.wait()
        let newHandle = await registry.insert(newer)
        await release.open()
        let oldHandle = await task.value
        #expect(await registry.session(for: oldHandle) == nil)
        #expect(await registry.session(for: newHandle) != nil)
        #expect(older.closed.value == 1)
        #expect(newer.closed.value == 0)
        await registry.closeAll()
    }
}
