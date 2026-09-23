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
    /// Maps a Ledger failure to the message shown for a **pairing/export** failure -- the
    /// `AddLedgerHWWallet` scan/connect/pair flow. `.ledgerUserRejected` means the user declined
    /// the viewing-key export on the device here; see `signingMessage(for:)` for the same SDK
    /// case's *different* meaning once signing exists (declining a transaction).
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
        // MOB-2020 Phase 3.2: signing-only cases -- never reachable from `AddLedgerHWWallet`'s
        // scan/connect/pair path. The SDK's `reason` text is deliberately never surfaced here (it
        // can describe the transaction), so both a caps mismatch and an unsignable transaction
        // share the same generic "can't sign this" copy.
        case ZcashError.ledgerTransactionNotSignable:
            return String(localizable: .ledgerErrorNotSignable)
        case ZcashError.ledgerDerivationBudgetExhausted:
            return String(localizable: .ledgerErrorDerivationBudget)
        case ZcashError.ledgerCapsMismatch:
            return String(localizable: .ledgerErrorNotSignable)
        default:
            if isConnectionLost(error) {
                return String(localizable: .ledgerErrorConnectionLost)
            }
            return String(localizable: .ledgerErrorGeneric)
        }
    }

    /// Maps a Ledger failure to the message shown for a **signing** failure --
    /// `LedgerSigning`/`LedgerSignSheetView`'s ceremony. `.ledgerUserRejected` means the user
    /// declined the *transaction* on the device here, distinct from `message(for:)`'s
    /// pairing-time meaning (declining the viewing-key export) -- the two contexts need different
    /// copy for the same SDK case. Every other case reads correctly in both contexts, so this
    /// defers to `message(for:)`.
    static func signingMessage(for error: Error) -> String {
        switch error {
        case ZcashError.ledgerUserRejected:
            return String(localizable: .ledgerErrorRejected)
        default:
            return message(for: error)
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
            ZcashError.ledgerBluetoothConnectionFailed,
            ZcashError.ledgerTransportFailed:
            return true
        case LedgerClientError.notConnected:
            return true
        default:
            return false
        }
    }

    /// Whether a fresh attempt at the same Ledger operation could succeed -- wraps the SDK's own
    /// `ZcashError.ledgerIsRestartable`, `false` for anything that did not come from the Ledger
    /// integration (`nil` there).
    static func isRestartable(_ error: Error) -> Bool {
        (error as? ZcashError)?.ledgerIsRestartable ?? false
    }
}
