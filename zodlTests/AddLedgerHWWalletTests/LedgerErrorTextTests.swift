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

    @Test func userRejectedMapsToUserRejected() {
        #expect(LedgerErrorText.message(for: ZcashError.ledgerUserRejected) == String(localizable: .ledgerErrorUserRejected))
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

    @Test func notConnectedMapsToConnectionLost() {
        #expect(LedgerErrorText.message(for: LedgerClientError.notConnected) == String(localizable: .ledgerErrorConnectionLost))
        #expect(LedgerErrorText.isConnectionLost(LedgerClientError.notConnected))
    }

    // MARK: - Generic fallback

    @Test func remainingLedgerCasesMapToGeneric() {
        let genericErrors: [Error] = [
            ZcashError.ledgerDerivationBudgetExhausted,
            ZcashError.ledgerDeviceRefused(0x6901, true),
            ZcashError.ledgerMalformedReply("bad reply"),
            ZcashError.ledgerInternal("internal"),
            ZcashError.ledgerInvalidInput("input"),
            ZcashError.ledgerCapsMismatch("caps"),
            ZcashError.ledgerTransactionNotSignable("not signable"),
            ZcashError.ledgerTransportFailed(UnrelatedError()),
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
