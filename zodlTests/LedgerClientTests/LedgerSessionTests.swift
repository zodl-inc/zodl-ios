//
//  LedgerSessionTests.swift
//  zodlTests
//
//  LedgerSession against a fake scanner and a fake transport: connect/close ordering, the
//  not-connected guard, that a failed pairing leaves the transport open, and that the scanner
//  itself is only created on first use (Dependencies/LedgerClient/LedgerClientLiveKey.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct LedgerSessionTests {
    @Test func pairAccountWithoutConnectThrowsNotConnected() async throws {
        let scanner = FakeLedgerScanning(transportsToReturn: [])
        let session = makeSession(makeScanner: { scanner })

        await #expect(throws: LedgerClientError.notConnected) {
            try await session.pairAccount(Zip32AccountIndex(0))
        }
    }

    @Test func connectClosesThePreviousTransportBeforeOpeningAnother() async throws {
        let log = EventLog()
        let transportA = FakeLedgerAPDUTransport(name: "A", log: log)
        let transportB = FakeLedgerAPDUTransport(name: "B", log: log)
        let scanner = FakeLedgerScanning(transportsToReturn: [transportA, transportB], log: log)
        let session = makeSession(makeScanner: { scanner })
        let device = try await firstDevice(from: scanner)

        try await session.connect(device)
        try await session.connect(device)

        #expect(log.events == ["connect-0", "close-A", "connect-1"])
        #expect(transportA.closeCount == 1)
        #expect(transportB.closeCount == 0)
    }

    @Test func pairAccountUsesTheConnectedTransportAndKeepsItOpenOnSuccess() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let fixture = try makePairingFixture()

        let session = makeSession(
            makeScanner: { scanner },
            pair: { receivedTransport, zip32AccountIndex in
                #expect(zip32AccountIndex == Zip32AccountIndex(0))
                #expect((receivedTransport as? FakeLedgerAPDUTransport) === transport)
                return fixture
            }
        )
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        let pairing = try await session.pairAccount(Zip32AccountIndex(0))

        #expect(pairing == fixture)
        #expect(transport.closeCount == 0)
    }

    @Test func pairAccountKeepsTheTransportOpenWhenPairingFails() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let session = makeSession(makeScanner: { scanner }, pair: { _, _ in throw PairingFailure() })
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        await #expect(throws: PairingFailure()) {
            try await session.pairAccount(Zip32AccountIndex(0))
        }
        #expect(transport.closeCount == 0)
    }

    @Test func disconnectClosesTheTransportAndForgetsIt() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let session = makeSession(makeScanner: { scanner })
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        await session.disconnect()

        #expect(transport.closeCount == 1)
        await #expect(throws: LedgerClientError.notConnected) {
            try await session.pairAccount(Zip32AccountIndex(0))
        }
    }

    @Test func scanDevicesForwardsTheScannerStream() async throws {
        let scanner = FakeLedgerScanning(transportsToReturn: [])
        let session = makeSession(makeScanner: { scanner })

        var received: [[LedgerBluetoothDevice]] = []
        for try await batch in session.scanDevices() {
            received.append(batch)
        }

        #expect(received.count == 1)
        #expect(received.first?.count == 1)
    }

    @Test func scannerIsCreatedOnFirstUseAndOnlyOnce() async throws {
        let creationLog = EventLog()
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let device = try await firstDevice(from: scanner)

        let session = makeSession(
            makeScanner: {
                creationLog.append("created")
                return scanner
            }
        )

        #expect(creationLog.events.count == 0)

        _ = session.scanDevices()
        #expect(creationLog.events.count == 1)

        try await session.connect(device)
        #expect(creationLog.events.count == 1)
    }

    @Test func signPCZTWithoutAConnectionFailsWithNotConnected() async throws {
        let scanner = FakeLedgerScanning(transportsToReturn: [])
        let signer = FakeLedgerSigner()
        let session = makeSession(
            makeScanner: { scanner },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await signer.sign(transport, pczt, accountUUID, binding, progress)
            }
        )

        await #expect(throws: LedgerClientError.notConnected) {
            for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
        }

        #expect(!signer.wasCalled)
    }

    @Test func signPCZTForwardsTheArgumentsAndYieldsEveryStageThenTheSignedPczt() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let signedPczt = Pczt([0xAB, 0xCD])
        let signer = FakeLedgerSigner(
            stages: [.identifyingDevice, .streaming(sent: 0, total: 2), .awaitingReviewOnDevice, .signing, .complete],
            outcome: .success(signedPczt)
        )
        let session = makeSession(
            makeScanner: { scanner },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await signer.sign(transport, pczt, accountUUID, binding, progress)
            }
        )
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        let accountUUID = makeAccountUUID()
        let binding = try makeBinding()
        let inputPczt = Pczt([0x01])

        var events: [LedgerSigningEvent] = []
        for try await event in session.signPCZT(inputPczt, accountUUID: accountUUID, binding: binding) {
            events.append(event)
        }

        #expect(events == [
            .progress(.identifyingDevice),
            .progress(.streaming(sent: 0, total: 2)),
            .progress(.awaitingReviewOnDevice),
            .progress(.signing),
            .progress(.complete),
            .signed(signedPczt)
        ])
        #expect((signer.receivedTransport as? FakeLedgerAPDUTransport) === transport)
        #expect(signer.receivedPczt == inputPczt)
        #expect(signer.receivedAccountUUID == accountUUID)
        #expect(signer.receivedBinding == binding)
    }

    @Test func aDeviceRejectionIsTheStreamsFailureAndKeepsTheTransport() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let signer = FakeLedgerSigner(outcome: .failure(ZcashError.ledgerUserRejected))
        let fixture = try makePairingFixture()
        let session = makeSession(
            makeScanner: { scanner },
            pair: { _, _ in fixture },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await signer.sign(transport, pczt, accountUUID, binding, progress)
            }
        )
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        await #expect(throws: ZcashError.ledgerUserRejected) {
            for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
        }

        let pairing = try await session.pairAccount(Zip32AccountIndex(0))
        #expect(pairing == fixture)
    }

    @Test func aClosedTransportIsDroppedAfterTheFailure() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let signer = FakeLedgerSigner(outcome: .failure(ZcashError.ledgerTransportClosed))
        let session = makeSession(
            makeScanner: { scanner },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await signer.sign(transport, pczt, accountUUID, binding, progress)
            }
        )
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        await #expect(throws: ZcashError.ledgerTransportClosed) {
            for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
        }

        await #expect(throws: LedgerClientError.notConnected) {
            try await session.pairAccount(Zip32AccountIndex(0))
        }
    }

    @Test func cancellingTheStreamCancelsTheSignerAndDropsTheTransport() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let signer = FakeLedgerSigner(outcome: .hangUntilCancelled)
        let session = makeSession(
            makeScanner: { scanner },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await signer.sign(transport, pczt, accountUUID, binding, progress)
            }
        )
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        let accountUUID = makeAccountUUID()
        let binding = try makeBinding()
        let consumer = Task {
            for try await _ in session.signPCZT(Pczt(), accountUUID: accountUUID, binding: binding) {}
        }

        try await eventually { signer.wasCalled }
        consumer.cancel()
        _ = try? await consumer.value

        try await eventually { signer.observedCancellation }
        try await eventually {
            do {
                _ = try await session.pairAccount(Zip32AccountIndex(0))
                return false
            } catch is LedgerClientError {
                return true
            } catch {
                return false
            }
        }
    }

    @Test func aTransportOpenedDuringAFailingCeremonyIsKept() async throws {
        let transportA = FakeLedgerAPDUTransport(name: "A")
        let transportB = FakeLedgerAPDUTransport(name: "B")
        let scanner = FakeLedgerScanning(transportsToReturn: [transportA, transportB])
        let fixture = try makePairingFixture()
        let signer = FakeLedgerSigner(outcome: .failWhenReleased(ZcashError.ledgerTransportClosed))
        let session = makeSession(
            makeScanner: { scanner },
            pair: { receivedTransport, _ in
                #expect((receivedTransport as? FakeLedgerAPDUTransport) === transportB)
                return fixture
            },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await signer.sign(transport, pczt, accountUUID, binding, progress)
            }
        )

        let deviceA = try await firstDevice(from: scanner)
        try await session.connect(deviceA)

        let stream = session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding())

        try await eventually { signer.wasCalled }

        let deviceB = try await firstDevice(from: scanner)
        try await session.connect(deviceB)

        signer.release()

        await #expect(throws: ZcashError.ledgerTransportClosed) {
            for try await _ in stream {}
        }

        let pairing = try await session.pairAccount(Zip32AccountIndex(0))
        #expect(pairing == fixture)
    }
}

