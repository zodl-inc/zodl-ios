//
//  WalletStorageTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 10.03.2022.
//

import XCTest
@preconcurrency import MnemonicSwift
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

extension WalletStorage.WalletStorageError {
    var debugValue: String {
        switch self {
        case .alreadyImported: return "alreadyImported"
        case .uninitializedWallet: return "uninitializedWallet"
        case .storageError: return "storageError"
        case .unsupportedVersion: return "unsupportedVersion"
        case .unsupportedLanguage: return "unsupportedLanguage"
        }
    }
}

class WalletStorageTests: XCTestCase {
    let birthday = BlockHeight(12345678)
    let seedPhrase = "one two three"
    let language = MnemonicLanguageType.english
    var storage = WalletStorage(secItem: .live)
    
    override func setUp() {
        super.setUp()
        storage.zcashStoredWalletPrefix = "test_walletStorage_"
        deleteData(forKey: WalletStorage.Constants.zcashStoredWallet)
    }
    
    func testWalletStoredSuccessfully() throws {
        do {
            try storage.importWallet(bip39: seedPhrase, birthday: birthday)
            guard let data = data(forKey: WalletStorage.Constants.zcashStoredWallet) else {
                return XCTFail("Keychain: no data found for key: `zcashStoredWallet`.")
            }
            
            guard let walletReceived = try storage.decode(json: data, as: StoredWallet.self) else {
                return XCTFail("Keychain: `walletReceived` can't be decoded.")
            }
            
            XCTAssertEqual(birthday, walletReceived.birthday?.value(), "Keychain: stored birthday and retrieved one must be the same.")
            XCTAssertEqual(seedPhrase, walletReceived.seedPhrase.value(), "Keychain: stored seed phrase and retrieved one must be the same.")
        } catch let err {
            XCTFail("Keychain: no error is expected for `testWalletStoredSuccessfully` but received. \(err)")
        }
    }

    func testWalletDuplicate() throws {
        // the test must fail for the 2nd call of importWallet
        var isAfterFirstCall = false
        do {
            try storage.importWallet(bip39: seedPhrase, birthday: birthday)
            isAfterFirstCall = true
            try storage.importWallet(bip39: seedPhrase, birthday: birthday)
            
            XCTFail("Keychain: `testRecoveryPhraseDuplicate` is expected to throw a `duplicate` error but passed instead.")
        } catch {
            XCTAssertTrue(isAfterFirstCall)
            
            guard let error = error as? WalletStorage.WalletStorageError else {
                XCTFail("Keychain: the error is expected to be WalletStorageError but it's \(error).")
                
                return
            }
            
            XCTAssertEqual(
                error.debugValue,
                WalletStorage.WalletStorageError.alreadyImported.debugValue,
                "Keychain: error must be .alreadyImported but it's \(error)."
            )
        }
    }

    func testUninitializedWallet() throws {
        do {
            _ = try storage.exportWallet()
            
            XCTFail("Keychain: `testUninitializedWallet` should fail but received some wallet.")
        } catch {
            guard let error = error as? WalletStorage.WalletStorageError else {
                return XCTFail("Keychain: the error is expected to be WalletStorageError but it's \(error).")
            }

            XCTAssertEqual(
                error.debugValue,
                WalletStorage.WalletStorageError.uninitializedWallet.debugValue,
                "Keychain: error must be .uninitializedWallet"
            )
        }
    }
    
    func testDeleteWallet() throws {
        do {
            let wallet = StoredWallet(
                language: language,
                seedPhrase: SeedPhrase(seedPhrase),
                version: WalletStorage.Constants.zcashKeychainVersion,
                birthday: Birthday(birthday),
                hasUserPassedPhraseBackupTest: false
            )
            
            guard let walletData = try storage.encode(object: wallet) else {
                return XCTFail("`testDeleteWallet` encoding `walletData` failed.")
            }

            do {
                try setData(walletData, forKey: WalletStorage.Constants.zcashStoredWallet)
            } catch {
                XCTFail("`testDeleteWallet` storing `walletData` failed.")
            }

            storage.resetZashi()
            
            let data = data(forKey: WalletStorage.Constants.zcashStoredWallet)
            
            XCTAssertEqual(data, nil, "Keychain: keychain is expected to not find anything for key `zcashStoredWallet` but received some data.")
        } catch {
            XCTFail("`testDeleteWallet` no error is expected.")
        }
    }
    
