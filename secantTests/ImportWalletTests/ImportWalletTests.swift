//
//  ImportWalletTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 25.05.2022.
//

import XCTest
import ComposableArchitecture
@testable import secant_testnet

// swiftlint:disable type_body_length
@MainActor
class ImportWalletTests: XCTestCase {
    func testOnAppear() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            ImportWallet()
        }
        
        await store.send(.onAppear) { state in
            state.maxWordsCount = 24
        }
        
        await store.finish()
    }
    
    func testWordsCount() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            ImportWallet()
        }
        
        store.dependencies.mnemonic = .noOp
        store.dependencies.mnemonic.isValid = { _ in throw "invalid mnemonic" }
        
        let seedPhrase = "one two three"
        
        await store.send(.binding(.set(\.importedSeedPhrase, seedPhrase))) { state in
            state.importedSeedPhrase = seedPhrase
        }

        await store.finish()
    }

    func testMaxWordsInvalidMnemonic() async throws {
        let store = TestStore(
            initialState: ImportWallet.State(maxWordsCount: 24, restoreInfoState: .initial)
        ) {
            ImportWallet()
        }
        
        store.dependencies.mnemonic = .noOp
        store.dependencies.mnemonic.isValid = { _ in throw "invalid mnemonic" }

        let seedPhrase = "a a a a a a a a a a a a a a a a a a a a a a a a".redacted
        
        await store.send(.seedPhraseInputChanged(seedPhrase)) { state in
            state.importedSeedPhrase = seedPhrase
            state.wordsCount = 24
            state.isValidNumberOfWords = true
            state.isValidMnemonic = false
        }
        
        await store.finish()
    }

    func testValidMnemonic() async throws {
        let store = TestStore(
            initialState: ImportWallet.State(maxWordsCount: 24, restoreInfoState: .initial)
        ) {
            ImportWallet()
        }
        
        store.dependencies.mnemonic = .noOp

        let seedPhrase =
            """
            still champion voice habit trend flight \
            survey between bitter process artefact blind \
            carbon truly provide dizzy crush flush \
            breeze blouse charge solid fish spread
            """.redacted
        
        await store.send(.seedPhraseInputChanged(seedPhrase)) { state in
            state.importedSeedPhrase = seedPhrase
            state.wordsCount = 24
            state.isValidNumberOfWords = true
            state.isValidMnemonic = true
        }
        
        await store.finish()
    }
    
    func testInvalidBirthdayHeight_lessThanSaplingActivation() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            ImportWallet()
        }
        
        let birthday = "200000".redacted
        
        await store.send(.birthdayInputChanged(birthday)) { state in
            state.birthdayHeight = birthday
        }
        
        await store.finish()
    }

    func testInvalidBirthdayHeight_invalidInput() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            ImportWallet()
        }
        
        let birthday = "abc".redacted
        
        await store.send(.birthdayInputChanged(birthday)) { state in
            state.birthdayHeight = birthday
        }
        
        await store.finish()
    }

    func testInvalidBirthdayHeight_validInput() async throws {
        let store = TestStore(
            initialState: .initial
        ) {
            ImportWallet()
        }
        
        let birthday = "1700000".redacted
        
        await store.send(.birthdayInputChanged(birthday)) { state in
            state.birthdayHeight = birthday
            state.birthdayHeightValue = RedactableBlockHeight(1_700_000)
        }
        
        await store.finish()
    }
        
    func testFormValidity_validBirthday_invalidMnemonic() async throws {
        let store = TestStore(
            initialState: ImportWallet.State(maxWordsCount: 24, restoreInfoState: .initial)
        ) {
            ImportWallet()
        }

        store.dependencies.mnemonic = .noOp
        store.dependencies.mnemonic.isValid = { _ in throw "invalid mnemonic" }
        
        let birthday = "1700000".redacted
        
        await store.send(.birthdayInputChanged(birthday)) { state in
            state.birthdayHeight = birthday
            state.birthdayHeightValue = RedactableBlockHeight(1_700_000)
        }
        
        let seedPhrase = "a a a a a a a a a a a a a a a a a a a a a a a a".redacted
        
        await store.send(.seedPhraseInputChanged(seedPhrase)) { state in
            state.importedSeedPhrase = seedPhrase
            state.wordsCount = 24
            state.isValidNumberOfWords = true
            state.isValidMnemonic = false
            XCTAssertFalse(
                state.isValidForm,
                "Import Wallet tests: `testFormValidity_validBirthday_validMnemonic` is expected to be false but it is \(state.isValidForm)"
            )
        }
        
        await store.finish()
    }
    
    func testFormValidity_invalidBirthday_invalidMnemonic() async throws {
        let store = TestStore(
            initialState: ImportWallet.State(maxWordsCount: 24, restoreInfoState: .initial)
        ) {
            ImportWallet()
        }
        
        store.dependencies.mnemonic = .noOp
        store.dependencies.mnemonic.isValid = { _ in throw "invalid mnemonic" }

        let birthday = "200000".redacted
        
        await store.send(.birthdayInputChanged(birthday)) { state in
            state.birthdayHeight = birthday
        }
        
        let seedPhrase = "a a a a a a a a a a a a a a a a a a a a a a a a".redacted
        
        await store.send(.seedPhraseInputChanged(seedPhrase)) { state in
            state.importedSeedPhrase = seedPhrase
            state.wordsCount = 24
            state.isValidNumberOfWords = true
            state.isValidMnemonic = false
            XCTAssertFalse(
                state.isValidForm,
                "Import Wallet tests: `testFormValidity_validBirthday_validMnemonic` is expected to be false but it is \(state.isValidForm)"
            )
        }
        
        await store.finish()
    }
    
    func testFormValidity_invalidBirthday_validMnemonic() async throws {
        let store = TestStore(
            initialState: ImportWallet.State(maxWordsCount: 24, restoreInfoState: .initial)
        ) {
            ImportWallet()
        }
        
        store.dependencies.mnemonic = .noOp

        let birthday = "200000".redacted
        
        await store.send(.birthdayInputChanged(birthday)) { state in
            state.birthdayHeight = birthday
        }
        
        let seedPhrase =
            """
            still champion voice habit trend flight \
            survey between bitter process artefact blind \
            carbon truly provide dizzy crush flush \
            breeze blouse charge solid fish spread
            """.redacted
        
        await store.send(.seedPhraseInputChanged(seedPhrase)) { state in
            state.importedSeedPhrase = seedPhrase
            state.wordsCount = 24
            state.isValidNumberOfWords = true
            state.isValidMnemonic = true
            XCTAssertFalse(
                state.isValidForm,
                "Import Wallet tests: `testFormValidity_validBirthday_validMnemonic` is expected to be false but it is \(state.isValidForm)"
            )
        }
        
        await store.finish()
    }
    
    func testFormValidity_validBirthday_validMnemonic() async throws {
        let store = TestStore(
            initialState: ImportWallet.State(maxWordsCount: 24, restoreInfoState: .initial)
        ) {
            ImportWallet()
        }
            
        store.dependencies.mnemonic = .noOp

        let birthday = "1700000".redacted
        
        await store.send(.birthdayInputChanged(birthday)) { state in
            state.birthdayHeight = birthday
            state.birthdayHeightValue = RedactableBlockHeight(1_700_000)
        }
        
        let seedPhrase =
            """
            still champion voice habit trend flight \
            survey between bitter process artefact blind \
            carbon truly provide dizzy crush flush \
            breeze blouse charge solid fish spread
            """.redacted
        
        await store.send(.seedPhraseInputChanged(seedPhrase)) { state in
            state.importedSeedPhrase = seedPhrase
            state.wordsCount = 24
            state.isValidNumberOfWords = true
            state.isValidMnemonic = true
            XCTAssertTrue(
                state.isValidForm,
                "Import Wallet tests: `testFormValidity_validBirthday_validMnemonic` is expected to be true but it is \(state.isValidForm)"
            )
        }
        
        await store.finish()
    }
    
    func testFormValidity_noBirthday_validMnemonic() async throws {
        let store = TestStore(
            initialState: ImportWallet.State(maxWordsCount: 24, restoreInfoState: .initial)
        ) {
            ImportWallet()
        }
        
        store.dependencies.mnemonic = .noOp

        let seedPhrase =
            """
            still champion voice habit trend flight \
            survey between bitter process artefact blind \
            carbon truly provide dizzy crush flush \
            breeze blouse charge solid fish spread
            """.redacted
        
        await store.send(.seedPhraseInputChanged(seedPhrase)) { state in
            state.importedSeedPhrase = seedPhrase
            state.wordsCount = 24
            state.isValidNumberOfWords = true
            state.isValidMnemonic = true
            XCTAssertTrue(
                state.isValidForm,
                "Import Wallet tests: `testFormValidity_validBirthday_validMnemonic` is expected to be true but it is \(state.isValidForm)"
            )
        }
        
        await store.finish()
    }

    func testRestoreWallet() async throws {
        let store = TestStore(
            initialState: ImportWallet.State(
                birthdayHeight: "1700000".redacted,
                birthdayHeightValue: RedactableBlockHeight(1_700_000),
                importedSeedPhrase: """
                still champion voice habit trend flight \
                survey between bitter process artefact blind \
                carbon truly provide dizzy crush flush \
                breeze blouse charge solid fish spread
                """.redacted,
                isValidMnemonic: true,
                isValidNumberOfWords: true,
                maxWordsCount: 24,
                restoreInfoState: .initial,
                wordsCount: 24
            )
        ) {
            ImportWallet()
        }
        
        store.dependencies.mnemonic = .noOp
        store.dependencies.walletStorage = .noOp
        
        await store.send(.restoreWallet) { state in
            state.importedSeedPhrase = .empty
            state.birthdayHeight = .empty
            state.destination = nil
        }

        await store.receive(.successfullyRecovered)

        await store.receive(.initializeSDK)

        await store.receive(.updateDestination(nil))

        await store.finish()
    }
}