// MARK: - Fixture

/// `LedgerAccountBinding`'s device identity is `tpk0-` plus 64 lowercase hex digits, validated
/// through the linked FFI.
private func makePairingFixture() throws -> LedgerPairing {
    LedgerPairing(
        ufvk: "utest1fixture",
        binding: LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
            zip32AccountIndex: Zip32AccountIndex(0)
        ),
        appVersion: "3.9.3"
    )
}

private struct PairingFailure: Error, Equatable {}
private struct PairShouldNotBeCalled: Error {}
private struct SignShouldNotBeCalled: Error {}

/// A fixed, valid `AccountUUID` for tests that never inspect its bytes.
private func makeAccountUUID() -> AccountUUID {
    AccountUUID(id: [UInt8](repeating: 0xAB, count: 16))
}

/// Builds a `LedgerAccountBinding` the way `makePairingFixture()` does: the device identity is
/// `tpk0-` plus 64 lowercase hex digits, validated through the linked FFI.
private func makeBinding(zip32AccountIndex: Zip32AccountIndex = Zip32AccountIndex(0)) throws -> LedgerAccountBinding {
    LedgerAccountBinding(
        deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
        zip32AccountIndex: zip32AccountIndex
    )
}

/// Builds a session with fakes that fail the test if reached, unless a test overrides them --
/// `pair` and `sign` default to throwing, so only the tests that care about pairing or signing
/// need to pass their own.
private func makeSession(
    makeScanner: @escaping @Sendable () -> any LedgerScanning,
    pair: @escaping @Sendable (any LedgerAPDUTransport, Zip32AccountIndex) async throws -> LedgerPairing = { _, _ in
        throw PairShouldNotBeCalled()
    },
    sign: @escaping @Sendable (
        any LedgerAPDUTransport, Pczt, AccountUUID, LedgerAccountBinding, @escaping @Sendable (LedgerSigningProgress) -> Void
    ) async throws -> Pczt = { _, _, _, _, _ in
        throw SignShouldNotBeCalled()
    }
) -> LedgerSession {
    LedgerSession(makeScanner: makeScanner, pair: pair, sign: sign)
}

