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
///
/// `signPCZT` throws the same error when nothing is open. A signing failure leaves the transport
/// open too, UNLESS the SDK has already closed it: `ledgerBluetoothDisconnected`, `ledgerTimeout`,
/// `ledgerTransportClosed`, `ledgerTransportFailed` and cancellation all mean the transport is
/// already gone (see docs/LEDGER.md's "transport closed" rule), so the session drops its reference
/// rather than keep a dead one around for a retry that would only fail again.
actor LedgerSession {
    private nonisolated let makeScanner: @Sendable () -> any LedgerScanning
    private nonisolated let scannerBox = LockIsolated<(any LedgerScanning)?>(nil)
    private let pair: @Sendable (any LedgerAPDUTransport, Zip32AccountIndex) async throws -> LedgerPairing
    private nonisolated let sign: @Sendable (
        any LedgerAPDUTransport, Pczt, AccountUUID, LedgerAccountBinding, @escaping @Sendable (LedgerSigningProgress) -> Void
    ) async throws -> Pczt
    private var transport: (any LedgerAPDUTransport)?

    init(
        makeScanner: @escaping @Sendable () -> any LedgerScanning,
        pair: @escaping @Sendable (any LedgerAPDUTransport, Zip32AccountIndex) async throws -> LedgerPairing,
        sign: @escaping @Sendable (
            any LedgerAPDUTransport, Pczt, AccountUUID, LedgerAccountBinding, @escaping @Sendable (LedgerSigningProgress) -> Void
        ) async throws -> Pczt
    ) {
        self.makeScanner = makeScanner
        self.pair = pair
        self.sign = sign
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
        LoggerProxy.event("Ledger: connecting to a \(device.model.productName)")
        do {
            transport = try await scanner().connect(to: device)
            LoggerProxy.event("Ledger: connected")
        } catch {
            LoggerProxy.warn("Ledger: connect failed (\(Self.errorTag(error)))")
            throw error
        }
    }

    func pairAccount(_ zip32AccountIndex: Zip32AccountIndex) async throws -> LedgerPairing {
        guard let transport else {
            throw LedgerClientError.notConnected
        }
        LoggerProxy.event("Ledger: pairing account \(zip32AccountIndex.index)")
        do {
            let pairing = try await pair(transport, zip32AccountIndex)
            LoggerProxy.event("Ledger: paired (Zcash app \(pairing.appVersion))")
            return pairing
        } catch {
            LoggerProxy.warn("Ledger: pairing failed (\(Self.errorTag(error)))")
            throw error
        }
    }

    func disconnect() async {
        guard let previous = transport else { return }
        transport = nil
        await previous.close()
        LoggerProxy.event("Ledger: disconnected")
    }

    /// Signs `pczt` on the connected device: yields `.progress` for each stage the SDK reports, in
    /// order, then `.signed` once, then finishes. Finishes throwing
    /// ``LedgerClientError/notConnected`` when nothing is connected. The actor lets go of isolation
    /// for the ceremony's duration — signing can take as long as the user needs to review the
    /// transaction on the device — and only comes back to it to record the outcome.
    nonisolated func signPCZT(
        _ pczt: Pczt,
        accountUUID: AccountUUID,
        binding: LedgerAccountBinding
    ) -> AsyncThrowingStream<LedgerSigningEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let transport = await self.transport else {
                    LoggerProxy.warn("Ledger: signing requested with no connection")
                    continuation.finish(throwing: LedgerClientError.notConnected)
                    return
                }

                LoggerProxy.event("Ledger: signing started")
                do {
                    let signed = try await self.sign(transport, pczt, accountUUID, binding) { stage in
                        LoggerProxy.event("Ledger: signing stage \(Self.stageTag(stage))")
                        continuation.yield(.progress(stage))
                    }
                    LoggerProxy.event("Ledger: signed")
                    continuation.yield(.signed(signed))
                    continuation.finish()
                } catch {
                    LoggerProxy.warn("Ledger: signing failed (\(Self.errorTag(error)))")
                    if Self.shouldDropTransport(after: error) {
                        await self.dropTransport()
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Forgets the open transport — called only after a signing failure the SDK already closed it
    /// for; never calls `close()` again, since the SDK already did.
    private func dropTransport() {
        transport = nil
    }

    /// The error's stable code (`ZLEDG…`) or type name — never its message, which for a custom
    /// transport could carry device data.
    private static func errorTag(_ error: Error) -> String {
        if let zcashError = error as? ZcashError {
            return zcashError.code.rawValue
        }
        return String(describing: type(of: error))
    }

    /// The stage's tag for the one-line-per-stage progress log — never the PCZT, keys, identities
    /// or addresses those stages are about.
    private static func stageTag(_ stage: LedgerSigningProgress) -> String {
        switch stage {
        case .identifyingDevice:
            return "identifyingDevice"
        case .streaming(let sent, let total):
            return "streaming \(sent)/\(total)"
        case .awaitingReviewOnDevice:
            return "awaitingReviewOnDevice"
        case .signing:
            return "signing"
        case .complete:
            return "complete"
        }
    }

    /// Whether a signing failure means the SDK already closed the transport, so the session should
    /// drop its reference to it rather than leave a dead one open for a retry that would only fail
    /// again. `CancellationError` counts too: cancelling a ceremony closes the transport the same
    /// way a transport-level failure does (docs/LEDGER.md). Every other error — a refusal, a rule
    /// violation, a mismatch — is a function of the transaction or the device, not the connection,
    /// so the same transport can retry.
    private static func shouldDropTransport(after error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        guard let zcashError = error as? ZcashError else {
            return false
        }
        switch zcashError {
        case .ledgerBluetoothDisconnected, .ledgerTimeout, .ledgerTransportClosed, .ledgerTransportFailed:
            return true
        default:
            return false
        }
    }
}

extension LedgerClient: DependencyKey {
    static let liveValue: Self = {
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        @Dependency(\.sdkSynchronizer) var sdkSynchronizer
        let networkType = zcashSDKEnvironment.network().networkType

        let session = LedgerSession(
            // The SDK logs connection stages, frame counts and error kinds only — never command,
            // reply, key or address bytes — so its debug log is safe to keep on.
            makeScanner: { LedgerBluetoothScanner(logger: OSLogger(logLevel: .debug, category: LoggerConstants.ledgerLogs)) },
            pair: { transport, zip32AccountIndex in
                let device = LedgerDevice(transport: transport, networkType: networkType)
                let pairing = try await device.pairAccount(zip32AccountIndex: zip32AccountIndex)
                return LedgerPairing(
                    ufvk: pairing.ufvk.stringEncoded,
                    binding: pairing.binding,
                    appVersion: pairing.appVersion.description
                )
            },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await sdkSynchronizer.signPCZTWithLedger(pczt, accountUUID, binding, transport, progress)
            }
        )

        return Self(
            scanDevices: { session.scanDevices() },
            connect: { device in try await session.connect(device) },
            pairAccount: { zip32AccountIndex in try await session.pairAccount(zip32AccountIndex) },
            disconnect: { await session.disconnect() },
            signPCZT: { pczt, accountUUID, binding in session.signPCZT(pczt, accountUUID: accountUUID, binding: binding) }
        )
    }()
}
