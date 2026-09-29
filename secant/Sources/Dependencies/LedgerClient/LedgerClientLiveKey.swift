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
/// always adopts the transport the SDK reports as live once pairing returns, whether it succeeded
/// or failed -- the SDK's own read-before-export retry (MOB-2020) may have reconnected on a fresh
/// transport, and a session still holding the old one would hand a dead transport to a later retry
/// or signing.
///
/// `signPCZT` throws the same error when nothing is open. A signing failure leaves the transport
/// open too, UNLESS the SDK has already closed it: `ledgerBluetoothDisconnected`, `ledgerTimeout`,
/// `ledgerTransportClosed`, `ledgerTransportFailed` and cancellation all mean the transport is
/// already gone (see docs/LEDGER.md's "transport closed" rule), so the session drops its reference
/// rather than keep a dead one around for a retry that would only fail again.
///
/// `bond`, `openZcashApp(_:)` and `pairDevice(_:_:)` (MOB-2020) are enrollment's own operations:
/// each opens a connection of its own on the same scanner and closes it before returning, never
/// reading or writing `transport`/`connectedDevice` above, so enrollment and signing never
/// overlap.
actor LedgerSession {
    /// `connect`'s own Bluetooth connection timeout.
    private static let connectTimeout: TimeInterval = 60
    /// The reconnect timeout `openZcashApp` uses while the device switches apps -- the SDK's own
    /// app-switch window (`LedgerZcashApp`'s doc comment).
    private static let appSwitchTimeout: TimeInterval = 10
    /// The status word a locked Ledger answers any command with (MOB-2020, Android
    /// `LOCKED_STATUS_WORD`) -- ``bond(_:)``'s one query failure that is not swallowed.
    private static let lockedStatusWord: UInt16 = 0x5515

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
    /// Reads which app a transport's device is running -- `LedgerZcashApp.currentApp` live,
    /// injected so ``bond(_:)`` can be driven by a fake in tests.
    private let currentApp: @Sendable (any LedgerAPDUTransport) async throws -> LedgerRunningApp
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
        ) async throws -> any LedgerAPDUTransport,
        currentApp: @escaping @Sendable (any LedgerAPDUTransport) async throws -> LedgerRunningApp
    ) {
        self.makeScanner = makeScanner
        self.pair = pair
        self.sign = sign
        self.openZcashApp = openZcashApp
        self.currentApp = currentApp
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
            throw error
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
        // or signing.
        self.transport = liveTransport
        switch result {
        case let .success(pairing):
            LoggerProxy.event("Ledger: paired (Zcash app \(pairing.appVersion))")
            return pairing
        case let .failure(error):
            LoggerProxy.warn("Ledger: pairing failed (\(Self.errorTag(error)))")
            throw error
        }
    }

    // MARK: - Enrollment's own bond, open-app and pair connections (MOB-2020)
    //
    // `bond`, `openZcashApp(_:)` and `pairDevice(_:_:)` each open their own connection on
    // `scanner()` and close it before returning, success or failure alike -- none of them reads
    // or writes `transport`/`connectedDevice` above, so enrollment and signing never overlap. On
    // a first Bluetooth pairing with the Zcash app already open, the Ledger freezes on its
    // pairing screen; enrollment therefore bonds on the dashboard first (`bond`), then opens the
    // app and pairs afterward, each over its own connection.

    /// Bonds with `device` -- pairing over Bluetooth if the phone has not yet -- and asks it
    /// once which app it runs, so the caller can skip ``openZcashApp(_:)`` when it already runs
    /// the Zcash app (Android 48b8d5bc, 6c9491c7, e3480698).
    ///
    /// - Returns: whether the device reported the Zcash app running already.
    /// - Throws: the connect step's own failure, unwrapped -- the caller classifies it with
    ///   `LedgerIssue.init(_:in:bonding:)`'s `bonding: true`. `ZcashError.ledgerDeviceRefused` when
    ///   the app query finds the device locked (status word `lockedStatusWord`): every step that
    ///   follows would refuse the same way, so this is the one query failure not swallowed. Any
    ///   other failure of the query only leaves the answer unknown, reported as `false`, since
    ///   the bond itself already succeeded.
    func bond(_ device: LedgerBluetoothDevice) async throws -> Bool {
        LoggerProxy.event("Ledger: bonding with a \(device.model.productName)")
        let opened: any LedgerAPDUTransport
        do {
            opened = try await scanner().connect(to: device, timeout: Self.connectTimeout)
            LoggerProxy.event("Ledger: bonded")
        } catch {
            LoggerProxy.warn("Ledger: bond failed (\(Self.errorTag(error)))")
            throw error
        }
        // Closed here in every case, including cancellation: `close()` cannot itself throw, so
        // this always runs to completion before `bond` returns or rethrows.
        defer { await opened.close() }

        do {
            return try await currentApp(opened).isZcash
        } catch {
            if error is CancellationError {
                throw error
            }
            if case ZcashError.ledgerDeviceRefused(Self.lockedStatusWord, _) = error {
                throw error
            }
            LoggerProxy.info("Ledger: bond's app query failed, the running app is unknown (\(Self.errorTag(error)))")
            return false
        }
    }

    /// Asks `device` to open the Zcash app, over a connection of its own -- the phone has
    /// already bonded with it (``bond(_:)``), so this sends the open command itself and waits
    /// for the user's confirmation on the device (Android 49811921).
    ///
    /// - Throws: the connect step's own failure, unwrapped. Otherwise whatever the open step
    ///   throws: a declined or missing app, or a reconnect that ran out of time while the device
    ///   switched apps.
    func openZcashApp(_ device: LedgerBluetoothDevice) async throws {
        LoggerProxy.event("Ledger: opening the Zcash app on a \(device.model.productName)")
        let opened: any LedgerAPDUTransport
        do {
            opened = try await scanner().connect(to: device, timeout: Self.connectTimeout)
        } catch {
            LoggerProxy.warn("Ledger: opening the Zcash app failed to connect (\(Self.errorTag(error)))")
            throw error
        }
        var held: [any LedgerAPDUTransport] = [opened]
        defer { await Self.closeAll(held) }

        do {
            let appTransport = try await self.openZcashApp(opened) {
                try await self.scanner().connect(to: device, timeout: Self.appSwitchTimeout)
            }
            held.append(appTransport)
            LoggerProxy.event("Ledger: the Zcash app is open")
        } catch {
            LoggerProxy.warn("Ledger: opening the Zcash app failed (\(Self.errorTag(error)))")
            throw error
        }
    }

    /// Bonds, opens the Zcash app and pairs `zip32AccountIndex` on `device` -- the same steps as
    /// ``bond(_:)`` and ``openZcashApp(_:)`` followed by the existing `pair` step, each over a
    /// connection of its own (Android aac01e65, 4f7b031e, e838559b).
    ///
    /// - Throws: the connect step's own failure, unwrapped; the open step's; or the pairing's.
    func pairDevice(_ device: LedgerBluetoothDevice, _ zip32AccountIndex: Zip32AccountIndex) async throws -> LedgerPairing {
        LoggerProxy.event("Ledger: pairing a \(device.model.productName), account \(zip32AccountIndex.index)")
        // Every transport this holds -- the first connection, the one the open step returns, and
        // the live one the pair closure reports -- is closed here, on success and failure alike;
        // closing the same one twice (they may coincide) is harmless.
        var held: [any LedgerAPDUTransport] = []
        defer { await Self.closeAll(held) }

        let opened = try await scanner().connect(to: device, timeout: Self.connectTimeout)
        held.append(opened)

        let appTransport = try await self.openZcashApp(opened) {
            try await self.scanner().connect(to: device, timeout: Self.appSwitchTimeout)
        }
        held.append(appTransport)

        let (result, liveTransport) = await pair(appTransport, zip32AccountIndex) {
            try await self.scanner().connect(to: device, timeout: Self.connectTimeout)
        }
        held.append(liveTransport)

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

    /// Closes every transport in `transports`, each at most once even if the same reference
    /// appears more than once (MOB-2020's `bond`/`openZcashApp`/`pairDevice` do not dedup what
    /// they collect) — a second close is documented as harmless, but a fake in tests would still
    /// count it. Compared by reference, the same way `dropTransport(ifStillOpen:)` above does.
    private static func closeAll(_ transports: [any LedgerAPDUTransport]) async {
        var closed: [ObjectIdentifier] = []
        for transport in transports {
            let id = ObjectIdentifier(transport as AnyObject)
            guard !closed.contains(id) else { continue }
            closed.append(id)
            await transport.close()
        }
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
            },
            currentApp: { transport in
                try await LedgerZcashApp.currentApp(transport: transport)
            }
        )

        return Self(
            scanDevices: { session.scanDevices() },
            connect: { device in try await session.connect(device) },
            bond: { device in try await session.bond(device) },
            openZcashApp: { device in try await session.openZcashApp(device) },
            pairDevice: { device, zip32AccountIndex in try await session.pairDevice(device, zip32AccountIndex) },
            pairAccount: { zip32AccountIndex in try await session.pairAccount(zip32AccountIndex) },
            disconnect: { await session.disconnect() },
            signPCZT: { pczt, accountUUID, binding in session.signPCZT(pczt, accountUUID: accountUUID, binding: binding) }
        )
    }()
}
