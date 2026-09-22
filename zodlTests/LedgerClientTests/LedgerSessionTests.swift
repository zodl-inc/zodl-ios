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
        let session = LedgerSession(makeScanner: { scanner }, pair: { _, _ in throw PairShouldNotBeCalled() })

        await #expect(throws: LedgerClientError.notConnected) {
            try await session.pairAccount(Zip32AccountIndex(0))
        }
    }

    @Test func connectClosesThePreviousTransportBeforeOpeningAnother() async throws {
        let log = EventLog()
        let transportA = FakeLedgerAPDUTransport(name: "A", log: log)
        let transportB = FakeLedgerAPDUTransport(name: "B", log: log)
        let scanner = FakeLedgerScanning(transportsToReturn: [transportA, transportB], log: log)
        let session = LedgerSession(makeScanner: { scanner }, pair: { _, _ in throw PairShouldNotBeCalled() })
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

        let session = LedgerSession(
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
        let session = LedgerSession(makeScanner: { scanner }, pair: { _, _ in throw PairingFailure() })
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
        let session = LedgerSession(makeScanner: { scanner }, pair: { _, _ in throw PairShouldNotBeCalled() })
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
        let session = LedgerSession(makeScanner: { scanner }, pair: { _, _ in throw PairShouldNotBeCalled() })

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

        let session = LedgerSession(
            makeScanner: {
                creationLog.append("created")
                return scanner
            },
            pair: { _, _ in throw PairShouldNotBeCalled() }
        )

        #expect(creationLog.events.count == 0)

        _ = session.scanDevices()
        #expect(creationLog.events.count == 1)

        try await session.connect(device)
        #expect(creationLog.events.count == 1)
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
