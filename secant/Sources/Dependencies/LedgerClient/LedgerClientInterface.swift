//
//  LedgerClientInterface.swift
//  Zashi
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var ledgerClient: LedgerClient {
        get { self[LedgerClient.self] }
        set { self[LedgerClient.self] = newValue }
    }
}

/// What a wallet keeps after pairing an account on a Ledger device: the account's viewing key to
/// import, and the binding to persist next to it so a later signing session can find the device
/// and account index again.
struct LedgerPairing: Equatable, Sendable {
    /// The account's unified full viewing key, encoded for `sdkSynchronizer.importAccount`.
    let ufvk: String
    /// The device and ZIP 32 account index to persist next to the imported account.
    let binding: LedgerAccountBinding
    /// The Zcash app version the device was running when the account was paired.
    let appVersion: String
}

enum LedgerClientError: Error, Equatable, LocalizedError {
    /// `pairAccount` was called before `connect` opened a transport.
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "No Ledger device is connected."
        }
    }
}

/// One step of a Ledger signing ceremony, as `LedgerClient.signPCZT` reports it.
enum LedgerSigningEvent: Equatable, Sendable {
    case progress(LedgerSigningProgress)
    case signed(Pczt)
}

@DependencyClient
struct LedgerClient {
    /// Scans for Ledger devices. Each element is the whole list found so far.
    var scanDevices: @Sendable () -> AsyncThrowingStream<[LedgerBluetoothDevice], Error> = {
        AsyncThrowingStream { $0.finish() }
    }
    /// Connects to a device, closing any previously open connection first.
    var connect: @Sendable (LedgerBluetoothDevice) async throws -> Void
    /// Pairs an account on the connected device. Throws ``LedgerClientError/notConnected`` when
    /// nothing is connected.
    var pairAccount: @Sendable (Zip32AccountIndex) async throws -> LedgerPairing
    /// Closes the open connection, if any.
    var disconnect: @Sendable () async -> Void
    /// Signs a PCZT on the connected device. Yields `.progress` for each stage the SDK reports, in
    /// order, then `.signed` once, then finishes. Fails with `LedgerClientError/notConnected` when
    /// nothing is connected, otherwise with the SDK's error. Cancelling the consumer cancels the
    /// ceremony (the SDK then closes the transport).
    var signPCZT: @Sendable (Pczt, AccountUUID, LedgerAccountBinding) -> AsyncThrowingStream<LedgerSigningEvent, Error> = { _, _, _ in
        AsyncThrowingStream { $0.finish(throwing: LedgerClientError.notConnected) }
    }
}
