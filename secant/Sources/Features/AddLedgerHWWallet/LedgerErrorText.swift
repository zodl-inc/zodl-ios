//
//  LedgerErrorText.swift
//  Zashi
//
//  Maps a Ledger connect/pair failure to the string the UI shows, and reports whether the
//  failure left the Bluetooth connection unusable (so the user must pick a device again) as
//  opposed to a device refusal (where the transport stays open and pairing can be retried).
//  Matches on the `ZcashError`/`LedgerClientError` case only, never on message text — see
//  ../../Dependencies/LedgerClient/LedgerClientInterface.swift and
//  ../../../../docs/LEDGER.md in the SDK worktree for the case list.
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum LedgerErrorText {
    static func message(for error: Error) -> String {
        switch error {
        case ZcashError.ledgerBluetoothPoweredOff:
            return String(localizable: .ledgerErrorBluetoothOff)
        case ZcashError.ledgerBluetoothUnauthorized:
            return String(localizable: .ledgerErrorBluetoothUnauthorized)
        case ZcashError.ledgerBluetoothUnsupported:
            return String(localizable: .ledgerErrorBluetoothUnsupported)
        case ZcashError.ledgerWrongApp:
            return String(localizable: .ledgerErrorWrongApp)
        case ZcashError.ledgerAppTooOld:
            return String(localizable: .ledgerErrorAppTooOld)
        case ZcashError.ledgerUserRejected:
            return String(localizable: .ledgerErrorUserRejected)
        case ZcashError.ledgerBluetoothPairingRefused:
            return String(localizable: .ledgerErrorPairingRefused)
        case ZcashError.ledgerDeviceMismatch:
            return String(localizable: .ledgerErrorDeviceMismatch)
        default:
            if isConnectionLost(error) {
                return String(localizable: .ledgerErrorConnectionLost)
            }
            return String(localizable: .ledgerErrorGeneric)
        }
    }

    /// `true` for a transport failure (the connection is closed and the user must pick a device
    /// again), `false` for a device refusal (the transport stays open and pairing can be
    /// retried on it) or any other failure.
    static func isConnectionLost(_ error: Error) -> Bool {
        switch error {
        case ZcashError.ledgerTransportClosed,
            ZcashError.ledgerBluetoothDisconnected,
            ZcashError.ledgerTimeout,
            ZcashError.ledgerBluetoothConnectionFailed:
            return true
        case LedgerClientError.notConnected:
            return true
        default:
            return false
        }
    }
}
