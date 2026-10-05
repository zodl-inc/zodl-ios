//
//  LedgerIssue.swift
//  Zashi
//
//  MOB-2020 Ledger error states: classifies a Ledger connect/pair/sign failure into the state
//  Figma's "Error States and Edge Cases" (Dev-Ready Q3 2026, node 1073:12817) draws as a bottom
//  sheet over the device picker -- an alert icon, a title, a message and one button -- and
//  supplies that sheet's copy and action. Matches on the `ZcashError`/`LedgerClientError` case
//  only, never on message text -- the one failure the SDK has no case for, an import collision,
//  is classified by LedgerAccountCollision.swift instead.
//

import Foundation
@preconcurrency import ZcashLightClientKit

/// One of the states the Ledger error sheets show, plus the copy and primary action that go with
/// it in each `Context`.
enum LedgerIssue: Equatable, Sendable, CaseIterable {
    /// Figma "Bluetooth Access Required."
    case bluetoothUnauthorized
    /// Not in Figma; draft copy.
    case bluetoothOff
    /// Not in Figma; draft copy.
    case bluetoothUnsupported
    /// Figma "No Devices Found."
    case noDevicesFound
    /// Figma "Unlock Your Ledger."
    case deviceLocked
    /// Figma "Pairing Failed."
    case pairingFailed
    /// Not in Figma; Android's copy.
    case appNotInstalled
    /// Not in Figma; Android's copy.
    case openAppRejected
    /// Figma "Import Rejected" in `.connect`; `.sign`'s "Transaction Rejected" is draft copy.
    case requestRejected
    /// Figma "Ledger Disconnected"; the `.sign` message is draft copy.
    case disconnected
    /// Figma "Account Already Added." Never produced by `init(_:)` -- `LedgerAccountCollision`
    /// classifies import collisions itself.
    case accountAlreadyAdded
    /// Not in Figma; draft copy.
    case appTooOld
    /// Not in Figma; draft copy.
    case derivationBudgetExhausted
    /// Not in Figma; draft copy.
    case deviceMismatch
    /// Not in Figma, draft copy (Android calls it "Ledger Not Paired"). The account has no
    /// stored Ledger binding, so no device can sign for it. Never produced by `init(_:)` --
    /// `SendConfirmation` reports it directly.
    case notPaired
    /// Not in Figma; draft copy.
    case transactionNotSignable
    /// Not in Figma; draft copy -- the catch-all for anything else.
    case unknown

    /// Which screen is showing the issue. The copy and the available primary action both depend
    /// on it.
    enum Context: Equatable, Sendable {
        /// The connect flow is `AddLedgerHWWallet`'s scan/connect/pair flow.
        case connect
        /// The Ledger sign sheet.
        case sign
    }

    /// The sheet's one button, or none.
    enum PrimaryAction: Equatable, Sendable {
        case tryAgain, openSettings, goToAccount, close, none
    }

    /// How long a scan may run without finding any Ledger before `.noDevicesFound` is shown.
    static let noDevicesFoundTimeout: Duration = .seconds(20)

