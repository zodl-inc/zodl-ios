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

@Suite struct LedgerIssueTests {
    private struct UnrelatedError: Error {}

    // MARK: - init(_:)

    // `ZcashError` is not `Sendable`, so this drives a local (Error, LedgerIssue) table with a
    // plain loop instead of `@Test(arguments:)`.
    @Test func classifiesEveryLedgerErrorCase() {
        let cases: [(Error, LedgerIssue)] = [
            (ZcashError.ledgerBluetoothUnauthorized, .bluetoothUnauthorized),
            (ZcashError.ledgerBluetoothPoweredOff, .bluetoothOff),
            (ZcashError.ledgerBluetoothUnsupported, .bluetoothUnsupported),
            (ZcashError.ledgerDeviceNotFound, .noDevicesFound),
            (ZcashError.ledgerWrongApp(0), .disconnected),
            (ZcashError.ledgerWrongApp(0x6E00), .deviceLocked),
            (ZcashError.ledgerWrongApp(0x6E01), .deviceLocked),
            (ZcashError.ledgerDeviceRefused(0x6985, true), .deviceLocked),
            (ZcashError.ledgerBluetoothPairingRefused, .pairingFailed),
            (ZcashError.ledgerAppNotInstalled, .appNotInstalled),
            (ZcashError.ledgerAppOpenRejected, .openAppRejected),
            (ZcashError.ledgerUserRejected, .requestRejected),
            (ZcashError.ledgerBluetoothDisconnected, .disconnected),
            (ZcashError.ledgerTimeout, .disconnected),
            (ZcashError.ledgerTransportClosed, .disconnected),
            (ZcashError.ledgerTransportFailed(UnrelatedError()), .disconnected),
            (ZcashError.ledgerBluetoothConnectionFailed(nil), .disconnected),
            (LedgerClientError.notConnected, .disconnected),
            (ZcashError.ledgerAppTooOld("3.5.0"), .appTooOld),
            (ZcashError.ledgerDerivationBudgetExhausted, .derivationBudgetExhausted),
            (ZcashError.ledgerDeviceMismatch, .deviceMismatch),
            (ZcashError.ledgerTransactionNotSignable("some SDK reason"), .transactionNotSignable),
            (ZcashError.ledgerCapsMismatch("some SDK reason"), .transactionNotSignable),
            (ZcashError.ledgerDeviceRefused(0x6985, false), .unknown),
            (ZcashError.ledgerMalformedReply("bad reply"), .unknown),
            (ZcashError.ledgerInvalidInput("bad input"), .unknown),
            (ZcashError.ledgerInternal("internal"), .unknown),
            (URLError(.badURL), .unknown)
        ]

        for (error, expected) in cases {
            #expect(LedgerIssue(error) == expected, "\(error) should classify as \(expected)")
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
}
