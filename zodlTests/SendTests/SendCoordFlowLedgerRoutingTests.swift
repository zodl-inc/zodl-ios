//
//  SendCoordFlowLedgerRoutingTests.swift
//  zodlTests
//
//  MOB-2020 Phase 3.2: coordinator-level routing for a Ledger account's send/scan/swap confirm --
//  the `confirmWithLedgerTapped` push and the `confirmWithLedger(.ledgerSigning(.signed))` ->
//  `.sending` push, across the three coordinators that gained a `confirmWithLedger` path case
//  (SendCoordFlowCoordinator, ScanCoordFlowCoordinator, SwapAndPayCoordFlowCoordinator). Mirrors
//  `KeystoneFirmwareCoordFlowTests.swift`'s pattern: CoordFlow `State` is not `Equatable`, so these
//  tests drive a plain `Store` and poll for the expected path shape, each isolated via
//  `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage() }`.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SendCoordFlowLedgerRoutingTests {
    private static func ledgerAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0x0E, count: 16)),
                name: "Ledger",
                keySource: "ledger",
                seedFingerprint: nil,
                hdAccountIndex: nil,
                ufvk: nil,
                uivk: nil
            )
        )
    }

    @Test func confirmWithLedgerTappedPushesTheLedgerScreenAndResolvesThePczt() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var sendConfirmationState = SendConfirmation.State.initial
            sendConfirmationState.proposal = .testOnlyFakeProposal(totalFee: 10_000)
            sendConfirmationState.$selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            var initialState = SendCoordFlow.State()
            initialState.path.append(.sendConfirmation(sendConfirmationState))
            let sendConfirmationId = try #require(initialState.path.ids.first)

            let pcztCreated = LockIsolated(false)
            let store = Store(initialState: initialState) {
                SendCoordFlow()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.walletStorage = .noOp
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                    pcztCreated.setValue(true)
                    return Pczt([0x01])
                }
            }

            store.send(.path(.element(id: sendConfirmationId, action: .sendConfirmation(.confirmWithLedgerTapped))))

            // `path.count == 2` alone is satisfied synchronously by the push -- `resolvePCZT`'s
            // `.run` effect (which calls `createPCZTFromProposal`) is still in flight at that
            // point, so wait on the PCZT creation too.
            await waitForCoordFlowStore {
                store.state.path.count == 2 && pcztCreated.value
            }

            #expect(store.state.path.count == 2)
            #expect(store.state.path.last?.is(\.confirmWithLedger) == true)
            #expect(pcztCreated.value)
        }
    }

    @Test func aLedgerSignedPcztPushesSending() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SendCoordFlow.State()
            initialState.path.append(.confirmWithLedger(SendConfirmation.State.initial))
            let confirmId = try #require(initialState.path.ids.first)

            let store = Store(initialState: initialState) {
                SendCoordFlow()
            }

            store.send(
                .path(
                    .element(id: confirmId, action: .confirmWithLedger(.ledgerSigning(.signed(Pczt([0xAB])))))
                )
            )

            await waitForCoordFlowStore {
                store.state.path.count == 2
            }

            #expect(store.state.path.count == 2)
            #expect(store.state.path.last?.is(\.sending) == true)
        }
    }

    @Test func theSwapFlowRoutesALedgerConfirmTheSameWay() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SwapAndPayCoordFlow.State()
            initialState.swapAndPayState.proposal = .testOnlyFakeProposal(totalFee: 10_000)
            initialState.$selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            let pcztCreated = LockIsolated(false)
            let store = Store(initialState: initialState) {
                SwapAndPayCoordFlow()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.walletStorage = .noOp
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                    pcztCreated.setValue(true)
                    return Pczt([0x01])
                }
            }

            store.send(.swapAndPay(.confirmWithLedgerTapped))

            await waitForCoordFlowStore {
                !store.state.path.filter { $0.is(\.confirmWithLedger) }.isEmpty && pcztCreated.value
            }

            #expect(store.state.path.last?.is(\.confirmWithLedger) == true)
            #expect(pcztCreated.value)
        }
    }

    @Test func theScanFlowRoutesALedgerConfirmTheSameWay() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = ScanCoordFlow.State()
            initialState.$selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            var sendConfirmationState = SendConfirmation.State.initial
            sendConfirmationState.proposal = .testOnlyFakeProposal(totalFee: 10_000)
            sendConfirmationState.$selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }
            initialState.path.append(.sendConfirmation(sendConfirmationState))
            let sendConfirmationId = try #require(initialState.path.ids.first)

            let pcztCreated = LockIsolated(false)
            let store = Store(initialState: initialState) {
                ScanCoordFlow()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.walletStorage = .noOp
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                    pcztCreated.setValue(true)
                    return Pczt([0x01])
                }
            }

            store.send(.path(.element(id: sendConfirmationId, action: .sendConfirmation(.confirmWithLedgerTapped))))

            await waitForCoordFlowStore {
                store.state.path.count == 2 && pcztCreated.value
            }

            #expect(store.state.path.count == 2)
            #expect(store.state.path.last?.is(\.confirmWithLedger) == true)
            #expect(pcztCreated.value)
        }
    }
}

@MainActor
private func waitForCoordFlowStore(
    timeoutNanoseconds: UInt64 = 60_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for CoordFlow store state", sourceLocation: sourceLocation)
}
