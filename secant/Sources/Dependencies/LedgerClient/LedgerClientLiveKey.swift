//
//  LedgerClientLiveKey.swift
//  Zashi
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

/// Finds Ledger devices and opens connections to them.
///
/// ``LedgerBluetoothScanner`` is the live conformance. A fake conforms in tests, so
/// ``LedgerSession`` can be driven without CoreBluetooth or a physical device.
protocol LedgerScanning: Sendable {
    func devices() -> AsyncThrowingStream<[LedgerBluetoothDevice], Error>
    func connect(to device: LedgerBluetoothDevice, timeout: TimeInterval) async throws -> any LedgerAPDUTransport
}

extension LedgerBluetoothScanner: LedgerScanning {
    // Naming this `connect(to:timeout:)` too -- the SDK's own method already has that shape --
    // would make the call below ambiguous between the two. The local `LedgerBluetoothTransport`
    // annotation picks the SDK's method (the only one returning that concrete type); the result
    // then converts to `any LedgerAPDUTransport` for the return. `timeout` just passes through.
    func connect(to device: LedgerBluetoothDevice, timeout: TimeInterval) async throws -> any LedgerAPDUTransport {
        let transport: LedgerBluetoothTransport = try await connect(to: device, timeout: timeout)
        return transport
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
/// `connect` always closes a previously open transport before opening the new one, then makes
/// sure the Zcash app is open on the device -- which may wait for the user to confirm it there --
/// before returning, and remembers the device for `pairAccount`'s own reconnect below.
/// `pairAccount` throws ``LedgerClientError/notConnected`` when nothing is open; otherwise it
/// adopts the transport the SDK reports as live once pairing returns, whether it succeeded or
/// failed -- the SDK's own read-before-export retry (MOB-2020) may have reconnected on a fresh
/// transport, and a session still holding the old one would hand a dead transport to a later retry
/// or signing -- but only when this session's own transport is still the one pairing started
/// with (MOB-2020): a `disconnect()` (Close or Back) can run during that `await`,
/// and adopting a transport reported live after that would put back one the session already tore
/// down, so this closes it instead.
///
/// `signPCZT` throws the same error when nothing is open. A signing failure leaves the transport
/// open too, UNLESS the SDK has already closed it: `ledgerBluetoothDisconnected`, `ledgerTimeout`,
/// `ledgerTransportClosed`, `ledgerTransportFailed` and cancellation all mean the transport is
/// already gone (see docs/LEDGER.md's "transport closed" rule), so the session drops its reference
/// rather than keep a dead one around for a retry that would only fail again.
actor LedgerSession {
    /// `connect`'s own Bluetooth connection timeout.
    private static let connectTimeout: TimeInterval = 60
    /// The reconnect timeout `openZcashApp` uses while the device switches apps -- the SDK's own
    /// app-switch window (`LedgerZcashApp`'s doc comment).
    private static let appSwitchTimeout: TimeInterval = 10

    private nonisolated let makeScanner: @Sendable () -> any LedgerScanning
    private nonisolated let scannerBox = LockIsolated<(any LedgerScanning)?>(nil)
    private let pair: @Sendable (
        any LedgerAPDUTransport, Zip32AccountIndex, @escaping @Sendable () async throws -> any LedgerAPDUTransport
    ) async -> (Result<LedgerPairing, Error>, any LedgerAPDUTransport)
    private nonisolated let sign: @Sendable (
        any LedgerAPDUTransport, Pczt, AccountUUID, LedgerAccountBinding, @escaping @Sendable (LedgerSigningProgress) -> Void
    ) async throws -> Pczt
    private let openZcashApp: @Sendable (
        any LedgerAPDUTransport, @escaping @Sendable () async throws -> any LedgerAPDUTransport
    ) async throws -> any LedgerAPDUTransport
    private var transport: (any LedgerAPDUTransport)?
    /// The device `connect` last connected -- `pairAccount`'s own reconnect closure targets it
    /// again, the same device, never a different one a later scan might turn up.
    private var connectedDevice: LedgerBluetoothDevice?

    init(
        makeScanner: @escaping @Sendable () -> any LedgerScanning,
        pair: @escaping @Sendable (
            any LedgerAPDUTransport, Zip32AccountIndex, @escaping @Sendable () async throws -> any LedgerAPDUTransport
        ) async -> (Result<LedgerPairing, Error>, any LedgerAPDUTransport),
        sign: @escaping @Sendable (
            any LedgerAPDUTransport, Pczt, AccountUUID, LedgerAccountBinding, @escaping @Sendable (LedgerSigningProgress) -> Void
        ) async throws -> Pczt,
        openZcashApp: @escaping @Sendable (
            any LedgerAPDUTransport, @escaping @Sendable () async throws -> any LedgerAPDUTransport
        ) async throws -> any LedgerAPDUTransport
    ) {
        self.makeScanner = makeScanner
        self.pair = pair
        self.sign = sign
        self.openZcashApp = openZcashApp
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
        connectedDevice = device
        LoggerProxy.event("Ledger: connecting to a \(device.model.productName)")
        let opened: any LedgerAPDUTransport
        do {
            opened = try await scanner().connect(to: device, timeout: Self.connectTimeout)
            LoggerProxy.event("Ledger: connected")
        } catch {
            LoggerProxy.warn("Ledger: connect failed (\(Self.errorTag(error)))")
            // MOB-2020: tag a failure of THIS step -- the raw Bluetooth bond, before any command
            // reached the device -- so LedgerIssue.init(_:in:) can tell it apart from a failure
            // once the link is up. A cancellation is not a connection failure to report; it
            // propagates as itself.
            if error is CancellationError {
                throw error
            }
            throw LedgerBluetoothConnectFailure(underlying: error)
        }

        LoggerProxy.event("Ledger: opening the Zcash app if needed")
        do {
            transport = try await openZcashApp(opened) {
                try await self.scanner().connect(to: device, timeout: Self.appSwitchTimeout)
            }
            LoggerProxy.event("Ledger: the Zcash app is open")
        } catch {
            transport = nil
            await opened.close()
            LoggerProxy.warn("Ledger: opening the Zcash app failed (\(Self.errorTag(error)))")
            throw error
        }
    }

    func pairAccount(_ zip32AccountIndex: Zip32AccountIndex) async throws -> LedgerPairing {
        guard let transport, let device = connectedDevice else {
            throw LedgerClientError.notConnected
        }
        LoggerProxy.event("Ledger: pairing account \(zip32AccountIndex.index)")
        let (result, liveTransport) = await pair(transport, zip32AccountIndex) {
            try await self.scanner().connect(to: device, timeout: Self.connectTimeout)
        }
        // The SDK's own read-before-export retry may have reconnected on a fresh transport --
        // adopt whatever it reports as live first, whether pairing succeeded or failed, so a
        // session still holding the old (possibly SDK-closed) one never hands it to a later retry
        // or signing. But only when this session's own transport is still the one `pair` was
        // called with -- a `disconnect()` (Close or Back) can run during the `await` above, and
        // adopting the transport it reports live then would put back one the session already
        // tore down. Compared by reference, the same way `dropTransport(ifStillOpen:)` below
        // does: `LedgerAPDUTransport` is not class-bound, but both the live and fake conformances
        // are reference types.
        if let current = self.transport, current as AnyObject === transport as AnyObject {
            self.transport = liveTransport
        } else if liveTransport as AnyObject !== transport as AnyObject {
            // Not the transport this call started with and not already closed by that
            // disconnect() (which would make this a redundant double close) -- close it so it
            // isn't leaked open and orphaned.
            await liveTransport.close()
        }
        switch result {
        case let .success(pairing):
            LoggerProxy.event("Ledger: paired (Zcash app \(pairing.appVersion))")
            return pairing
        case let .failure(error):
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
                        await self.dropTransport(ifStillOpen: transport)
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Forgets the open transport after a signing failure the SDK already closed it for — but only
    /// when the session is still holding the very transport the ceremony used. A `connect()` that
    /// opened a different transport while this ceremony's failure was still unwinding must not lose
    /// that newer, live transport to a stale ceremony's cleanup. Compared by reference
    /// (`LedgerAPDUTransport` is not class-bound, but both the live and fake conformances are
    /// reference types — `LedgerBluetoothTransport` is an actor), since the protocol does not
    /// require `Equatable`. Never calls `close()` again on it — the SDK already did.
    private func dropTransport(ifStillOpen usedTransport: any LedgerAPDUTransport) {
        guard let current = transport, current as AnyObject === usedTransport as AnyObject else {
            return
        }
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
            pair: { transport, zip32AccountIndex, reconnect in
                let device = LedgerDevice(transport: transport, networkType: networkType)
                do {
                    let pairing = try await device.pairAccount(
                        zip32AccountIndex: zip32AccountIndex,
                        readTimeout: LedgerDevice.defaultPairingReadTimeout,
                        reconnect: reconnect
                    )
                    let live = LedgerPairing(
                        ufvk: pairing.ufvk.stringEncoded,
                        binding: pairing.binding,
                        appVersion: pairing.appVersion.description
                    )
                    return (.success(live), await device.transport)
                } catch {
                    return (.failure(error), await device.transport)
                }
            },
            sign: { transport, pczt, accountUUID, binding, progress in
                try await sdkSynchronizer.signPCZTWithLedger(pczt, accountUUID, binding, transport, progress)
            },
            openZcashApp: { transport, reconnect in
                try await LedgerZcashApp.ensureZcashAppOpen(transport: transport, reconnect: reconnect)
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