    func testUpdateBirthdayOverNil() throws {
        let wallet = StoredWallet(
            language: language,
            seedPhrase: SeedPhrase(seedPhrase),
            version: WalletStorage.Constants.zcashKeychainVersion,
            birthday: nil,
            hasUserPassedPhraseBackupTest: false
        )
        
        guard let walletData = try storage.encode(object: wallet) else {
            return XCTFail("`testUpdateBirthdayOverNil` encoding `walletData` failed.")
        }

        do {
            try setData(walletData, forKey: WalletStorage.Constants.zcashStoredWallet)
        } catch {
            XCTFail("`testUpdateBirthdayOverNil` storing `walletData` failed.")
        }

        do {
            try storage.updateBirthday(birthday)
            guard let data = data(forKey: WalletStorage.Constants.zcashStoredWallet) else {
                return XCTFail("Keychain: no data found for key: `zcashStoredWallet`.")
            }
            
            guard let walletReceived = try storage.decode(json: data, as: StoredWallet.self) else {
                return XCTFail("Keychain: `walletReceived` can't be decoded.")
            }
            
            XCTAssertEqual(birthday, walletReceived.birthday?.value(), "Keychain: stored birthday and retrieved one must be the same.")
            XCTAssertEqual(seedPhrase, walletReceived.seedPhrase.value(), "Keychain: stored seed phrase and retrieved one must be the same.")
        } catch let err {
            XCTFail("Keychain: no error is expected for `testUpdateBirthdayOverNil` but received. \(err)")
        }
    }

    func testUpdateBirthdayOverSomeBirthday() throws {
        let wallet = StoredWallet(
            language: language,
            seedPhrase: SeedPhrase(seedPhrase),
            version: WalletStorage.Constants.zcashKeychainVersion,
            birthday: Birthday(birthday),
            hasUserPassedPhraseBackupTest: false
        )
        let newBirthday = BlockHeight(87654321)
        
        guard let walletData = try storage.encode(object: wallet) else {
            return XCTFail("`testUpdateBirthdayOverSomeBirthday` encoding `walletData` failed.")
        }

        do {
            try setData(walletData, forKey: WalletStorage.Constants.zcashStoredWallet)
        } catch {
            XCTFail("`testUpdateBirthdayOverSomeBirthday` storing `walletData` failed.")
        }

        do {
            try storage.updateBirthday(newBirthday)
            guard let data = data(forKey: WalletStorage.Constants.zcashStoredWallet) else {
                return XCTFail("Keychain: no data found for key: `zcashStoredWallet`.")
            }
            
            guard let walletReceived = try storage.decode(json: data, as: StoredWallet.self) else {
                return XCTFail("Keychain: `walletReceived` can't be decoded.")
            }
            
            XCTAssertEqual(newBirthday, walletReceived.birthday?.value(), "Keychain: stored birthday and retrieved one must be the same.")
            XCTAssertEqual(seedPhrase, walletReceived.seedPhrase.value(), "Keychain: stored seed phrase and retrieved one must be the same.")
        } catch let err {
            XCTFail("Keychain: no error is expected for `testUpdateBirthdayOverNil` but received. \(err)")
        }
    }
    
    func testMarkUserPassedPhraseBackupTest() throws {
        let wallet = StoredWallet(
            language: language,
            seedPhrase: SeedPhrase(seedPhrase),
            version: WalletStorage.Constants.zcashKeychainVersion,
            birthday: Birthday(birthday),
            hasUserPassedPhraseBackupTest: false
        )
        guard let walletData = try storage.encode(object: wallet) else {
            return XCTFail("`testMarkUserPassedPhraseBackupTest` encoding `walletData` failed.")
        }

        do {
            try setData(walletData, forKey: WalletStorage.Constants.zcashStoredWallet)
        } catch {
            XCTFail("`testMarkUserPassedPhraseBackupTest` storing `walletData` failed.")
        }

        do {
            try storage.markUserPassedPhraseBackupTest()
            guard let data = data(forKey: WalletStorage.Constants.zcashStoredWallet) else {
                return XCTFail("Keychain: no data found for key: `zcashStoredWallet`.")
            }
            
            guard let walletReceived = try storage.decode(json: data, as: StoredWallet.self) else {
                return XCTFail("Keychain: `walletReceived` can't be decoded.")
            }
            
            XCTAssertTrue(walletReceived.hasUserPassedPhraseBackupTest, "Keychain: `hasUserPassedPhraseBackupTest` must be set to true.")
            XCTAssertEqual(seedPhrase, walletReceived.seedPhrase.value(), "Keychain: stored seed phrase and retrieved one must be the same.")
        } catch let err {
            XCTFail("Keychain: no error is expected for `testMarkUserPassedPhraseBackupTest` but received. \(err)")
        }
    }
    
