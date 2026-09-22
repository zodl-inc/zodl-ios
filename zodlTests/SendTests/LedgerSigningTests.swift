//
//  LedgerSigningTests.swift
//  zodlTests
//
//  MOB-2020 Phase 3.2: covers `LedgerSigning` in isolation -- scanning, auto-connect vs. device
//  picker, a sign request arriving before the device is connected, every progress stage on a
//  successful ceremony, and the restartable/connection-lost split on failure
//  (Features/SendConfirmation/LedgerSigningStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct LedgerSigningTests {
    @MainActor @Test func onAppearStartsScanning() async throws {
        let request = try Self.signRequest()
        var state = LedgerSigning.State()
        state.phase = .failed
        state.errorMessage = "stale error"
        state.isRestartable = true
        state.isConnectionLost = true
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
        }

        await store.send(.onAppear) {
            $0 = LedgerSigning.State()
            $0.request = request
        }
        await store.receive(\.startScanning)
        await store.finish()
    }

    @MainActor @Test func aSingleDeviceIsConnectedAutomatically() async {
        let device = Self.device(name: "Nano X")
        let store = TestStore(initialState: LedgerSigning.State()) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.connect = { _ in }
        }

        await store.send(.devicesUpdated([device])) {
            $0.devices = [device]
            $0.selectedDevice = device
        }
        await store.receive(\.connect) {
            $0.phase = .connecting
        }
        await store.receive(\.deviceConnected) {
            $0.phase = .connected
        }
        // No `request` yet -- `startSigningIfReady`'s guard fails and nothing further happens.
        await store.receive(\.startSigningIfReady)
        await store.finish()
    }

    @MainActor @Test func severalDevicesWaitForATap() async {
        let deviceA = Self.device(name: "Nano X A")
        let deviceB = Self.device(name: "Nano X B")
        // No `connect`/`signPCZT` override beyond `.noOp`: reaching either would trip "has no
        // test implementation" and fail the test -- proving nothing auto-connects here.
        let store = TestStore(initialState: LedgerSigning.State()) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
        }

        await store.send(.devicesUpdated([deviceA, deviceB])) {
            $0.devices = [deviceA, deviceB]
            $0.phase = .selectingDevice
        }
        await store.finish()
    }

    @MainActor @Test func aSignRequestBeforeTheConnectionWaitsUntilConnected() async throws {
        let request = try Self.signRequest()
        let signPCZTCallCount = LockIsolated(0)
        let store = TestStore(initialState: LedgerSigning.State()) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                signPCZTCallCount.withValue { $0 += 1 }
                return AsyncThrowingStream { $0.finish() }
            }
        }

        await store.send(.signRequested(request)) {
            $0.request = request
        }
        // Still `.scanning` (the default) -- `startSigningIfReady`'s guard must not let signing
        // start before a device is connected.
        await store.receive(\.startSigningIfReady)
        #expect(signPCZTCallCount.value == 0)

        await store.send(.deviceConnected) {
            $0.phase = .connected
        }
        await store.receive(\.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.finish()

        #expect(signPCZTCallCount.value == 1)
    }

    @MainActor @Test func aConnectedDeviceWithARequestSignsAndReportsEveryStage() async throws {
        let request = try Self.signRequest()
        let signedPczt = Pczt([0xAB])
        var state = LedgerSigning.State()
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.progress(.identifyingDevice))
                    continuation.yield(.progress(.streaming(sent: 0, total: 2)))
                    continuation.yield(.progress(.awaitingReviewOnDevice))
                    continuation.yield(.progress(.signing))
                    continuation.yield(.progress(.complete))
                    continuation.yield(.signed(signedPczt))
                    continuation.finish()
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        // `startSigningIfReady` already optimistically set `.identifyingDevice` above, so this
        // first progress event (the same stage) makes no further observable change.
        await store.receive(\.signingProgressed)
        await store.receive(\.signingProgressed) {
            $0.phase = .signing(.streaming(sent: 0, total: 2))
        }
        await store.receive(\.signingProgressed) {
            $0.phase = .signing(.awaitingReviewOnDevice)
        }
        await store.receive(\.signingProgressed) {
            $0.phase = .signing(.signing)
        }
        await store.receive(\.signingProgressed) {
            $0.phase = .signing(.complete)
        }
        await store.receive(.signed(signedPczt)) {
            $0.phase = .signed
        }
        await store.finish()
    }

    @MainActor @Test func aDeviceRejectionIsRestartableAndKeepsTheRequest() async throws {
        let request = try Self.signRequest()
        let signPCZTCallCount = LockIsolated(0)
        var state = LedgerSigning.State()
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                signPCZTCallCount.withValue { $0 += 1 }
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerUserRejected)
                }
            }
        }

        // Routed through `LedgerErrorText.signingMessage(for:)`, not `message(for:)` -- the two
        // give `.ledgerUserRejected` different copy (signing-declined vs. pairing-declined).
        let expectedMessage = LedgerErrorText.signingMessage(for: ZcashError.ledgerUserRejected)

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(
            .signingFailed(message: expectedMessage, restartable: true, connectionLost: false)
        ) {
            $0.phase = .failed
            $0.errorMessage = expectedMessage
            $0.isRestartable = true
            $0.isConnectionLost = false
        }
        #expect(signPCZTCallCount.value == 1)
        // The request is still there -- Try Again can resume signing without asking again.
        #expect(store.state.request == request)

        await store.send(.tryAgainTapped) {
            $0.phase = .connected
        }
        await store.receive(\.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(
            .signingFailed(message: expectedMessage, restartable: true, connectionLost: false)
        ) {
            $0.phase = .failed
        }
        await store.finish()

        #expect(signPCZTCallCount.value == 2)
    }

    @MainActor @Test func aLostConnectionRescansOnTryAgain() async throws {
        let device = Self.device(name: "Nano X")
        let request = try Self.signRequest()
        var state = LedgerSigning.State()
        state.devices = [device]
        state.selectedDevice = device
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerTransportClosed)
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(
            .signingFailed(message: String(localizable: .ledgerErrorConnectionLost), restartable: true, connectionLost: true)
        ) {
            $0.phase = .failed
            $0.errorMessage = String(localizable: .ledgerErrorConnectionLost)
            $0.isRestartable = true
            $0.isConnectionLost = true
        }

        await store.send(.tryAgainTapped) {
            $0.devices = []
            $0.selectedDevice = nil
            $0.phase = .scanning
        }
        await store.receive(\.startScanning) {
            $0.errorMessage = nil
        }
        await store.finish()
    }

    @MainActor @Test func aNotSignableTransactionIsNotRestartable() async throws {
        let request = try Self.signRequest()
        var state = LedgerSigning.State()
        state.phase = .connected
        state.request = request

        let store = TestStore(initialState: state) {
            LedgerSigning()
        } withDependencies: {
            $0.ledgerClient = .noOp
            $0.ledgerClient.signPCZT = { _, _, _ in
                AsyncThrowingStream { continuation in
                    continuation.finish(throwing: ZcashError.ledgerTransactionNotSignable("some SDK reason"))
                }
            }
        }

        await store.send(.startSigningIfReady) {
            $0.phase = .signing(.identifyingDevice)
        }
        await store.receive(
            .signingFailed(message: String(localizable: .ledgerErrorNotSignable), restartable: false, connectionLost: false)
        ) {
            $0.phase = .failed
            $0.errorMessage = String(localizable: .ledgerErrorNotSignable)
            $0.isRestartable = false
            $0.isConnectionLost = false
        }
        await store.finish()
    }

    // MARK: - Fixtures

    private static func device(name: String) -> LedgerBluetoothDevice {
        LedgerBluetoothDevice(id: UUID(), name: name, model: .nanoX, rssi: -40)
    }

    /// A validated `LedgerDeviceIdentity`: `tpk0-` plus 64 lowercase hex digits, the same
    /// well-formed, non-secret placeholder `WalletStorageLedgerBindingTests.swift` and
    /// `LedgerSessionTests.swift` use.
    private static func ledgerAccountBinding() throws -> LedgerAccountBinding {
        LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
    }

    private static func signRequest() throws -> LedgerSigning.State.SignRequest {
        LedgerSigning.State.SignRequest(
            pczt: Pczt([0x01]),
            accountUUID: AccountUUID(id: [UInt8](repeating: 0xAB, count: 16)),
            binding: try ledgerAccountBinding()
        )
    }
}
