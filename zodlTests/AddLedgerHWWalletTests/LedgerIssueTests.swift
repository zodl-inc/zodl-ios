//
//  LedgerIssueTests.swift
//  zodlTests
//
//  Covers LedgerIssue's classification of a Ledger failure (init(_:)), its per-context copy and
//  primary action, and retryNeedsNewConnection(in:) (Features/AddLedgerHWWallet/LedgerIssue.swift).
//

import Testing
import Foundation
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// `.timeLimit` is SignalledClock's own backstop (TestSupport/SignalledClock.swift): a wait that
// genuinely never fires is recorded as a failure here instead of hanging the run.
@Suite(.timeLimit(.minutes(1))) struct LedgerIssueTests {
    private struct UnrelatedError: Error {}

    // MARK: - init(_:in:)

    // `ZcashError` is not `Sendable`, so this drives a local table with a plain loop instead of
    // `@Test(arguments:)`. MOB-2020 (Android b013b7c2): each row is checked in three shapes --
    // wrapped in `LedgerBluetoothConnectFailure` while still bonding in `.connect` ("pairing"),
    // unwrapped once the link is up in `.connect` ("connect"), and unwrapped in `.sign` ("sign") --
    // mirroring Android's `LedgerIssueMapperTest` `pairing`/`enrollment`/`signing` columns.
    @Test func classifiesEveryLedgerErrorCase() {
        typealias Row = (name: String, error: Error, pairing: LedgerIssue, connect: LedgerIssue, sign: LedgerIssue)

        // Every column maps this error alike -- the common case, unaffected by the wrap/phase
        // split below.
        func every(_ name: String, _ error: Error, _ issue: LedgerIssue) -> Row {
            (name, error, issue, issue, issue)
        }

        let rows: [Row] = [
            every("bluetoothUnauthorized", ZcashError.ledgerBluetoothUnauthorized, .bluetoothUnauthorized),
            every("bluetoothPoweredOff", ZcashError.ledgerBluetoothPoweredOff, .bluetoothOff),
            every("bluetoothUnsupported", ZcashError.ledgerBluetoothUnsupported, .bluetoothUnsupported),
            // `ledgerDeviceNotFound`, `ledgerTimeout` and `ledgerBluetoothConnectionFailed` now
            // read as `.pairingFailed` only while still bonding; once the link is up, or while
            // signing, the device WAS reachable, so they read as `.disconnected` instead --
            // `ledgerDeviceNotFound` no longer means "no devices" at all (see its doc comment).
            ("deviceNotFound", ZcashError.ledgerDeviceNotFound, .pairingFailed, .disconnected, .disconnected),
            every("wrongAppTimedOut", ZcashError.ledgerWrongApp(0), .disconnected),
            every("wrongAppWithStatusWordA", ZcashError.ledgerWrongApp(0x6E00), .deviceLocked),
            every("wrongAppWithStatusWordB", ZcashError.ledgerWrongApp(0x6E01), .deviceLocked),
            every("deviceRefusedTransient", ZcashError.ledgerDeviceRefused(0x6985, true), .deviceLocked),
            // Always `.pairingFailed`, wrapped or not -- the one refusal the OS-level Bluetooth
            // pairing dialog itself raises.
            every("bluetoothPairingRefused", ZcashError.ledgerBluetoothPairingRefused, .pairingFailed),
            every("appNotInstalled", ZcashError.ledgerAppNotInstalled, .appNotInstalled),
            every("appOpenRejected", ZcashError.ledgerAppOpenRejected, .openAppRejected),
            every("userRejected", ZcashError.ledgerUserRejected, .requestRejected),
            every("bluetoothDisconnected", ZcashError.ledgerBluetoothDisconnected, .disconnected),
            ("timeout", ZcashError.ledgerTimeout, .pairingFailed, .disconnected, .disconnected),
            every("transportClosed", ZcashError.ledgerTransportClosed, .disconnected),
            every("transportFailed", ZcashError.ledgerTransportFailed(UnrelatedError()), .disconnected),
            ("bluetoothConnectionFailed", ZcashError.ledgerBluetoothConnectionFailed(nil), .pairingFailed, .disconnected, .disconnected),
            every("notConnected", LedgerClientError.notConnected, .disconnected),
            every("appTooOld", ZcashError.ledgerAppTooOld("3.5.0"), .appTooOld),
            every("derivationBudgetExhausted", ZcashError.ledgerDerivationBudgetExhausted, .derivationBudgetExhausted),
            every("deviceMismatch", ZcashError.ledgerDeviceMismatch, .deviceMismatch),
            every("transactionNotSignable", ZcashError.ledgerTransactionNotSignable("some SDK reason"), .transactionNotSignable),
            every("capsMismatch", ZcashError.ledgerCapsMismatch("some SDK reason"), .transactionNotSignable),
            every("deviceRefusedPermanent", ZcashError.ledgerDeviceRefused(0x6985, false), .unknown),
            every("malformedReply", ZcashError.ledgerMalformedReply("bad reply"), .unknown),
            every("invalidInput", ZcashError.ledgerInvalidInput("bad input"), .unknown),
            every("internal", ZcashError.ledgerInternal("internal"), .unknown),
            every("nonLedgerError", URLError(.badURL), .unknown)
        ]

        for row in rows {
            let pairing = LedgerIssue(LedgerBluetoothConnectFailure(underlying: row.error), in: .connect)
            let connect = LedgerIssue(row.error, in: .connect)
            let sign = LedgerIssue(row.error, in: .sign)
            #expect(pairing == row.pairing, "\(row.name) while still bonding (.connect, wrapped)")
            #expect(connect == row.connect, "\(row.name) once the link is up (.connect, unwrapped)")
            #expect(sign == row.sign, "\(row.name) while signing (.sign)")
        }
    }

    // MARK: - Copy across contexts

    @Test func connectAndSignCopyDifferOnlyWhereTheContextChangesTheMeaning() {
        // Arrays, not Sets: LedgerIssue is deliberately not Hashable, only Equatable.
        let contextVaryingTitle: [LedgerIssue] = [.requestRejected]
        let contextVaryingMessage: [LedgerIssue] = [.requestRejected, .disconnected, .unknown]

        for issue in LedgerIssue.allCases {
            let connectTitle = issue.title(in: .connect)
            let signTitle = issue.title(in: .sign)
            let connectMessage = issue.message(in: .connect)
            let signMessage = issue.message(in: .sign)

            #expect(!connectTitle.isEmpty, "\(issue) .connect title")
            #expect(!signTitle.isEmpty, "\(issue) .sign title")
            #expect(!connectMessage.isEmpty, "\(issue) .connect message")
            #expect(!signMessage.isEmpty, "\(issue) .sign message")

            if contextVaryingTitle.contains(issue) {
                #expect(connectTitle != signTitle, "\(issue) title should differ by context")
            } else {
                #expect(connectTitle == signTitle, "\(issue) title should not differ by context")
            }

            if contextVaryingMessage.contains(issue) {
                #expect(connectMessage != signMessage, "\(issue) message should differ by context")
            } else {
                #expect(connectMessage == signMessage, "\(issue) message should not differ by context")
            }
        }
    }

    // MARK: - The two new states' copy

    // Not Figma states (figmaStatesUseTheirKeys below is Figma-only), so their own small table:
    // both cases share one title and one message across `.connect` and `.sign` (per
    // connectAndSignCopyDifferOnlyWhereTheContextChangesTheMeaning above), sourced from their own
    // catalog keys.
    @Test func appNotInstalledAndOpenAppRejectedUseTheirKeys() {
        let states: [(issue: LedgerIssue, title: String, message: String)] = [
            (.appNotInstalled,
             String(localizable: .ledgerIssueAppNotInstalledTitle),
             String(localizable: .ledgerIssueAppNotInstalledMessage)),
            (.openAppRejected,
             String(localizable: .ledgerIssueOpenAppRejectedTitle),
             String(localizable: .ledgerIssueOpenAppRejectedMessage))
        ]

        for state in states {
            for context in [LedgerIssue.Context.connect, .sign] {
                #expect(state.issue.title(in: context) == state.title, "\(state.issue) \(context) title")
                #expect(state.issue.message(in: context) == state.message, "\(state.issue) \(context) message")
                #expect(state.issue.primaryAction(in: context) == .tryAgain, "\(state.issue) \(context) primary action")
            }
        }
    }

    // MARK: - Figma states

    @Test func figmaStatesUseTheirKeys() {
        let figmaConnectStates: [(issue: LedgerIssue, title: String, message: String, buttonTitle: String)] = [
            (.bluetoothUnauthorized,
             String(localizable: .ledgerIssueBluetoothUnauthorizedTitle),
             String(localizable: .ledgerIssueBluetoothUnauthorizedMessage),
             String(localizable: .ledgerIssueOpenSettings)),
            (.noDevicesFound,
             String(localizable: .ledgerIssueNoDevicesFoundTitle),
             String(localizable: .ledgerIssueNoDevicesFoundMessage),
             String(localizable: .ledgerIssueTryAgain)),
            (.deviceLocked,
             String(localizable: .ledgerIssueDeviceLockedTitle),
             String(localizable: .ledgerIssueDeviceLockedMessage),
             String(localizable: .ledgerIssueTryAgain)),
            (.pairingFailed,
             String(localizable: .ledgerIssuePairingFailedTitle),
             String(localizable: .ledgerIssuePairingFailedMessage),
             String(localizable: .ledgerIssueTryAgain)),
            (.requestRejected,
             String(localizable: .ledgerIssueRequestRejectedTitle),
             String(localizable: .ledgerIssueRequestRejectedMessage),
             String(localizable: .ledgerIssueTryAgain)),
            (.disconnected,
             String(localizable: .ledgerIssueDisconnectedTitle),
             String(localizable: .ledgerIssueDisconnectedMessage),
             String(localizable: .ledgerIssueTryAgain)),
            (.accountAlreadyAdded,
             String(localizable: .ledgerIssueAccountAlreadyAddedTitle),
             String(localizable: .ledgerIssueAccountAlreadyAddedMessage),
             String(localizable: .ledgerIssueGoToAccount))
        ]

        #expect(figmaConnectStates.count == 7)
        for state in figmaConnectStates {
            #expect(state.issue.title(in: .connect) == state.title, "\(state.issue) title")
            #expect(state.issue.message(in: .connect) == state.message, "\(state.issue) message")
            #expect(state.issue.primaryActionTitle(in: .connect) == state.buttonTitle, "\(state.issue) button title")
        }
    }

    // MARK: - Table-driven checks

    @Test func primaryActionsMatchTheTable() {
        typealias Row = (issue: LedgerIssue, connect: LedgerIssue.PrimaryAction, sign: LedgerIssue.PrimaryAction)
        let table: [Row] = [
            (.bluetoothUnauthorized, .openSettings, .openSettings),
            (.bluetoothOff, .tryAgain, .tryAgain),
            (.bluetoothUnsupported, .close, .none),
            (.noDevicesFound, .tryAgain, .tryAgain),
            (.deviceLocked, .tryAgain, .tryAgain),
            (.pairingFailed, .tryAgain, .tryAgain),
            (.appNotInstalled, .tryAgain, .tryAgain),
            (.openAppRejected, .tryAgain, .tryAgain),
            (.requestRejected, .tryAgain, .tryAgain),
            (.disconnected, .tryAgain, .tryAgain),
            (.accountAlreadyAdded, .goToAccount, .none),
            (.appTooOld, .tryAgain, .tryAgain),
            (.derivationBudgetExhausted, .tryAgain, .tryAgain),
            (.deviceMismatch, .tryAgain, .tryAgain),
            (.notPaired, .none, .none),
            (.transactionNotSignable, .close, .none),
            (.unknown, .tryAgain, .tryAgain)
        ]

        #expect(table.count == LedgerIssue.allCases.count)
        for row in table {
            #expect(row.issue.primaryAction(in: .connect) == row.connect, "\(row.issue) .connect")
            #expect(row.issue.primaryAction(in: .sign) == row.sign, "\(row.issue) .sign")
        }
    }

    // MOB-2020: `.deviceLocked` and `.derivationBudgetExhausted` are the only rows where the two
    // contexts differ -- while signing, a fresh connection re-opens the Zcash app; while
    // connecting, every retry reconnects anyway once a device is selected, so the same-link
    // answer from before this commit still holds there.
    @Test func retryNeedsNewConnectionMatchesTheTable() {
        typealias Row = (issue: LedgerIssue, connect: Bool, sign: Bool)
        let table: [Row] = [
            (.bluetoothUnauthorized, true, true),
            (.bluetoothOff, true, true),
            (.bluetoothUnsupported, true, true),
            (.noDevicesFound, true, true),
            (.deviceLocked, false, true),
            (.pairingFailed, true, true),
            (.appNotInstalled, true, true),
            (.openAppRejected, true, true),
            (.requestRejected, false, false),
            (.disconnected, true, true),
            (.accountAlreadyAdded, false, false),
            (.appTooOld, true, true),
            (.derivationBudgetExhausted, false, true),
            (.deviceMismatch, true, true),
            (.notPaired, false, false),
            (.transactionNotSignable, false, false),
            (.unknown, true, true)
        ]

        #expect(table.count == LedgerIssue.allCases.count)
        for row in table {
            #expect(row.issue.retryNeedsNewConnection(in: .connect) == row.connect, "\(row.issue) .connect")
            #expect(row.issue.retryNeedsNewConnection(in: .sign) == row.sign, "\(row.issue) .sign")
        }
    }

    // MARK: - racingApprovalTimeout's .cancelled outcome

    // MOB-2020: without this fix, cancelling the caller's task while `work` was
    // still suspended still read as `.timedOut` -- the timer's own `CancellationError` was
    // swallowed by `try?` -- so a caller ran its time-cap cleanup (disconnect, a "Disconnected"
    // send) for what was really a cancel, e.g. the user cancelling mid-approval-wait.
    @Test func racingApprovalTimeoutReportsCancelledRatherThanTimedOutWhenCancelled() async throws {
        let clock = SignalledClock()
        let workStarted = SignalledRecords<Void>()

        let race = Task {
            await LedgerIssue.racingApprovalTimeout(clock: clock) { () -> Int in
                workStarted.recordCall()
                // Parked exactly like a real connect waiting on the on-device prompt -- must not
                // itself decide the race's outcome; only the enclosing task's own cancellation
                // does.
                try? await Task.sleep(for: .seconds(999))
                return 1
            }
        }

        await workStarted.countReached(1)
        // The timeout timer's sleep is parked (and only then recorded) before cancelling, so the
        // cancel below is guaranteed to land on a settled race, not one still starting.
        await clock.sleepDeadlines.countReached(1)

        race.cancel()
        let outcome = await race.value

        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
    }
}