    /// Classifies a Ledger failure by its `ZcashError`/`LedgerClientError` case only, never by
    /// message text. Never produces `.accountAlreadyAdded`; `LedgerAccountCollision` classifies
    /// import collisions itself.
    init(_ error: Error) {
        switch error {
        case ZcashError.ledgerBluetoothUnauthorized:
            self = .bluetoothUnauthorized
        case ZcashError.ledgerBluetoothPoweredOff:
            self = .bluetoothOff
        case ZcashError.ledgerBluetoothUnsupported:
            self = .bluetoothUnsupported
        case ZcashError.ledgerDeviceNotFound:
            self = .noDevicesFound
        case ZcashError.ledgerWrongApp, ZcashError.ledgerDeviceRefused(_, true):
            // `ledgerWrongApp` and a transient device refusal (such as a locked device) both
            // clear on their own once the user unlocks the device or opens the app, so they
            // share copy telling the user to do exactly that.
            self = .deviceLocked
        case ZcashError.ledgerBluetoothPairingRefused:
            self = .pairingFailed
        case ZcashError.ledgerAppNotInstalled:
            self = .appNotInstalled
        case ZcashError.ledgerAppOpenRejected:
            self = .openAppRejected
        case ZcashError.ledgerUserRejected:
            self = .requestRejected
        case ZcashError.ledgerBluetoothDisconnected,
            ZcashError.ledgerTimeout,
            ZcashError.ledgerTransportClosed,
            ZcashError.ledgerTransportFailed,
            ZcashError.ledgerBluetoothConnectionFailed,
            LedgerClientError.notConnected:
            self = .disconnected
        case ZcashError.ledgerAppTooOld:
            self = .appTooOld
        case ZcashError.ledgerDerivationBudgetExhausted:
            self = .derivationBudgetExhausted
        case ZcashError.ledgerDeviceMismatch:
            self = .deviceMismatch
        case ZcashError.ledgerTransactionNotSignable, ZcashError.ledgerCapsMismatch:
            self = .transactionNotSignable
        default:
            // `ledgerDeviceRefused(_, false)` (a non-transient refusal), `ledgerMalformedReply`,
            // `ledgerInvalidInput`, `ledgerInternal`, any other ZcashError case, and any
            // non-Ledger error all land here.
            self = .unknown
        }
    }

    /// The sheet's title in `context`.
    func title(in context: Context) -> String {
        switch self {
        case .bluetoothUnauthorized:
            return String(localizable: .ledgerIssueBluetoothUnauthorizedTitle)
        case .bluetoothOff:
            return String(localizable: .ledgerIssueBluetoothOffTitle)
        case .bluetoothUnsupported:
            return String(localizable: .ledgerIssueBluetoothUnsupportedTitle)
        case .noDevicesFound:
            return String(localizable: .ledgerIssueNoDevicesFoundTitle)
        case .deviceLocked:
            return String(localizable: .ledgerIssueDeviceLockedTitle)
        case .pairingFailed:
            return String(localizable: .ledgerIssuePairingFailedTitle)
        case .appNotInstalled:
            return String(localizable: .ledgerIssueAppNotInstalledTitle)
        case .openAppRejected:
            return String(localizable: .ledgerIssueOpenAppRejectedTitle)
        case .requestRejected:
            switch context {
            case .connect: return String(localizable: .ledgerIssueRequestRejectedTitle)
            case .sign: return String(localizable: .ledgerIssueRequestRejectedSignTitle)
            }
        case .disconnected:
            return String(localizable: .ledgerIssueDisconnectedTitle)
        case .accountAlreadyAdded:
            return String(localizable: .ledgerIssueAccountAlreadyAddedTitle)
        case .appTooOld:
            return String(localizable: .ledgerIssueAppTooOldTitle)
        case .derivationBudgetExhausted:
            return String(localizable: .ledgerIssueDerivationBudgetTitle)
        case .deviceMismatch:
            return String(localizable: .ledgerIssueDeviceMismatchTitle)
        case .notPaired:
            return String(localizable: .ledgerIssueNotPairedTitle)
        case .transactionNotSignable:
            return String(localizable: .ledgerIssueNotSignableTitle)
        case .unknown:
            return String(localizable: .ledgerIssueUnknownTitle)
        }
    }

