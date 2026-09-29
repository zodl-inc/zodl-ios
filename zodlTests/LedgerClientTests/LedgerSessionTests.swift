//
//  LedgerSessionTests.swift
//  zodlTests
//
//  LedgerSession against a fake scanner and a fake transport: connect/close ordering, the
//  not-connected guard, that the scanner itself is only created on first use, and MOB-2020's own
//  enrollment operations (bond, openZcashApp, pairDevice), each self-contained and never touching
//  the connection connect/signPCZT hold (Dependencies/LedgerClient/LedgerClientLiveKey.swift).
//  MOB-2020 (Android aac01e65): pairAccount is gone -- enrollment pairs with pairDevice now, and
//  connect (kept for signing) never pairs, so there is no longer a connect-then-pair transport to
//  keep across two calls; a following signPCZT is what proves connect's own kept transport now.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct LedgerSessionTests {
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

    // MARK: - connect's Bluetooth-step failure (MOB-2020, Android aac01e65: LedgerBluetoothConnectFailure
    // is gone -- LedgerIssue's own `bonding` parameter, passed by the caller, now tells step 2's
    // bond apart from every other connect-step failure; see LedgerIssueTests.)

    @Test func connectsBluetoothStepFailureThrowsAsIsUnwrapped() async throws {
        struct BluetoothStepFailure: Error, Equatable {}
        let scanner = FakeLedgerScanning(transportsToReturn: [], failAt: (index: 0, error: BluetoothStepFailure()))
        let session = makeSession(makeScanner: { scanner })
        let device = try await firstDevice(from: scanner)

        await #expect(throws: BluetoothStepFailure()) {
            try await session.connect(device)
        }
    }

    @Test func connectRethrowsACancellationAtTheBluetoothStepAsIs() async throws {
        let scanner = FakeLedgerScanning(transportsToReturn: [], failAt: (index: 0, error: CancellationError()))
        let session = makeSession(makeScanner: { scanner })
        let device = try await firstDevice(from: scanner)

        do {
            try await session.connect(device)
            Issue.record("expected connect to throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
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
            for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
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
        let callCount = LockIsolated(0)
        let secondReceivedTransport = LockIsolated<(any LedgerAPDUTransport)?>(nil)
        let session = makeSession(
            makeScanner: { scanner },
            sign: { transport, _, _, _, _ in
                let call = callCount.withValue { $0 += 1; return $0 }
                if call == 1 {
                    throw ZcashError.ledgerUserRejected
                }
                secondReceivedTransport.setValue(transport)
                return Pczt([0xAB])
            }
        )
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        await #expect(throws: ZcashError.ledgerUserRejected) {
            for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
        }

        // A device rejection is not a transport-level failure, so a retry reaches the same
        // transport.
        for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
        #expect((secondReceivedTransport.value as? FakeLedgerAPDUTransport) === transport)
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
            for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
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
                for try await _ in session.signPCZT(Pczt(), accountUUID: accountUUID, binding: binding) {}
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
        let callCount = LockIsolated(0)
        let released = LockIsolated(false)
        let secondReceivedTransport = LockIsolated<(any LedgerAPDUTransport)?>(nil)
        let session = makeSession(
            makeScanner: { scanner },
            sign: { transport, _, _, _, _ in
                let call = callCount.withValue { $0 += 1; return $0 }
                if call == 1 {
                    while !released.value {
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    throw ZcashError.ledgerTransportClosed
                }
                secondReceivedTransport.setValue(transport)
                return Pczt([0xAB])
            }
        )

        let deviceA = try await firstDevice(from: scanner)
        try await session.connect(deviceA)

        let stream = session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding())

        try await eventually { callCount.value > 0 }

        let deviceB = try await firstDevice(from: scanner)
        try await session.connect(deviceB)

        released.setValue(true)

        await #expect(throws: ZcashError.ledgerTransportClosed) {
            for try await _ in stream {}
        }

        // transportA's ceremony failed after transportB was already the session's held
        // transport -- the drop-on-failure logic must only ever drop the transport a failing
        // ceremony itself used, never a newer one a later connect() opened underneath it.
        for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
        #expect((secondReceivedTransport.value as? FakeLedgerAPDUTransport) === transportB)
    }

    // MARK: - openZcashApp

    @Test func connectRunsTheOpenStepAndKeepsTheTransportItReturns() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let opened = FakeLedgerAPDUTransport(name: "opened")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected])
        let signer = FakeLedgerSigner(outcome: .success(Pczt([0xAB])))
        let session = makeSession(
            makeScanner: { scanner },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await signer.sign(transport, pczt, accountUUID, binding, progress)
            },
            openZcashApp: { transport, _ in
                #expect((transport as? FakeLedgerAPDUTransport) === connected)
                return opened
            }
        )
        let device = try await firstDevice(from: scanner)
        try await session.connect(device)

        // Reaches the transport the open step returned, not the one `connect` opened.
        for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
        #expect((signer.receivedTransport as? FakeLedgerAPDUTransport) === opened)
    }

    @Test func aFailingOpenStepClosesTheTransportAndLeavesTheSessionDisconnected() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected])
        let session = makeSession(
            makeScanner: { scanner },
            openZcashApp: { _, _ in throw OpenZcashAppFailure() }
        )
        let device = try await firstDevice(from: scanner)

        await #expect(throws: OpenZcashAppFailure()) {
            try await session.connect(device)
        }

        #expect(connected.closeCount == 1)
        await #expect(throws: LedgerClientError.notConnected) {
            for try await _ in session.signPCZT(Pczt(), accountUUID: makeAccountUUID(), binding: try makeBinding()) {}
        }
    }

    @Test func connectUsesSixtySecondsAndTheOpenStepsReconnectUsesTenOnTheSameDevice() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let reconnected = FakeLedgerAPDUTransport(name: "reconnected")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected, reconnected])
        let session = makeSession(
            makeScanner: { scanner },
            openZcashApp: { _, reconnect in
                // Calls the very reconnect closure `connect(_:)` hands the live SDK step, so this
                // exercises the real timeout and device it captures, not a fake's own bookkeeping.
                try await reconnect()
            }
        )
        let device = try await firstDevice(from: scanner)

        try await session.connect(device)

        #expect(scanner.connectCalls.map(\.timeout) == [60, 10])
        #expect(scanner.connectCalls.allSatisfy { $0.deviceID == device.id })
    }

    // MARK: - The live `pair` closure's shape

    // `LedgerSession`'s own `pair` closure type carries no `readTimeout` -- it is a
    // `LedgerClientLiveKey.swift`-only default argument to the SDK's `LedgerDevice.pairAccount`,
    // invisible to every fake above. This test reconstructs that live closure's shape (a real
    // `LedgerDevice` over a scripted transport) to make the 10 s deadline observable at all.
    @Test func theLivePairClosureShapePassesTheTenSecondPairingReadTimeout() async throws {
        struct StalledRead: Error {}
        let transport = FakeLedgerAPDUTransport(onExchange: { throw StalledRead() })
        let device = LedgerDevice(transport: transport, networkType: .testnet)

        do {
            _ = try await device.pairAccount(
                zip32AccountIndex: Zip32AccountIndex(0),
                readTimeout: LedgerDevice.defaultPairingReadTimeout,
                reconnect: nil
            )
            Issue.record("expected the scripted transport's failure to propagate")
        } catch {
            // Expected: the fake fails the very first exchange (the app-version read).
        }

        #expect(transport.exchangeTimeouts.first == LedgerDevice.defaultPairingReadTimeout)
    }

    // MARK: - bond (MOB-2020)

    @Test func bondReturnsTrueWhenTheDeviceAlreadyRunsTheZcashApp() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let session = makeSession(
            makeScanner: { scanner },
            currentApp: { _ in LedgerRunningApp(name: "Zcash", version: "3.9.3") }
        )
        let device = try await firstDevice(from: scanner)

        let isZcashAppRunning = try await session.bond(device)

        #expect(isZcashAppRunning)
        #expect(transport.closeCount == 1)
    }

    @Test func bondReturnsFalseWhenAnotherAppIsRunning() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let session = makeSession(
            makeScanner: { scanner },
            currentApp: { _ in LedgerRunningApp(name: "BOLOS", version: "1.0") }
        )
        let device = try await firstDevice(from: scanner)

        let isZcashAppRunning = try await session.bond(device)

        #expect(!isZcashAppRunning)
        #expect(transport.closeCount == 1)
    }

    @Test func bondRethrowsALockedRefusalAndStillClosesTheTransport() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let locked = ZcashError.ledgerDeviceRefused(0x5515, true)
        let session = makeSession(
            makeScanner: { scanner },
            currentApp: { _ in throw locked }
        )
        let device = try await firstDevice(from: scanner)

        await #expect(throws: locked) {
            try await session.bond(device)
        }
        #expect(transport.closeCount == 1)
    }

    @Test func bondTurnsAnyOtherAppQueryFailureIntoFalseAndStillClosesTheTransport() async throws {
        struct SomeQueryFailure: Error {}
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let session = makeSession(
            makeScanner: { scanner },
            currentApp: { _ in throw SomeQueryFailure() }
        )
        let device = try await firstDevice(from: scanner)

        let isZcashAppRunning = try await session.bond(device)

        #expect(!isZcashAppRunning)
        #expect(transport.closeCount == 1)
    }

    @Test func bondsConnectFailureThrowsAsIsNeverWrapped() async throws {
        struct BondConnectFailure: Error, Equatable {}
        let scanner = FakeLedgerScanning(transportsToReturn: [], failAt: (index: 0, error: BondConnectFailure()))
        let session = makeSession(makeScanner: { scanner })
        let device = try await firstDevice(from: scanner)

        await #expect(throws: BondConnectFailure()) {
            try await session.bond(device)
        }
    }

    @Test func bondClosesItsTransportEvenWhenCancelled() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let started = LockIsolated<Bool>(false)
        let session = makeSession(
            makeScanner: { scanner },
            currentApp: { _ in
                started.withValue { $0 = true }
                while true {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        )
        let device = try await firstDevice(from: scanner)

        let task = Task {
            try? await session.bond(device)
        }
        try await eventually { started.value }
        task.cancel()
        _ = await task.value

        try await eventually { transport.closeCount == 1 }
    }

    // MARK: - openZcashApp operation (MOB-2020)
    //
    // Distinct from the "openZcashApp" section above, which is `connect(_:)`'s own use of the
    // same underlying open step -- these exercise the new standalone `LedgerClient.openZcashApp`
    // operation, `LedgerSession.openZcashApp(_:)`.

    @Test func openZcashAppOperationClosesTheTransportItOpenedOnSuccess() async throws {
        let transport = FakeLedgerAPDUTransport()
        let scanner = FakeLedgerScanning(transportsToReturn: [transport])
        let session = makeSession(makeScanner: { scanner })
        let device = try await firstDevice(from: scanner)

        try await session.openZcashApp(device)

        #expect(transport.closeCount == 1)
    }

    @Test func openZcashAppOperationClosesBothTransportsWhenTheOpenStepReconnects() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let reopened = FakeLedgerAPDUTransport(name: "reopened")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected, reopened])
        let session = makeSession(
            makeScanner: { scanner },
            openZcashApp: { transport, _ in
                #expect((transport as? FakeLedgerAPDUTransport) === connected)
                return reopened
            }
        )
        let device = try await firstDevice(from: scanner)

        try await session.openZcashApp(device)

        #expect(connected.closeCount == 1)
        #expect(reopened.closeCount == 1)
    }

    @Test func openZcashAppOperationClosesTheFirstTransportOnFailure() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected])
        let session = makeSession(
            makeScanner: { scanner },
            openZcashApp: { _, _ in throw OpenZcashAppFailure() }
        )
        let device = try await firstDevice(from: scanner)

        await #expect(throws: OpenZcashAppFailure()) {
            try await session.openZcashApp(device)
        }
        #expect(connected.closeCount == 1)
    }

    @Test func openZcashAppOperationsConnectFailureThrowsAsIsNeverWrapped() async throws {
        struct OpenAppConnectFailure: Error, Equatable {}
        let scanner = FakeLedgerScanning(transportsToReturn: [], failAt: (index: 0, error: OpenAppConnectFailure()))
        let session = makeSession(makeScanner: { scanner })
        let device = try await firstDevice(from: scanner)

        await #expect(throws: OpenAppConnectFailure()) {
            try await session.openZcashApp(device)
        }
    }

    @Test func openZcashAppOperationUsesSixtySecondsAndItsReconnectUsesTenOnTheSameDevice() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let reconnected = FakeLedgerAPDUTransport(name: "reconnected")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected, reconnected])
        let session = makeSession(
            makeScanner: { scanner },
            openZcashApp: { _, reconnect in try await reconnect() }
        )
        let device = try await firstDevice(from: scanner)

        try await session.openZcashApp(device)

        #expect(scanner.connectCalls.map(\.timeout) == [60, 10])
        #expect(scanner.connectCalls.allSatisfy { $0.deviceID == device.id })
    }

    // MARK: - pairDevice (MOB-2020)

    @Test func pairDeviceReturnsThePairingAndClosesEveryTransportItHeld() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let opened = FakeLedgerAPDUTransport(name: "opened")
        let paired = FakeLedgerAPDUTransport(name: "paired")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected])
        let fixture = try makePairingFixture()
        let session = makeSession(
            makeScanner: { scanner },
            pair: { receivedTransport, zip32AccountIndex, _ in
                #expect(zip32AccountIndex == Zip32AccountIndex(0))
                #expect((receivedTransport as? FakeLedgerAPDUTransport) === opened)
                return (.success(fixture), paired)
            },
            openZcashApp: { transport, _ in
                #expect((transport as? FakeLedgerAPDUTransport) === connected)
                return opened
            }
        )
        let device = try await firstDevice(from: scanner)

        let pairing = try await session.pairDevice(device, Zip32AccountIndex(0))

        #expect(pairing == fixture)
        #expect(connected.closeCount == 1)
        #expect(opened.closeCount == 1)
        #expect(paired.closeCount == 1)
    }

    @Test func pairDeviceClosesEveryTransportItHeldOnAPairingFailure() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let opened = FakeLedgerAPDUTransport(name: "opened")
        let failedLive = FakeLedgerAPDUTransport(name: "failedLive")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected])
        let session = makeSession(
            makeScanner: { scanner },
            pair: { _, _, _ in (.failure(PairingFailure()), failedLive) },
            openZcashApp: { _, _ in opened }
        )
        let device = try await firstDevice(from: scanner)

        await #expect(throws: PairingFailure()) {
            try await session.pairDevice(device, Zip32AccountIndex(0))
        }

        #expect(connected.closeCount == 1)
        #expect(opened.closeCount == 1)
        #expect(failedLive.closeCount == 1)
    }

    @Test func pairDeviceClosesTheFirstTransportWhenTheOpenStepFails() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected])
        let session = makeSession(
            makeScanner: { scanner },
            openZcashApp: { _, _ in throw OpenZcashAppFailure() }
        )
        let device = try await firstDevice(from: scanner)

        await #expect(throws: OpenZcashAppFailure()) {
            try await session.pairDevice(device, Zip32AccountIndex(0))
        }
        #expect(connected.closeCount == 1)
    }

    @Test func pairDevicesConnectFailureThrowsAsIsNeverWrapped() async throws {
        struct PairDeviceConnectFailure: Error, Equatable {}
        let scanner = FakeLedgerScanning(transportsToReturn: [], failAt: (index: 0, error: PairDeviceConnectFailure()))
        let session = makeSession(makeScanner: { scanner })
        let device = try await firstDevice(from: scanner)

        await #expect(throws: PairDeviceConnectFailure()) {
            try await session.pairDevice(device, Zip32AccountIndex(0))
        }
    }

    @Test func pairDeviceReconnectsToTheSameDeviceWithTheRightTimeouts() async throws {
        let connected = FakeLedgerAPDUTransport(name: "connected")
        let appReconnected = FakeLedgerAPDUTransport(name: "appReconnected")
        let pairReconnected = FakeLedgerAPDUTransport(name: "pairReconnected")
        let scanner = FakeLedgerScanning(transportsToReturn: [connected, appReconnected, pairReconnected])
        let fixture = try makePairingFixture()
        let session = makeSession(
            makeScanner: { scanner },
            pair: { receivedTransport, _, reconnect in
                guard let fresh = try? await reconnect() else {
                    return (.failure(PairingFailure()), receivedTransport)
                }
                return (.success(fixture), fresh)
            },
            openZcashApp: { _, reconnect in try await reconnect() }
        )
        let device = try await firstDevice(from: scanner)

        let pairing = try await session.pairDevice(device, Zip32AccountIndex(0))

        #expect(pairing == fixture)
        #expect(scanner.connectCalls.map(\.timeout) == [60, 10, 60])
        #expect(scanner.connectCalls.allSatisfy { $0.deviceID == device.id })
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
private struct OpenZcashAppFailure: Error, Equatable {}
private struct CurrentAppShouldNotBeCalled: Error {}

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
/// `pair` and `sign` default to failing, so only the tests that care about pairing or signing
/// need to pass their own. `openZcashApp` defaults to a pass-through that returns the transport
/// it's given, so every test that doesn't care about the open step keeps its original meaning.
private func makeSession(
    makeScanner: @escaping @Sendable () -> any LedgerScanning,
    pair: @escaping @Sendable (
        any LedgerAPDUTransport, Zip32AccountIndex, @escaping @Sendable () async throws -> any LedgerAPDUTransport
    ) async -> (Result<LedgerPairing, Error>, any LedgerAPDUTransport) = { transport, _, _ in
        (.failure(PairShouldNotBeCalled()), transport)
    },
    sign: @escaping @Sendable (
        any LedgerAPDUTransport, Pczt, AccountUUID, LedgerAccountBinding, @escaping @Sendable (LedgerSigningProgress) -> Void
    ) async throws -> Pczt = { _, _, _, _, _ in
        throw SignShouldNotBeCalled()
    },
    openZcashApp: @escaping @Sendable (
        any LedgerAPDUTransport, @escaping @Sendable () async throws -> any LedgerAPDUTransport
    ) async throws -> any LedgerAPDUTransport = { transport, _ in transport },
    // `bond`'s own seam onto `LedgerZcashApp.currentApp` -- defaults to failing the test if
    // reached, unless a test overrides it, same as `pair` and `sign` above.
    currentApp: @escaping @Sendable (any LedgerAPDUTransport) async throws -> LedgerRunningApp = { _ in
        throw CurrentAppShouldNotBeCalled()
    }
) -> LedgerSession {
    LedgerSession(makeScanner: makeScanner, pair: pair, sign: sign, openZcashApp: openZcashApp, currentApp: currentApp)
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

/// A transport that records how many times it was closed and, by default, fails if ever asked to
/// exchange — none of the `LedgerSession`-level tests above should reach a real APDU exchange.
/// `onExchange` is an opt-in escape hatch for the one test that scripts a real `LedgerDevice`
/// directly (below): every call's `timeout` is still recorded first, so that test can observe it
/// even though the exchange itself then throws.
private final class FakeLedgerAPDUTransport: LedgerAPDUTransport, @unchecked Sendable {
    private let name: String
    private let log: EventLog?
    private let onExchange: (@Sendable () throws -> Data)?
    private let _closeCount = LockIsolated<Int>(0)
    private let _exchangeTimeouts = LockIsolated<[TimeInterval?]>([])

    init(name: String = "transport", log: EventLog? = nil, onExchange: (@Sendable () throws -> Data)? = nil) {
        self.name = name
        self.log = log
        self.onExchange = onExchange
    }

    var closeCount: Int {
        _closeCount.value
    }

    /// Every `exchange` call's `timeout`, in call order.
    var exchangeTimeouts: [TimeInterval?] {
        _exchangeTimeouts.value
    }

    func exchange(_ apdu: Data, timeout: TimeInterval?) async throws -> Data {
        _exchangeTimeouts.withValue { $0.append(timeout) }
        guard let onExchange else {
            Issue.record("FakeLedgerAPDUTransport.exchange must never be called")
            throw ExchangeMustNotBeCalled()
        }
        return try onExchange()
    }

    func close() async {
        _closeCount.withValue { $0 += 1 }
        log?.append("close-\(name)")
    }
}

/// Vends one device through `devices()` and hands out `transportsToReturn` in call order from
/// `connect(to:timeout:)`, regardless of which device was passed. `failAt` makes one specific
/// `connect(to:timeout:)` call (by its zero-based index) throw instead of dispensing a transport --
/// mirroring Android's `ScriptedTransport(failAt = ...)` -- for the tests below that need
/// `LedgerSession.connect`'s own Bluetooth step to fail.
private final class FakeLedgerScanning: LedgerScanning, @unchecked Sendable {
    private let transportsToReturn: [FakeLedgerAPDUTransport]
    private let log: EventLog?
    private let failAt: (index: Int, error: Error)?
    private let connectCallCount = LockIsolated<Int>(0)
    private let _connectCalls = LockIsolated<[(deviceID: UUID, timeout: TimeInterval)]>([])

    init(transportsToReturn: [FakeLedgerAPDUTransport], log: EventLog? = nil, failAt: (index: Int, error: Error)? = nil) {
        self.transportsToReturn = transportsToReturn
        self.log = log
        self.failAt = failAt
    }

    /// Every `connect(to:timeout:)` call, in order, as the device it targeted and the timeout it
    /// received -- for asserting `connect`'s own 60 s connection against the open step's 10 s
    /// reconnect, both against the same device.
    var connectCalls: [(deviceID: UUID, timeout: TimeInterval)] {
        _connectCalls.value
    }

    func devices() -> AsyncThrowingStream<[LedgerBluetoothDevice], Error> {
        AsyncThrowingStream { continuation in
            let device = LedgerBluetoothDevice(id: UUID(), name: "Fake Nano X", model: .nanoX, rssi: -40)
            continuation.yield([device])
            continuation.finish()
        }
    }

    func connect(to device: LedgerBluetoothDevice, timeout: TimeInterval) async throws -> any LedgerAPDUTransport {
        let index = connectCallCount.withValue { count -> Int in
            let current = count
            count += 1
            return current
        }
        _connectCalls.withValue { $0.append((device.id, timeout)) }

        if let failAt, failAt.index == index {
            log?.append("connect-\(index)-failed")
            throw failAt.error
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
