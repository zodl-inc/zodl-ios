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
    /// Figma "No Devices Found." Only ever produced by the scan itself timing out
    /// (`AddLedgerHWWalletStore`/`LedgerSigningStore`'s `scanTimedOut`) -- never by `init(_:in:)`,
    /// since a connect attempt's own "no such device" failure now reads as `.pairingFailed` or
    /// `.disconnected` (MOB-2020, Android b013b7c2): `ledgerDeviceNotFound` is a connect-time
    /// error, not something the scan (`LedgerBluetoothScanner.devices()`) itself ever throws.
    case noDevicesFound
    /// Figma "Unlock Your Ledger."
    case deviceLocked
    /// Figma "Pairing Failed."
    case pairingFailed
    /// Not in Figma; Android's copy.
    case appNotInstalled
    /// `.connect`/`.pairing` not in Figma, Android's copy; `.sign` is Figma's sign-sheet frame 9,
    /// "Zcash App Not Opened" (node 1652:235).
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
    /// `SendConfirmation` reports it directly. MOB-2020 (Android e36fedb2/ebc98b38): `.sign`
    /// offers Pair Ledger, which reopens the connect flow to pair this account again;
    /// `.connect` has no such affordance since nothing there is missing a pairing.
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
        /// Step 2's bond (`LedgerClient.bond`), while the phone is still bonding to the selected
        /// device -- before steps 3/4 ever run. The device picker's issue sheet uses this context
        /// for a bond failure and for a scan failure alike. Behaves exactly like `.connect`
        /// everywhere except `.deviceLocked`'s message, so the two contexts' copy is identical in
        /// every other case.
        case pairing
        /// The Ledger sign sheet.
        case sign
    }

    /// The sheet's one button, or none.
    enum PrimaryAction: Equatable, Sendable {
        case tryAgain, openSettings, goToAccount, close, pairLedger, none
    }

    /// How long a scan may run without finding any Ledger before `.noDevicesFound` is shown.
    static let noDevicesFoundTimeout: Duration = .seconds(30)

    /// How long the user's approval on the device may run before a flow gives up waiting for it:
    /// `AddLedgerHWWalletStore.connectDeviceTapped`'s whole connect-then-pair effect, and
    /// `LedgerSigningStore`'s connect effect (the on-device "Open Zcash?" prompt) -- never the
    /// on-device transaction review itself, which has no cap.
    static let approvalTimeout: Duration = .seconds(300)

    /// One child task's outcome from `racingApprovalTimeout`: `work` finished on its own, the cap
    /// won first, or the caller's own task was cancelled while the race was still running.
    enum ApprovalRace<Success: Sendable>: Sendable {
        case completed(Success)
        case timedOut
        /// MOB-2020: distinct from `.timedOut` -- a cancelled wait is not a timed-out
        /// one, and a caller must not run its time-cap cleanup (disconnect, a "Disconnected" send)
        /// for what was really a cancel, e.g. the user cancelling mid-approval-wait.
        case cancelled
    }

    /// Races `work` against `approvalTimeout` on `clock`, sibling child tasks of one task group --
    /// the same shape `AddLedgerHWWalletStore.startScanning` already uses for its no-devices timer.
    /// Whichever finishes first cancels the other, so the caller's own effect cancellation cancels
    /// both. `work` must report its own outcome through its return value rather than by sending a
    /// terminal action itself: once the cap wins, `work`'s task is only cancelled, not stopped
    /// synchronously, so a send from its losing side could still land after the timeout's own send
    /// already has, overwriting it.
    ///
    /// MOB-2020: cancelling the CALLER's task (e.g. `LedgerSigning`'s `.connect`
    /// effect, torn down by Cancel Transaction) cancels both children at once, and `work` is free
    /// to catch that cancellation and still "complete" on its own terms (e.g. `.connect`'s own
    /// `do`/`catch` around `ledgerClient.connect` turns a `CancellationError` into a completed
    /// `.failed(...)`) -- so which child `group.next()` picks up first is a genuine race, not
    /// something `work`'s own behaviour can be relied on to settle. The caller's own
    /// `Task.isCancelled`, checked once the race has settled, is what actually tells a cancel apart
    /// from a real timeout or a real completion.
    static func racingApprovalTimeout<Success: Sendable>(
        clock: any Clock<Duration>,
        work: @escaping @Sendable () async -> Success
    ) async -> ApprovalRace<Success> {
        await withTaskGroup(of: ApprovalRace<Success>.self) { group in
            group.addTask { .completed(await work()) }
            group.addTask {
                do {
                    try await clock.sleep(for: approvalTimeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let outcome = await group.next() ?? .timedOut
            group.cancelAll()
            return Task.isCancelled ? .cancelled : outcome
        }
    }

    /// Classifies a Ledger failure by its `ZcashError`/`LedgerClientError` case only, never by
    /// message text, for the screen showing it in `context`. Never produces `.accountAlreadyAdded`;
    /// `LedgerAccountCollision` classifies import collisions itself.
    ///
    /// MOB-2020 (Android aac01e65): `.pairing` applies only to step 2's `LedgerClient.bond` --
    /// the phone was still bonding to the device, before any command reached it -- never to step
    /// 3, step 4 or signing, which all pass `.connect`/`.sign` since enrollment's bonding happens
    /// once, on step 2, before any of them run. `ledgerDeviceNotFound`, `ledgerBluetoothConnectionFailed`
    /// and `ledgerTimeout` read as `.pairingFailed` only in `.pairing`; every other case (the same
    /// three kinds once bonded, or any context while signing) reads as `.disconnected`, the device
    /// having been reachable at some point. `ledgerBluetoothPairingRefused` is always
    /// `.pairingFailed` regardless of context -- the one refusal the OS-level Bluetooth pairing
    /// dialog itself can raise.
    init(_ error: Error, in context: Context) {
        switch error {
        case ZcashError.ledgerBluetoothUnauthorized:
            self = .bluetoothUnauthorized
        case ZcashError.ledgerBluetoothPoweredOff:
            self = .bluetoothOff
        case ZcashError.ledgerBluetoothUnsupported:
            self = .bluetoothUnsupported
        case ZcashError.ledgerWrongApp(0):
            // Status word 0 is the SDK's sentinel for a timed-out app switch -- neither
            // `LedgerErrors.swift`'s FFI fallback nor `LedgerZcashApp`'s app-switch poll ever
            // throws it for a real reply, since no device sends a genuine 0x0000 status word.
            // The device is unlocked, just too slow to reconnect, so this reads as a disconnect
            // rather than a lock.
            self = .disconnected
        case ZcashError.ledgerWrongApp, ZcashError.ledgerDeviceRefused(_, true):
            // `ledgerWrongApp` (carrying a real status word) and a transient device refusal
            // (such as a locked device) both clear on their own once the user unlocks the
            // device or opens the app, so they share copy telling the user to do exactly that.
            self = .deviceLocked
        case ZcashError.ledgerBluetoothPairingRefused:
            self = .pairingFailed
        case ZcashError.ledgerAppNotInstalled:
            self = .appNotInstalled
        case ZcashError.ledgerAppOpenRejected:
            self = .openAppRejected
        case ZcashError.ledgerUserRejected:
            self = .requestRejected
        case ZcashError.ledgerDeviceNotFound, ZcashError.ledgerBluetoothConnectionFailed, ZcashError.ledgerTimeout:
            self = context == .pairing ? .pairingFailed : .disconnected
        case ZcashError.ledgerBluetoothDisconnected,
            ZcashError.ledgerTransportClosed,
            ZcashError.ledgerTransportFailed,
            // A later connect() to the same device displaced this one. Not restartable on its
            // own -- reconnecting automatically would just displace whichever connection
            // replaced it in turn -- so it reads the same as any other lost connection: a
            // user-tapped retry scans and connects fresh.
            ZcashError.ledgerTransportReplaced,
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
            switch context {
            case .connect, .pairing: return String(localizable: .ledgerIssueOpenAppRejectedTitle)
            case .sign: return String(localizable: .ledgerIssueOpenAppRejectedSignTitle)
            }
        case .requestRejected:
            switch context {
            case .connect, .pairing: return String(localizable: .ledgerIssueRequestRejectedTitle)
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
            switch context {
            case .connect, .sign: return String(localizable: .ledgerIssueDeviceLockedMessage)
            case .pairing: return String(localizable: .ledgerIssueDeviceLockedPairingMessage)
            }
        case .pairingFailed:
            return String(localizable: .ledgerIssuePairingFailedMessage)
        case .appNotInstalled:
            return String(localizable: .ledgerIssueAppNotInstalledMessage)
        case .openAppRejected:
            switch context {
            case .connect, .pairing: return String(localizable: .ledgerIssueOpenAppRejectedMessage)
            case .sign: return String(localizable: .ledgerIssueOpenAppRejectedSignMessage)
            }
        case .requestRejected:
            switch context {
            case .connect, .pairing: return String(localizable: .ledgerIssueRequestRejectedMessage)
            case .sign: return String(localizable: .ledgerIssueRequestRejectedSignMessage)
            }
        case .disconnected:
            switch context {
            case .connect, .pairing: return String(localizable: .ledgerIssueDisconnectedMessage)
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
            case .connect, .pairing: return String(localizable: .ledgerIssueUnknownMessage)
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
            return context != .sign ? .close : .none
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
            return context != .sign ? .goToAccount : .none
        case .appTooOld:
            return .tryAgain
        case .derivationBudgetExhausted:
            return .tryAgain
        case .deviceMismatch:
            return .tryAgain
        case .notPaired:
            // MOB-2020 (Android e36fedb2/ebc98b38): the sign sheet offers Pair Ledger; the
            // connect flow never shows `.notPaired` in the first place (its own picker/approve
            // screens fail with a different issue before an account would ever exist to report
            // this one about), so `.connect` keeps `.none`.
            return context == .sign ? .pairLedger : .none
        case .transactionNotSignable:
            return context != .sign ? .close : .none
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
        case .pairLedger: return String(localizable: .ledgerIssueNotPairedCta)
        case .none: return nil
        }
    }

    /// `true` when a retry in `context` must scan and connect again, rather than repeat the
    /// request on the connection that is still open. A device refusal (`.deviceLocked`,
    /// `.requestRejected`, `.derivationBudgetExhausted` or `.transactionNotSignable`) leaves the
    /// transport usable for another attempt in `.connect`, where every retry reconnects anyway
    /// once a device is selected; `.accountAlreadyAdded` and `.notPaired` need no retry at all.
    /// While signing, though, `.deviceLocked` and `.derivationBudgetExhausted` need a fresh
    /// connection too: the device has to be unlocked, switched to the Zcash app, or have that app
    /// restarted, and only a fresh `LedgerSession.connect` runs the open-Zcash-app step again.
    /// Everything else needs a fresh scan and connection in both contexts: the transport is gone,
    /// or a different or restarted device must be connected (`.deviceMismatch`, `.appTooOld`
    /// after the update, and `.unknown`, where a clean reconnect is the safe retry).
    func retryNeedsNewConnection(in context: Context) -> Bool {
        switch self {
        case .bluetoothUnauthorized, .bluetoothOff, .bluetoothUnsupported, .noDevicesFound,
            .pairingFailed, .appNotInstalled, .openAppRejected, .disconnected, .appTooOld, .deviceMismatch, .unknown:
            return true
        case .deviceLocked, .derivationBudgetExhausted:
            return context == .sign
        case .requestRejected, .accountAlreadyAdded, .notPaired, .transactionNotSignable:
            return false
        }
    }
}
