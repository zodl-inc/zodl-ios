//
//  LedgerClientLiveKey.swift
//  Zashi
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

/// Finds Ledger devices and opens connections to them.
///
/// ``LedgerBluetoothScanner`` is the live conformance. A fake conforms in tests, so
/// ``LedgerSession`` can be driven without CoreBluetooth or a physical device.
protocol LedgerScanning: Sendable {
    func devices() -> AsyncThrowingStream<[LedgerBluetoothDevice], Error>
    func connect(to device: LedgerBluetoothDevice) async throws -> any LedgerAPDUTransport
}

extension LedgerBluetoothScanner: LedgerScanning {
    func connect(to device: LedgerBluetoothDevice) async throws -> any LedgerAPDUTransport {
        try await connect(to: device, timeout: 60)
    }
}

/// Owns the one scanner and at most one open transport a Ledger flow needs.
///
/// The scanner is created on first use — the first `scanDevices()` or `connect` call — and reused
/// after that, never when `LedgerSession` itself is built. `LedgerBluetoothScanner`'s init starts
/// CoreBluetooth, which raises the system's Bluetooth permission prompt, and `LedgerSession` is
/// built as soon as anything reads `@Dependency(\.ledgerClient)` — so building it must never by
/// itself trigger that prompt.
///
/// `connect` always closes a previously open transport before opening the new one. `pairAccount`
/// throws ``LedgerClientError/notConnected`` when nothing is open; otherwise it leaves the
/// transport open whether pairing succeeds or fails, so a failed pairing can be retried over the
/// same connection.
actor LedgerSession {
    private nonisolated let makeScanner: @Sendable () -> any LedgerScanning
    private nonisolated let scannerBox = LockIsolated<(any LedgerScanning)?>(nil)
    private let pair: @Sendable (any LedgerAPDUTransport, Zip32AccountIndex) async throws -> LedgerPairing
    private var transport: (any LedgerAPDUTransport)?

    init(
        makeScanner: @escaping @Sendable () -> any LedgerScanning,
        pair: @escaping @Sendable (any LedgerAPDUTransport, Zip32AccountIndex) async throws -> LedgerPairing
    ) {
        self.makeScanner = makeScanner
        self.pair = pair
    }

    /// The scanner, created on first use and reused after that.
    private nonisolated func scanner() -> any LedgerScanning {
        scannerBox.withValue { boxed in
            if let existing = boxed {
                return existing
            }
            let created = makeScanner()
            boxed = created
            return created
        }
    }

    nonisolated func scanDevices() -> AsyncThrowingStream<[LedgerBluetoothDevice], Error> {
        scanner().devices()
    }

    func connect(_ device: LedgerBluetoothDevice) async throws {
        if let previous = transport {
            transport = nil
            await previous.close()
        }
        transport = try await scanner().connect(to: device)
    }

    func pairAccount(_ zip32AccountIndex: Zip32AccountIndex) async throws -> LedgerPairing {
        guard let transport else {
            throw LedgerClientError.notConnected
        }
        return try await pair(transport, zip32AccountIndex)
    }

    func disconnect() async {
        guard let previous = transport else { return }
        transport = nil
        await previous.close()
    }
}

extension LedgerClient: DependencyKey {
    static let liveValue: Self = {
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        let networkType = zcashSDKEnvironment.network().networkType

        let session = LedgerSession(
            makeScanner: { LedgerBluetoothScanner() },
            pair: { transport, zip32AccountIndex in
                let device = LedgerDevice(transport: transport, networkType: networkType)
                let pairing = try await device.pairAccount(zip32AccountIndex: zip32AccountIndex)
                return LedgerPairing(
                    ufvk: pairing.ufvk.stringEncoded,
                    binding: pairing.binding,
                    appVersion: pairing.appVersion.description
                )
            }
        )

        return Self(
            scanDevices: { session.scanDevices() },
            connect: { device in try await session.connect(device) },
            pairAccount: { zip32AccountIndex in try await session.pairAccount(zip32AccountIndex) },
            disconnect: { await session.disconnect() }
        )
    }()
}
