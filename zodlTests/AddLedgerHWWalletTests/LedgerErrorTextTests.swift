//
//  LedgerErrorTextTests.swift
//  zodlTests
//
//  Every ZcashError ledger case LedgerErrorText.message(for:) maps, plus isConnectionLost
//  (Features/AddLedgerHWWallet/LedgerErrorText.swift).
//

import Testing
import Foundation
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct LedgerErrorTextTests {
    private struct UnrelatedError: Error {}

    // MARK: - Explicitly mapped cases

    @Test func bluetoothPoweredOffMapsToBluetoothOff() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerBluetoothPoweredOff) == String(localizable: .ledgerErrorBluetoothOff))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerBluetoothPoweredOff))
    }

    @Test func bluetoothUnauthorizedMapsToBluetoothUnauthorized() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerBluetoothUnauthorized) == String(localizable: .ledgerErrorBluetoothUnauthorized))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerBluetoothUnauthorized))
    }

    @Test func bluetoothUnsupportedMapsToBluetoothUnsupported() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerBluetoothUnsupported) == String(localizable: .ledgerErrorBluetoothUnsupported))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerBluetoothUnsupported))
    }

    @Test func wrongAppMapsToWrongApp() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerWrongApp(0x6E00)) == String(localizable: .ledgerErrorWrongApp))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerWrongApp(0x6E00)))
    }

    @Test func appTooOldMapsToAppTooOld() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerAppTooOld("3.5.0")) == String(localizable: .ledgerErrorAppTooOld))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerAppTooOld("3.5.0")))
    }

    // MOB-2020 Phase 3.2: `.ledgerUserRejected` now maps to the vendor-neutral signing copy
    // (`ledger.error.rejected`), not the old pairing-specific `ledger.error.userRejected` --
    // see `LedgerErrorText.message(for:)`'s comment on this case.
    @Test func userRejectedMapsToRejected() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerUserRejected) == String(localizable: .ledgerErrorRejected))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerUserRejected))
    }

    @Test func pairingRefusedMapsToPairingRefused() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerBluetoothPairingRefused) == String(localizable: .ledgerErrorPairingRefused))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerBluetoothPairingRefused))
    }

    @Test func deviceMismatchMapsToDeviceMismatch() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerDeviceMismatch) == String(localizable: .ledgerErrorDeviceMismatch))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerDeviceMismatch))
    }

    // MARK: - Signing cases (MOB-2020 Phase 3.2)

    @Test func transactionNotSignableMapsToNotSignable() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerTransactionNotSignable("some SDK reason")) == String(localizable: .ledgerErrorNotSignable))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerTransactionNotSignable("some SDK reason")))
        // The SDK's reason text must never reach the user -- only the generic copy.
        #expect(!LedgerErrorText.message(for: ZcashError.ledgerTransactionNotSignable("some SDK reason")).contains("some SDK reason"))
    }

    @Test func derivationBudgetExhaustedMapsToDerivationBudget() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerDerivationBudgetExhausted) == String(localizable: .ledgerErrorDerivationBudget))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerDerivationBudgetExhausted))
    }

    @Test func capsMismatchMapsToNotSignable() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerCapsMismatch("some SDK reason")) == String(localizable: .ledgerErrorNotSignable))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerCapsMismatch("some SDK reason")))
        #expect(!LedgerErrorText.message(for: ZcashError.ledgerCapsMismatch("some SDK reason")).contains("some SDK reason"))
    }

    // MARK: - Connection-lost transport failures

    @Test func transportClosedMapsToConnectionLost() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerTransportClosed) == String(localizable: .ledgerErrorConnectionLost))
        #expect(LedgerErrorText.isConnectionLost(ZcashError.ledgerTransportClosed))
    }

    @Test func bluetoothDisconnectedMapsToConnectionLost() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerBluetoothDisconnected) == String(localizable: .ledgerErrorConnectionLost))
        #expect(LedgerErrorText.isConnectionLost(ZcashError.ledgerBluetoothDisconnected))
    }

    @Test func timeoutMapsToConnectionLost() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerTimeout) == String(localizable: .ledgerErrorConnectionLost))
        #expect(LedgerErrorText.isConnectionLost(ZcashError.ledgerTimeout))
    }

    @Test func bluetoothConnectionFailedMapsToConnectionLost() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerBluetoothConnectionFailed(nil)) == String(localizable: .ledgerErrorConnectionLost))
        #expect(LedgerErrorText.isConnectionLost(ZcashError.ledgerBluetoothConnectionFailed(nil)))
    }

    @Test func transportFailedMapsToConnectionLost() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerTransportFailed(UnrelatedError())) == String(localizable: .ledgerErrorConnectionLost))
        #expect(LedgerErrorText.isConnectionLost(ZcashError.ledgerTransportFailed(UnrelatedError())))
    }

    @Test func notConnectedMapsToConnectionLost() {
        #expect(LedgerErrorText.message(for: LedgerClientError.notConnected) == String(localizable: .ledgerErrorConnectionLost))
        #expect(LedgerErrorText.isConnectionLost(LedgerClientError.notConnected))
    }

    // MARK: - isRestartable

    @Test func userRejectedIsRestartableButNotConnectionLost() {
        #expect(LedgerErrorText.isRestartable(ZcashError.ledgerUserRejected))
        #expect(!LedgerErrorText.isConnectionLost(ZcashError.ledgerUserRejected))
    }

    @Test func transportClosedIsRestartableAndConnectionLost() {
        #expect(LedgerErrorText.isRestartable(ZcashError.ledgerTransportClosed))
        #expect(LedgerErrorText.isConnectionLost(ZcashError.ledgerTransportClosed))
    }

    // MARK: - Generic fallback

    @Test func remainingLedgerCasesMapToGeneric() {
        let genericErrors: [Error] = [
            ZcashError.ledgerDeviceRefused(0x6901, true),
            ZcashError.ledgerMalformedReply("bad reply"),
            ZcashError.ledgerInternal("internal"),
            ZcashError.ledgerInvalidInput("input"),
            ZcashError.ledgerDeviceNotFound
        ]

        for error in genericErrors {
            #expect(LedgerErrorText.message(for: error) == String(localizable: .ledgerErrorGeneric))
            #expect(!LedgerErrorText.isConnectionLost(error))
        }
    }

    @Test func anUnrelatedErrorMapsToGeneric() {
        #expect(LedgerErrorText.message(for: UnrelatedError()) == String(localizable: .ledgerErrorGeneric))
        #expect(!LedgerErrorText.isConnectionLost(UnrelatedError()))
    }
}
