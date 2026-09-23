//
//  SendCoordFlowLedgerRoutingTests.swift
//  zodlTests
//
//  MOB-2020 UI round 2: coordinator-level routing for a Ledger account's send/scan/swap confirm,
//  now that `LedgerSignSheetView` presents as a sheet over `sendConfirmation`/`requestZecConfirmation`
//  (or, for swap, the scoped `ledgerConfirmationState`) instead of a separate pushed
//  `confirmWithLedger` path element -- `.ledgerSigning(.signed)` -> `.sending` and
//  `.pcztSendFailed` -> `.sendFailed`/`.preSendingFailure` across the three coordinators
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

    /// MOB-2020 audit: a validated `LedgerDeviceIdentity`, same well-formed non-secret placeholder
    /// `SendConfirmationLedgerSigningTests.swift` uses. A test that now also starts the Ledger
    /// ceremony (`.confirmWithLedgerTapped` -> `.ledgerSigning(.onAppear)`) needs this so
    /// `.ledgerSignRequest` doesn't throw and reset `isLedgerSignSheetPresented` back to `false`
    /// out from under the polling assertion below.
    private static func ledgerAccountBinding() throws -> LedgerAccountBinding {
        LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
    }

    @Test func aLedgerSignatureOnTheSendConfirmationPushesSending() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SendCoordFlow.State()
            initialState.path.append(.sendConfirmation(SendConfirmation.State.initial))
            let sendConfirmationId = try #require(initialState.path.ids.first)

            let store = Store(initialState: initialState) {
                SendCoordFlow()
            }

            store.send(
                .path(
                    .element(id: sendConfirmationId, action: .sendConfirmation(.ledgerSigning(.signed(Pczt([0xAB])))))
                )
            )

            await waitForCoordFlowStore {
                store.state.path.count == 2
            }

            #expect(store.state.path.count == 2)
            #expect(store.state.path.last?.is(\.sending) == true)
        }
    }

    @Test func aPreSigningFailureOnTheSendConfirmationPushesPreSendingFailure() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SendCoordFlow.State()
            initialState.path.append(.sendConfirmation(SendConfirmation.State.initial))
            let sendConfirmationId = try #require(initialState.path.ids.first)

            let store = Store(initialState: initialState) {
                SendCoordFlow()
            }

            // No `.sending` on the path yet -- this is a pre-signing failure (e.g. `resolvePCZT`
            // or `addProofsToPczt` failed before a signature was ever obtained).
            store.send(
                .path(
                    .element(id: sendConfirmationId, action: .sendConfirmation(.pcztSendFailed(nil)))
                )
            )

            await waitForCoordFlowStore {
                store.state.path.count == 2
            }

            #expect(store.state.path.count == 2)
            #expect(store.state.path.last?.is(\.preSendingFailure) == true)
        }
    }

    @Test func aFailureAfterSendingIsForwardedAsSendFailed() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SendCoordFlow.State()
            initialState.path.append(.sendConfirmation(SendConfirmation.State.initial))
            let sendConfirmationId = try #require(initialState.path.ids.first)
            // `.sending` is already on the path -- a `.pcztSendFailed` arriving now is a stale
            // race (the submit already started), so it must be forwarded as `.sendFailed` on the
            // `sendConfirmation` element rather than pushing a second failure screen.
            initialState.path.append(.sending(SendConfirmation.State.initial))

            let store = Store(initialState: initialState) {
                SendCoordFlow()
            } withDependencies: {
                $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
                $0.mainQueue = .immediate
            }

            store.send(
                .path(
                    .element(id: sendConfirmationId, action: .sendConfirmation(.pcztSendFailed(nil)))
                )
            )

            // `.sendFailed(_, true)` (the coordinator hardcodes `isTxIdPresentInTheDB: true`)
            // cascades through `SendConfirmation`'s own reducer to `.updateResult(.pending)`,
            // which the coordinator observes to push `.sendResultPending`.
            await waitForCoordFlowStore {
                store.state.path.count == 3
            }

            #expect(store.state.path.count == 3)
            #expect(store.state.path.last?.is(\.sendResultPending) == true)
        }
    }

    @Test func theScanFlowRoutesALedgerSignatureTheSameWay() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = ScanCoordFlow.State()
            initialState.path.append(.sendConfirmation(SendConfirmation.State.initial))
            let sendConfirmationId = try #require(initialState.path.ids.first)

            let store = Store(initialState: initialState) {
                ScanCoordFlow()
            }

            store.send(
                .path(
                    .element(id: sendConfirmationId, action: .sendConfirmation(.ledgerSigning(.signed(Pczt([0xAB])))))
                )
            )

            await waitForCoordFlowStore {
                store.state.path.count == 2
            }

            #expect(store.state.path.count == 2)
            #expect(store.state.path.last?.is(\.sending) == true)
        }
    }

    @Test func theSwapQuotePresentsTheLedgerSheetOnlyAfterItCloses() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let binding = try Self.ledgerAccountBinding()
            var initialState = SwapAndPayCoordFlow.State()
            initialState.swapAndPayState.proposal = .testOnlyFakeProposal(totalFee: 10_000)
            initialState.$selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            let pcztCreated = LockIsolated(false)
            let store = Store(initialState: initialState) {
                SwapAndPayCoordFlow()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.walletStorage = .noOp
                $0.walletStorage.exportLedgerBinding = { _ in binding }
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                    pcztCreated.setValue(true)
                    return Pczt([0x01])
                }
                // MOB-2020 audit: `.confirmWithLedgerTapped` also starts the Ledger ceremony
                // (`.ledgerSigning(.onAppear)`), which reaches `ledgerClient.scanDevices`. The
                // binding above keeps `.ledgerSignRequest` from throwing and cascading to
                // `.pcztSendFailed`, which would reset `isLedgerSignSheetPresented` back to
                // `false` out from under the polling assertion below.
                $0.ledgerClient = .noOp
                // ... and, through `.ledgerSigning(.startScanning)`, the no-devices timer.
                $0.continuousClock = SignalledClock()
            }

            store.send(.swapAndPay(.confirmWithLedgerTapped))

            // iOS cannot present a second sheet while the quote sheet is still animating out --
            // `.confirmWithLedgerTapped` only stages `ledgerConfirmationState` and waits.
            #expect(store.state.ledgerConfirmationState.isLedgerSignSheetPresented == false)
            #expect(pcztCreated.value == false)

            store.send(.swapAndPay(.quoteSheetDismissed))

            await waitForCoordFlowStore {
                store.state.ledgerConfirmationState.isLedgerSignSheetPresented && pcztCreated.value
            }

            #expect(store.state.ledgerConfirmationState.isLedgerSignSheetPresented == true)
            #expect(pcztCreated.value)
        }
    }

    @Test func theCrossPayConfirmationPresentsTheLedgerSheetImmediately() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let binding = try Self.ledgerAccountBinding()
            var initialState = SwapAndPayCoordFlow.State()
            initialState.swapAndPayState.proposal = .testOnlyFakeProposal(totalFee: 10_000)
            initialState.path.append(.crossPayConfirmation(initialState.swapAndPayState))
            let crossPayId = try #require(initialState.path.ids.first)
            initialState.$selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            let pcztCreated = LockIsolated(false)
            let store = Store(initialState: initialState) {
                SwapAndPayCoordFlow()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.walletStorage = .noOp
                $0.walletStorage.exportLedgerBinding = { _ in binding }
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.createPCZTFromProposal = { _, _ in
                    pcztCreated.setValue(true)
                    return Pczt([0x01])
                }
                // MOB-2020 audit: `.confirmWithLedgerTapped` also starts the Ledger ceremony
                // (`.ledgerSigning(.onAppear)`), which reaches `ledgerClient.scanDevices`. The
                // binding above keeps `.ledgerSignRequest` from throwing and cascading to
                // `.pcztSendFailed`, which would reset `isLedgerSignSheetPresented` back to
                // `false` out from under the polling assertion below.
                $0.ledgerClient = .noOp
                // ... and, through `.ledgerSigning(.startScanning)`, the no-devices timer.
                $0.continuousClock = SignalledClock()
            }

            // No sheet is up over `CrossPayConfirmationView` -- unlike the quote-sheet case, this
            // presents immediately with no dismissal to wait for.
            store.send(
                .path(
                    .element(id: crossPayId, action: .crossPayConfirmation(.confirmWithLedgerTapped))
                )
            )

            await waitForCoordFlowStore {
                store.state.ledgerConfirmationState.isLedgerSignSheetPresented && pcztCreated.value
            }

            #expect(store.state.ledgerConfirmationState.isLedgerSignSheetPresented == true)
            #expect(pcztCreated.value)
        }
    }

    @Test func aLedgerSignedSwapPushesSending() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: SwapAndPayCoordFlow.State()) {
                SwapAndPayCoordFlow()
            }

            store.send(.ledgerConfirmation(.ledgerSigning(.signed(Pczt([0xAB])))))

            await waitForCoordFlowStore {
                store.state.path.count == 1
            }

            #expect(store.state.path.count == 1)
            #expect(store.state.path.last?.is(\.sending) == true)
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