    /// The sheet's message in `context`.
    func message(in context: Context) -> String {
        switch self {
        case .bluetoothUnauthorized:
            return String(localizable: .ledgerIssueBluetoothUnauthorizedMessage)
        case .bluetoothOff:
            return String(localizable: .ledgerIssueBluetoothOffMessage)
        case .bluetoothUnsupported:
            return String(localizable: .ledgerIssueBluetoothUnsupportedMessage)
        case .noDevicesFound:
            return String(localizable: .ledgerIssueNoDevicesFoundMessage)
        case .deviceLocked:
            return String(localizable: .ledgerIssueDeviceLockedMessage)
        case .pairingFailed:
            return String(localizable: .ledgerIssuePairingFailedMessage)
        case .appNotInstalled:
            return String(localizable: .ledgerIssueAppNotInstalledMessage)
        case .openAppRejected:
            return String(localizable: .ledgerIssueOpenAppRejectedMessage)
        case .requestRejected:
            switch context {
            case .connect: return String(localizable: .ledgerIssueRequestRejectedMessage)
            case .sign: return String(localizable: .ledgerIssueRequestRejectedSignMessage)
            }
        case .disconnected:
            switch context {
            case .connect: return String(localizable: .ledgerIssueDisconnectedMessage)
            case .sign: return String(localizable: .ledgerIssueDisconnectedSignMessage)
            }
        case .accountAlreadyAdded:
            return String(localizable: .ledgerIssueAccountAlreadyAddedMessage)
        case .appTooOld:
            return String(localizable: .ledgerIssueAppTooOldMessage)
        case .derivationBudgetExhausted:
            return String(localizable: .ledgerIssueDerivationBudgetMessage)
        case .deviceMismatch:
            return String(localizable: .ledgerIssueDeviceMismatchMessage)
        case .notPaired:
            return String(localizable: .ledgerIssueNotPairedMessage)
        case .transactionNotSignable:
            return String(localizable: .ledgerIssueNotSignableMessage)
        case .unknown:
            switch context {
            case .connect: return String(localizable: .ledgerIssueUnknownMessage)
            case .sign: return String(localizable: .ledgerIssueUnknownSignMessage)
            }
        }
    }

    /// The sheet's one button in `context`.
    func primaryAction(in context: Context) -> PrimaryAction {
        switch self {
        case .bluetoothUnauthorized:
            return .openSettings
        case .bluetoothOff:
            return .tryAgain
        case .bluetoothUnsupported:
            return context == .connect ? .close : .none
        case .noDevicesFound:
            return .tryAgain
        case .deviceLocked:
            return .tryAgain
        case .pairingFailed:
            return .tryAgain
        case .appNotInstalled:
            return .tryAgain
        case .openAppRejected:
            return .tryAgain
        case .requestRejected:
            return .tryAgain
        case .disconnected:
            return .tryAgain
        case .accountAlreadyAdded:
            return context == .connect ? .goToAccount : .none
        case .appTooOld:
            return .tryAgain
        case .derivationBudgetExhausted:
            return .tryAgain
        case .deviceMismatch:
            return .tryAgain
        case .notPaired:
            return .none
        case .transactionNotSignable:
            return context == .connect ? .close : .none
        case .unknown:
            return .tryAgain
        }
    }

    /// `primaryAction(in:)`'s button title, or `nil` for `.none`.
    func primaryActionTitle(in context: Context) -> String? {
        switch primaryAction(in: context) {
        case .tryAgain: return String(localizable: .ledgerIssueTryAgain)
        case .openSettings: return String(localizable: .ledgerIssueOpenSettings)
        case .goToAccount: return String(localizable: .ledgerIssueGoToAccount)
        case .close: return String(localizable: .generalClose)
        case .none: return nil
        }
    }

    /// `true` when a retry must scan and connect again, rather than repeat the request on the
    /// connection that is still open. A device refusal (`.deviceLocked`, `.requestRejected`,
    /// `.derivationBudgetExhausted` or `.transactionNotSignable`) leaves the transport usable for
    /// another attempt; `.accountAlreadyAdded` and `.notPaired` need no retry at all. Everything
    /// else needs a fresh scan and connection: the transport is gone, or a different or restarted
    /// device must be connected (`.deviceMismatch`, `.appTooOld` after the update, and
    /// `.unknown`, where a clean reconnect is the safe retry).
    var retryNeedsNewConnection: Bool {
        switch self {
        case .bluetoothUnauthorized, .bluetoothOff, .bluetoothUnsupported, .noDevicesFound,
            .pairingFailed, .appNotInstalled, .openAppRejected, .disconnected, .appTooOld, .deviceMismatch, .unknown:
            return true
        case .deviceLocked, .requestRejected, .accountAlreadyAdded, .notPaired, .derivationBudgetExhausted,
            .transactionNotSignable:
            return false
        }
    }
}