    func testUnsupportedVersion() throws {
        let wallet = StoredWallet(
            language: language,
            seedPhrase: SeedPhrase(seedPhrase),
            /// older version
            version: WalletStorage.Constants.zcashKeychainVersion - 1,
            birthday: Birthday(birthday),
            hasUserPassedPhraseBackupTest: false
        )
        
        guard let walletData = try storage.encode(object: wallet) else {
            return XCTFail("`testUnsupportedVersion` encoding `walletData` failed.")
        }

        do {
            try setData(walletData, forKey: WalletStorage.Constants.zcashStoredWallet)
        } catch {
            XCTFail("`testUnsupportedVersion` storing `walletData` failed.")
        }
        
        do {
            _ = try storage.exportWallet()
            
            XCTFail("Keychain: `testUnsupportedVersion` should fail but received some wallet with correct version.")
        } catch WalletStorage.WalletStorageError.unsupportedVersion(let version) {
            XCTAssertEqual(
                version + 1,
                WalletStorage.Constants.zcashKeychainVersion,
                "Keychain: version should be \(WalletStorage.Constants.zcashKeychainVersion) but stored version is \(version)"
            )
        } catch {
            XCTFail("Keychain: `testUnsupportedVersion` should fail with `unsupportedVersion` error but threw \(error).")
        }
    }
    
    func testUnsupportedLanguage() throws {
        do {
            try storage.importWallet(bip39: seedPhrase, birthday: birthday, language: .chinese)
            
            XCTFail("Keychain: `testUnsupportedLanguage` should fail but imported chinese language.")
        } catch WalletStorage.WalletStorageError.unsupportedLanguage(let languageToStore) {
            XCTAssertEqual(
                MnemonicLanguageType.chinese,
                languageToStore,
                "Keychain: language should be english but received \(languageToStore)"
            )
        } catch {
            XCTFail("Keychain: `testUnsupportedLanguage` should fail with `unsupportedLanguage` error but threw \(error).")
        }
    }
}

// MARK: - Misc

/// The followings methods are here purposely to not rely on `WalletStorage` in order to test functionality of JUST ONE method at a time
private extension WalletStorageTests {
    private func setData(
        account: String = "",
        _ data: Data,
        forKey: String
    ) throws {
        var query = storage.baseQuery(forAccount: account, andKey: forKey)
        query[kSecValueData as String] = data as AnyObject

        // TODO: [#231] - Mock the Keychain and write unit tests (https://github.com/Electric-Coin-Company/zashi-ios/issues/231)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func data(
        forKey: String,
        account: String = ""
    ) -> Data? {
        let query = storage.restoreQuery(forAccount: account, andKey: forKey)

        var result: AnyObject?
        // TODO: [#231] - Mock the Keychain and write unit tests (https://github.com/Electric-Coin-Company/zashi-ios/issues/231)
        _ = SecItemCopyMatching(query as CFDictionary, &result)
        
        return result as? Data
    }
    
    @discardableResult
    private func deleteData(
        forKey: String,
        account: String = ""
    ) -> Bool {
        let query = storage.baseQuery(forAccount: account, andKey: forKey)

        // TODO: [#231] - Mock the Keychain and write unit tests (https://github.com/Electric-Coin-Company/zashi-ios/issues/231)
        let status = SecItemDelete(query as CFDictionary)

        return status == noErr
    }
    
    func updateData(
        _ data: Data,
        forKey: String,
        account: String = ""
    ) throws {
        let query = storage.baseQuery(forAccount: account, andKey: forKey)
        
        let attributes: [String: AnyObject] = [
            kSecValueData as String: data as AnyObject
        ]

        // TODO: [#231] - Mock the Keychain and write unit tests (https://github.com/Electric-Coin-Company/zashi-ios/issues/231)
        _ = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}