// MARK: - Fakes

/// `LedgerBluetoothDevice` has no public initializer, so the only way to obtain one here is
/// through a fake scanner's own `devices()` stream (constructible because this file has
/// `@testable` access to the SDK).
private func firstDevice(from scanner: FakeLedgerScanning) async throws -> LedgerBluetoothDevice {
    struct NoDeviceFromFakeScanner: Error {}

    var iterator = scanner.devices().makeAsyncIterator()
    guard let batch = try await iterator.next(), let device = batch.first else {
        throw NoDeviceFromFakeScanner()
    }
    return device
}

/// Retries `attempt` every 5ms, for up to 10 seconds (2000 tries), until it returns `true` — for
/// observing cleanup that runs asynchronously (a cancellation, the actor's own bookkeeping), which
/// has no other completion signal the test can await. 10 seconds, not less: this repo has lost
/// sub-10-second wall-clock guards to a cold CI test-runner process before. Records an issue if
/// `attempt` never returns `true`.
private func eventually(_ attempt: () async throws -> Bool) async throws {
    for _ in 0..<2000 {
        if try await attempt() {
            return
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("Condition never became true within the time budget")
}

/// Records the order fake Ledger calls happen in, for the connect/close ordering and
/// scanner-creation assertions. `LockIsolated` (rather than a raw lock) because its accessors
/// stay usable from the `async` fake methods below.
private final class EventLog: @unchecked Sendable {
    private let storage = LockIsolated<[String]>([])

    func append(_ event: String) {
        storage.withValue { $0.append(event) }
    }

    var events: [String] {
        storage.value
    }
}

private struct ExchangeMustNotBeCalled: Error {}

/// A transport that records how many times it was closed and fails if ever asked to exchange —
/// none of these tests should reach a real APDU exchange.
private final class FakeLedgerAPDUTransport: LedgerAPDUTransport, @unchecked Sendable {
    private let name: String
    private let log: EventLog?
    private let _closeCount = LockIsolated<Int>(0)

    init(name: String = "transport", log: EventLog? = nil) {
        self.name = name
        self.log = log
    }

    var closeCount: Int {
        _closeCount.value
    }

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        Issue.record("FakeLedgerAPDUTransport.exchange must never be called")
        throw ExchangeMustNotBeCalled()
    }

    func close() async {
        _closeCount.withValue { $0 += 1 }
        log?.append("close-\(name)")
    }
}

/// Vends one device through `devices()` and hands out `transportsToReturn` in call order from
/// `connect(to:)`, regardless of which device was passed.
private final class FakeLedgerScanning: LedgerScanning, @unchecked Sendable {
    private let transportsToReturn: [FakeLedgerAPDUTransport]
    private let log: EventLog?
    private let connectCallCount = LockIsolated<Int>(0)

    init(transportsToReturn: [FakeLedgerAPDUTransport], log: EventLog? = nil) {
        self.transportsToReturn = transportsToReturn
        self.log = log
    }

    func devices() -> AsyncThrowingStream<[LedgerBluetoothDevice], Error> {
        AsyncThrowingStream { continuation in
            let device = LedgerBluetoothDevice(id: UUID(), name: "Fake Nano X", model: .nanoX, rssi: -40)
            continuation.yield([device])
            continuation.finish()
        }
    }

    func connect(to device: LedgerBluetoothDevice) async throws -> any LedgerAPDUTransport {
        let index = connectCallCount.withValue { count -> Int in
            let current = count
            count += 1
            return current
        }

        guard transportsToReturn.indices.contains(index) else {
            fatalError("FakeLedgerScanning: no fake transport queued for connect() call #\(index)")
        }

        log?.append("connect-\(index)")
        return transportsToReturn[index]
    }
}

/// A `sign` fake for `LedgerSession`: records the arguments each call receives, reports a fixed
/// sequence of stages through the progress callback, and then returns or throws whatever the test
/// configured — or hangs until the caller cancels it or releases it, for the cancellation and
/// kept-transport tests.
private final class FakeLedgerSigner: @unchecked Sendable {
    enum Outcome {
        case success(Pczt)
        case failure(Error)
        case hangUntilCancelled
        /// Polls every 5ms until `release()` is called, then throws `error` — for a test that needs
        /// to perform other actions (like opening a different transport) while a ceremony is still
        /// in flight, before letting it fail.
        case failWhenReleased(Error)
    }

    private let stages: [LedgerSigningProgress]
    private let outcome: Outcome
    private let _callCount = LockIsolated<Int>(0)
    private let _receivedTransport = LockIsolated<(any LedgerAPDUTransport)?>(nil)
    private let _receivedPczt = LockIsolated<Pczt?>(nil)
    private let _receivedAccountUUID = LockIsolated<AccountUUID?>(nil)
    private let _receivedBinding = LockIsolated<LedgerAccountBinding?>(nil)
    private let _observedCancellation = LockIsolated<Bool>(false)
    private let _released = LockIsolated<Bool>(false)

    init(stages: [LedgerSigningProgress] = [], outcome: Outcome = .failure(SignShouldNotBeCalled())) {
        self.stages = stages
        self.outcome = outcome
    }

    var wasCalled: Bool { _callCount.value > 0 }
    var receivedTransport: (any LedgerAPDUTransport)? { _receivedTransport.value }
    var receivedPczt: Pczt? { _receivedPczt.value }
    var receivedAccountUUID: AccountUUID? { _receivedAccountUUID.value }
    var receivedBinding: LedgerAccountBinding? { _receivedBinding.value }
    var observedCancellation: Bool { _observedCancellation.value }

    /// Lets a `.failWhenReleased` call that is currently polling proceed to throw its error.
    func release() {
        _released.withValue { $0 = true }
    }

    func sign(
        _ transport: any LedgerAPDUTransport,
        _ pczt: Pczt,
        _ accountUUID: AccountUUID,
        _ binding: LedgerAccountBinding,
        _ progress: @escaping @Sendable (LedgerSigningProgress) -> Void
    ) async throws -> Pczt {
        _callCount.withValue { $0 += 1 }
        _receivedTransport.withValue { $0 = transport }
        _receivedPczt.withValue { $0 = pczt }
        _receivedAccountUUID.withValue { $0 = accountUUID }
        _receivedBinding.withValue { $0 = binding }

        for stage in stages {
            progress(stage)
        }

        switch outcome {
        case .success(let signed):
            return signed
        case .failure(let error):
            throw error
        case .hangUntilCancelled:
            do {
                while true {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            } catch {
                _observedCancellation.withValue { $0 = true }
                throw error
            }
        case .failWhenReleased(let error):
            while !_released.value {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            throw error
        }
    }
}
