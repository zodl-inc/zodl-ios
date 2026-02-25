//
//  SettingsTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 21.07.2022.
//

import XCTest
import Utils
import ComposableArchitecture
import LogsHandler
import Models
import WalletStorage
import RecoveryPhraseDisplay
import Settings
import ExportLogs
import SupportDataGenerator
import Pasteboard
@testable import secant_testnet

@MainActor
class SettingsTests: XCTestCase {
    func testBackupWalletAccessRequest_AuthenticateSuccessPath() async throws {
        let mnemonic =
            """
            still champion voice habit trend flight \
            survey between bitter process artefact blind \
            carbon truly provide dizzy crush flush \
            breeze blouse charge solid fish spread
            """
        
        let mockedWalletStorage = WalletStorageClient(
            importWallet: { _, _, _, _ in
                throw WalletStorage.WalletStorageError.alreadyImported
            },
            exportWallet: {
                StoredWallet(
                    language: .english,
                    seedPhrase: SeedPhrase(mnemonic),
                    version: 1,
                    hasUserPassedPhraseBackupTest: true
                )
            },
            areKeysPresent: {
                throw WalletStorage.WalletStorageError.uninitializedWallet
            },
            updateBirthday: { _ in
                throw WalletStorage.KeychainError.encoding
            },
            markUserPassedPhraseBackupTest: { _ in
                throw WalletStorage.KeychainError.encoding
            },
            resetZashi: { },
            importAddressBookEncryptionKeys: { _ in },
            exportAddressBookEncryptionKeys: { .empty }
        )
        
        let store = TestStore(
            initialState: AdvancedSettings.State(
                currencyConversionSetupState: .initial,
                deleteWalletState: .initial,
                phraseDisplayState: RecoveryPhraseDisplay.State(phrase: nil),
                privateDataConsentState: .initial,
                serverSetupState: .initial
            )
        ) {
            AdvancedSettings()
        }

        store.dependencies.localAuthentication = .mockAuthenticationSucceeded
        store.dependencies.mnemonic = .noOp
        store.dependencies.mnemonic.asWords = { _ in mnemonic.components(separatedBy: " ") }
        store.dependencies.walletStorage = mockedWalletStorage

        await store.send(.protectedAccessRequest(.backupPhrase))
        
        await store.receive(.updateDestination(.backupPhrase)) { state in
            state.destination = .backupPhrase
            state.phraseDisplayState.showBackButton = true
        }
    }
    
    func testBackupWalletAccessRequest_AuthenticateFailedPath() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            AdvancedSettings()
        }

        store.dependencies.localAuthentication = .mockAuthenticationFailed

        await store.send(.protectedAccessRequest(.backupPhrase))
        
        await store.finish()
    }

    func testSupportDataGeneratorSubject() async throws {
        let generator = SupportDataGenerator.generate()
        
        XCTAssertEqual(generator.subject, "Zashi")
    }

    func testSupportDataGeneratorEmail() async throws {
        let generator = SupportDataGenerator.generate()
        
        XCTAssertEqual(generator.toAddress, "support@zodl.com")
    }
}
