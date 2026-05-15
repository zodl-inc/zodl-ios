//
//  SendTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 02.05.2022.
//

import XCTest
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

// swiftlint:disable type_body_length
@MainActor
class SendTests: XCTestCase {
    var storage = WalletStorage(secItem: .live)
    let usNumberFormatter = NumberFormatter()

    override func setUp() {
        super.setUp()
        storage.zcashStoredWalletPrefix = "test_send_"
        storage.deleteData(forKey: WalletStorage.Constants.zcashStoredWallet)

        usNumberFormatter.maximumFractionDigits = 8
        usNumberFormatter.maximumIntegerDigits = 8
        usNumberFormatter.numberStyle = .decimal
        usNumberFormatter.usesGroupingSeparator = true
        usNumberFormatter.locale = Locale(identifier: "en_US")
    }

    // TODO: [#1349] fix the tests https://github.com/Electric-Coin-Company/zashi-ios/issues/1349
//    @MainActor func testSendSucceeded() async throws {
//        // the test needs to pass the exportWallet() so we simulate some in the keychain
//        try storage.importWallet(bip39: "one two three", birthday: nil)
//        
//        var initialState = SendConfirmation.State.initial
//        initialState.proposal = Proposal.testOnlyFakeProposal(totalFee: 10_000)
//
//        let store = TestStore(
//            initialState: initialState
//        ) {
//            SendConfirmation()
//        }
//        
//        store.dependencies.derivationTool = .liveValue
//        store.dependencies.mainQueue = .immediate
//        store.dependencies.numberFormatter = .live()
//        store.dependencies.walletStorage = .noOp
//        store.dependencies.mnemonic = .liveValue
//        store.dependencies.sdkSynchronizer = .mock
//        store.dependencies.sdkSynchronizer.createProposedTransactions = { _, _ in .success }
//        store.dependencies.localAuthentication = .mockAuthenticationSucceeded
//        store.dependencies.zcashSDKEnvironment = .testValue
//        
//        // simulate the sending confirmation button to be pressed
//        await store.send(.sendTapped) { state in
//            // once sending is confirmed, the attempts to try to send again by pressing the button
//            // needs to be eliminated, indicated by the flag `isSending`, need to be true
//            state.isSending = true
//        }
//        
//        await store.receive(.sendDone) { state in
//            state.isSending = false
//        }
//
//        await store.finish()
//    }
//
//    @MainActor func testSendFailed() async throws {
//        // the test needs to pass the exportWallet() so we simulate some in the keychain
//        try storage.importWallet(bip39: "one two three", birthday: nil)
//        
//        var initialState = SendConfirmation.State.initial
//        initialState.proposal = Proposal.testOnlyFakeProposal(totalFee: 10_000)
//
//        let store = TestStore(
//            initialState: initialState
//        ) {
//            SendConfirmation()
//        }
//        
//        let error = "send failed".toZcashError()
//        
//        store.dependencies.derivationTool = .liveValue
//        store.dependencies.mainQueue = .immediate
//        store.dependencies.numberFormatter = .live()
//        store.dependencies.walletStorage = .noOp
//        store.dependencies.mnemonic = .liveValue
//        store.dependencies.sdkSynchronizer = .mock
//        store.dependencies.sdkSynchronizer.createProposedTransactions = { _, _ in throw error }
//        store.dependencies.localAuthentication = .mockAuthenticationSucceeded
//        store.dependencies.zcashSDKEnvironment = .testValue
//        
//        // simulate the sending confirmation button to be pressed
//        await store.send(.sendTapped) { state in
//            // once sending is confirmed, the attempts to try to send again by pressing the button
//            // needs to be eliminated, indicated by the flag `isSending`, need to be true
//            state.isSending = true
//        }
//        
//        await store.receive(.sendFailed(error)) { state in
//            state.isSending = false
//            state.alert = AlertState.sendFailure(error)
//        }
//
//        await store.finish()
//    }
//
//    @MainActor func testSendFailedBeforeHitSynchronizer() async throws {
//        // the test needs to pass the exportWallet() so we simulate some in the keychain
//        try storage.importWallet(bip39: "one two three", birthday: nil)
//        
//        var initialState = SendConfirmation.State.initial
//        initialState.proposal = Proposal.testOnlyFakeProposal(totalFee: 10_000)
//
//        let store = TestStore(
//            initialState: initialState
//        ) {
//            SendConfirmation()
//        }
//        
//        store.dependencies.derivationTool = .liveValue
//        store.dependencies.mainQueue = .immediate
//        store.dependencies.numberFormatter = .live()
//        store.dependencies.walletStorage = .noOp
//        store.dependencies.mnemonic = .liveValue
//        store.dependencies.sdkSynchronizer = .noOp
//        store.dependencies.localAuthentication = .mockAuthenticationSucceeded
//        store.dependencies.zcashSDKEnvironment = .testValue
//        
//        let walletStorageError: ZcashError = "export failed".toZcashError()
//        store.dependencies.walletStorage.exportWallet = { throw walletStorageError }
//        
//        // simulate the sending confirmation button to be pressed
//        await store.send(.sendTapped) { state in
//            state.isSending = true
//        }
//        
//        await store.receive(.sendFailed(walletStorageError)) { state in
//            state.isSending = false
//            state.alert = AlertState.sendFailure(walletStorageError)
//        }
//
//        await store.finish()
//    }
//
//    func testAddressValidation_Invalid() async throws {
//        let store = TestStore(
//            initialState: .initial
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.derivationTool = .noOp
//        store.dependencies.derivationTool.isZcashAddress = { _, _ in false }
//
//        let address = "3HRG769ii3HDSJV5vNknQPzXqtL2mTSGnr".redacted
//        
//        await store.send(.transactionAddressInput(.textField(.set(address)))) { state in
//            state.transactionAddressInputState.textFieldState.text = address
//            // true is expected here because textField doesn't have any `validationType: String.ValidationType?`
//            // isValid function returns true, `guard let validationType else { return true }`
//            state.transactionAddressInputState.textFieldState.valid = true
//            state.transactionAddressInputState.isValidAddress = false
//            XCTAssertTrue(
//                state.isInvalidAddressFormat,
//                "Send Tests: `testAddressValidation` is expected to be true but it's \(state.isInvalidAddressFormat)"
//            )
//        }
//    }
//
//    func testAddressValidation_Valid() async throws {
//        let store = TestStore(
//            initialState: .initial
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.derivationTool = .noOp
//        store.dependencies.derivationTool.isZcashAddress = { _, _ in true }
//        
//        let address = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po".redacted
//
//        await store.send(.transactionAddressInput(.textField(.set(address)))) { state in
//            state.transactionAddressInputState.textFieldState.text = address
//            // true is expected here because textField doesn't have any `validationType: String.ValidationType?`
//            // isValid function returns true, `guard let validationType else { return true }`
//            state.transactionAddressInputState.textFieldState.valid = true
//            state.transactionAddressInputState.isValidAddress = true
//            XCTAssertFalse(
//                state.isInvalidAddressFormat,
//                "Send Tests: `testAddressValidation` is expected to be false but it's \(state.isInvalidAddressFormat)"
//            )
//        }
//    }
//
//    func testInvalidAmountFormatEmptyInput() async throws {
//        var state = SendForm.State.initial
//        state.transactionAmountInputState = .amount
//        
//        let store = TestStore(
//            initialState: state
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.numberFormatter = .noOp
//
//        // Checks the computed property `isInvalidAmountFormat` which controls the error message to be shown on the screen
//        // With empty input it must be false
//        await store.send(.transactionAmountInput(.textField(.set(.empty))))
//
//        await store.receive(.transactionAmountInput(.updateAmount))
//    }
//
//    func testInvalidAddressFormatEmptyInput() async throws {
//        let store = TestStore(
//            initialState: .initial
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.derivationTool = .noOp
//
//        // Checks the computed property `isInvalidAddressFormat` which controls the error message to be shown on the screen
//        // With empty input it must be false
//        await store.send(.transactionAddressInput(.textField(.set(.empty)))) { state in
//            state.transactionAddressInputState.textFieldState.text = .empty
//            // true is expected here because textField doesn't have any `validationType: String.ValidationType?`
//            // isValid function returns true, `guard let validationType else { return true }`
//            state.transactionAddressInputState.textFieldState.valid = true
//            XCTAssertFalse(
//                state.isInvalidAddressFormat,
//                "Send Tests: `testInvalidAddressFormatEmptyInput` is expected to be false but it's \(state.isInvalidAddressFormat)"
//            )
//        }
//    }
//
//    func testFundsSufficiency_SufficientAmount() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            shieldedBalance: Zatoshi(100_000),
//            transactionAddressInputState: .initial,
//            transactionAmountInputState: .initial,
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.numberFormatter = .live(numberFormatter: usNumberFormatter)
//
//        let amount = "0.0009".redacted
//        
//        await store.send(.transactionAmountInput(.textField(.set(amount)))) { state in
//            state.transactionAmountInputState.textFieldState.text = amount
//            state.transactionAmountInputState.textFieldState.valid = true
//        }
//
//        await store.receive(.transactionAmountInput(.updateAmount)) { state in
//            state.transactionAmountInputState.amount = Int64(90_000).redacted
//            XCTAssertFalse(
//                state.isInsufficientFunds,
//                "Send Tests: `testFundsSufficiency` is expected to be false but it's \(state.isInsufficientFunds)"
//            )
//        }
//    }
//
//    func testFundsSufficiency_InsufficientAmount() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState: .initial,
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.numberFormatter = .live(numberFormatter: usNumberFormatter)
//
//        let amount = "0.00090001".redacted
//        
//        await store.send(.transactionAmountInput(.textField(.set(amount)))) { state in
//            state.transactionAmountInputState.textFieldState.text = amount
//            state.transactionAmountInputState.textFieldState.valid = true
//            XCTAssertFalse(
//                state.isInsufficientFunds,
//                "Send Tests: `testFundsSufficiency` is expected to be false but it's \(state.isInsufficientFunds)"
//            )
//        }
//
//        await store.receive(.transactionAmountInput(.updateAmount)) { state in
//            state.transactionAmountInputState.amount = Int64(90_001).redacted
//            XCTAssertTrue(
//                state.isInsufficientFunds,
//                "Send Tests: `testFundsSufficiency` is expected to be true but it's \(state.isInsufficientFunds)"
//            )
//        }
//    }
//
//    func testDifferentNumberFormats_LiveNumberFormatter() throws {
//        let zcashNumberFormatter = NumberFormatter.zcashNumberFormatter
//        zcashNumberFormatter.locale = Locale(identifier: "en_US")
//        
//        try numberFormatTest("1.234", NSNumber(1.234))
//        try numberFormatTest("1,234", NSNumber(1_234))
//        try numberFormatTest("1 234", NSNumber(1_234))
//        try numberFormatTest("1,234.567", NSNumber(1_234.567))
//        try numberFormatTest("1.", NSNumber(1))
//        try numberFormatTest("1..", nil)
//        try numberFormatTest("1,.", nil)
//        try numberFormatTest("1.,", nil)
//        try numberFormatTest("1,,", nil)
//        try numberFormatTest("1,23", nil)
//        try numberFormatTest("1 23", nil)
//        try numberFormatTest("1.2.3", nil)
//    }
//
//    func testValidForm() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            shieldedBalance: Zatoshi(100_000),
//            transactionAddressInputState: .initial,
//            transactionAmountInputState: .initial,
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.numberFormatter = .live(numberFormatter: usNumberFormatter)
//        store.dependencies.derivationTool = .live()
//
//        let amount = "0.0009".redacted
//        
//        await store.send(.transactionAmountInput(.textField(.set(amount)))) { state in
//            state.transactionAmountInputState.textFieldState.text = amount
//            state.transactionAmountInputState.textFieldState.valid = true
//        }
//
//        await store.receive(.transactionAmountInput(.updateAmount)) { state in
//            state.transactionAmountInputState.amount = Int64(90_000).redacted
//            XCTAssertFalse(
//                state.isInsufficientFunds,
//                "Send Tests: `testFundsSufficiency` is expected to be false but it's \(state.isInsufficientFunds)"
//            )
//        }
//        
//        let address = "tmViyFacKkncJ6zhEqs8rjqNPkGqXsMV4uq".redacted
//        
//        await store.send(.transactionAddressInput(.textField(.set(address)))) { state in
//            state.transactionAddressInputState.textFieldState.text = address
//            // true is expected here because textField doesn't have any `validationType: String.ValidationType?`
//            // isValid function returns true, `guard let validationType else { return true }`
//            state.transactionAddressInputState.textFieldState.valid = true
//            state.transactionAddressInputState.isValidAddress = true
//            state.transactionAddressInputState.isValidTransparentAddress = true
//            XCTAssertTrue(
//                state.isValidForm,
//                "Send Tests: `testValidForm` is expected to be false but it's \(state.isValidForm)"
//            )
//        }
//    }
//
//    func testValidForm_NoFees() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState:
//                TransactionAmountTextFieldReducer.State(
//                    amount: Int64(9_000).redacted,
//                    currencySelectionState: CurrencySelectionReducer.State(),
//                    maxValue: Int64(501_302).redacted,
//                    textFieldState:
//                        TCATextFieldReducer.State(
//                            validationType: .customFloatingPoint(usNumberFormatter),
//                            text: "0.00501301".redacted
//                        )
//                ),
//            walletBalancesState: .initial
//        )
//        
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//        
//        store.dependencies.derivationTool = .noOp
//        store.dependencies.derivationTool.isZcashAddress = { _, _ in true }
//        store.dependencies.numberFormatter = .noOp
//
//        let address = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po".redacted
//        
//        await store.send(.transactionAddressInput(.textField(.set(address)))) { state in
//            state.transactionAddressInputState.textFieldState.text = address
//            // true is expected here because textField doesn't have any `validationType: String.ValidationType?`
//            // isValid function returns true, `guard let validationType else { return true }`
//            state.transactionAddressInputState.textFieldState.valid = true
//            state.transactionAddressInputState.isValidAddress = true
//            XCTAssertFalse(
//                state.isValidForm,
//                "Send Tests: `testValidForm` is expected to be false but it's \(state.isValidForm)"
//            )
//        }
//    }
//
//    func testInvalidForm_InsufficientFunds() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState:
//                TransactionAmountTextFieldReducer.State(
//                    amount: .init(501_301),
//                    currencySelectionState: CurrencySelectionReducer.State(),
//                    maxValue: Int64(501_300).redacted,
//                    textFieldState:
//                        TCATextFieldReducer.State(
//                            validationType: .floatingPoint,
//                            text: "0.00501301".redacted
//                        )
//                ),
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.derivationTool = .noOp
//        store.dependencies.derivationTool.isZcashAddress = { _, _ in true }
//        store.dependencies.numberFormatter = .noOp
//        store.dependencies.numberFormatter.number = { _ in NSNumber(501_301) }
//
//        let address = "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po".redacted
//        
//        await store.send(.transactionAddressInput(.textField(.set(address)))) { state in
//            state.transactionAddressInputState.textFieldState.text = address
//            // true is expected here because textField doesn't have any `validationType: String.ValidationType?`
//            // isValid function returns true, `guard let validationType else { return true }`
//            state.transactionAddressInputState.textFieldState.valid = true
//            state.transactionAddressInputState.isValidAddress = true
//            XCTAssertFalse(
//                state.isValidForm,
//                "Send Tests: `testValidForm` is expected to be false but it's \(state.isValidForm)"
//            )
//        }
//    }
//
//    func testInvalidForm_AddressFormat() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState:
//                TransactionAmountTextFieldReducer.State(
//                    currencySelectionState: CurrencySelectionReducer.State(),
//                    maxValue: Int64(501_302).redacted,
//                    textFieldState:
//                        TCATextFieldReducer.State(
//                            validationType: .floatingPoint,
//                            text: "0.00501301".redacted
//                        )
//                ),
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.derivationTool = .noOp
//        store.dependencies.zcashSDKEnvironment = .testValue
//
//        let address = "3HRG769ii3HDSJV5vNknQPzXqtL2mTSGnr".redacted
//        
//        await store.send(.transactionAddressInput(.textField(.set(address)))) { state in
//            state.transactionAddressInputState.textFieldState.text = address
//            // true is expected here because textField doesn't have any `validationType: String.ValidationType?`
//            // isValid function returns true, `guard let validationType else { return true }`
//            state.transactionAddressInputState.textFieldState.valid = true
//            state.transactionAddressInputState.isValidAddress = false
//            XCTAssertFalse(
//                state.isValidForm,
//                "Send Tests: `testValidForm` is expected to be false but it's \(state.isValidForm)"
//            )
//        }
//    }
//
//    func testInvalidForm_ExceededMemoCharLimit() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: MessageEditor.State(charLimit: 3),
//            scanState: .initial,
//            transactionAddressInputState:
//                TransactionAddressTextFieldReducer.State(
//                    isValidAddress: true,
//                    textFieldState:
//                        TCATextFieldReducer.State(
//                            validationType: .none,
//                            text: "t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po".redacted
//                        )
//                ),
//            transactionAmountInputState:
//                TransactionAmountTextFieldReducer.State(
//                    amount: Int64(100).redacted,
//                    currencySelectionState: CurrencySelectionReducer.State(),
//                    maxValue: Int64(501_302).redacted,
//                    textFieldState:
//                        TCATextFieldReducer.State(
//                            validationType: .floatingPoint,
//                            text: "0.0.0501301".redacted
//                        )
//                ),
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//
//        let value = "test".redacted
//        
//        store.dependencies.numberFormatter = .noOp
//        
//        await store.send(.memo(.inputChanged(value))) { state in
//            state.memoState.text = value
//            XCTAssertFalse(
//                state.isValidForm,
//                "Send Tests: `testValidForm` is expected to be false but it's \(state.isValidForm)"
//            )
//        }
//    }
//
//    func testMemoCharLimitSet() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState:
//                TransactionAmountTextFieldReducer.State(
//                    currencySelectionState: CurrencySelectionReducer.State(),
//                    maxValue: Int64(501_302).redacted,
//                    textFieldState:
//                        TCATextFieldReducer.State(
//                            validationType: .floatingPoint,
//                            text: "0.0.0501301".redacted
//                        )
//                ),
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.mainQueue = .immediate
//        store.dependencies.sdkSynchronizer = .noOp
//
//        await store.send(.onAppear) { state in
//            state.memoState.charLimit = 512
//        }
//    }
//
//    func testScannedAddress() async throws {
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState: .initial,
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//
//        store.dependencies.audioServices = AudioServicesClient(systemSoundVibrate: { })
//        store.dependencies.derivationTool = .noOp
//
//        // We don't need to pass a valid address here, we just need to confirm some
//        // found string is received and the `isValidAddress` flag is set to `true`
//        let address = "address".redacted
//        
//        await store.send(.scan(.found(address))) { state in
//            state.transactionAddressInputState.textFieldState.text = address
//            state.transactionAddressInputState.isValidAddress = true
//        }
//
//        await store.receive(.updateDestination(nil))
//    }
//    
//    func testReviewTapped() async throws {
//        var sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState: .initial,
//            walletBalancesState: .initial
//        )
//        sendState.address = "tmViyFacKkncJ6zhEqs8rjqNPkGqXsMV4uq"
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//        
//        store.dependencies.sdkSynchronizer = .noOp
//        let proposal = Proposal.testOnlyFakeProposal(totalFee: 10_000)
//        store.dependencies.sdkSynchronizer.proposeTransfer = { _, _, _, _ in proposal }
//
//        await store.send(.reviewTapped)
//        
//        await store.receive(.proposal(proposal)) { state in
//            state.proposal = proposal
//        }
//        
//        await store.receive(.sendConfirmationRequired)
//        
//        await store.finish()
//    }
//    
//    func testMemoToMessage() throws {
//        let testMessage = "test message".redacted
//        
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: MessageEditor.State(charLimit: 512, text: testMessage),
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState: .initial,
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//        
//        XCTAssertEqual(store.state.message, testMessage.data)
//    }
//    
//    func testFeeFormat() throws {
//        let zashiBalanceFormatter = NumberFormatter.zashiBalanceFormatter
//        zashiBalanceFormatter.locale = Locale(identifier: "en_US")
//
//        let feeFormat = "(Typical Fee < 0.001)"
//        
//        let sendState = SendForm.State(
//            addMemoState: true,
//            memoState: .initial,
//            scanState: .initial,
//            transactionAddressInputState: .initial,
//            transactionAmountInputState: .initial,
//            walletBalancesState: .initial
//        )
//
//        let store = TestStore(
//            initialState: sendState
//        ) {
//            SendForm()
//        }
//        
//        XCTAssertEqual(store.state.feeFormat, feeFormat)
//    }
}

private extension SendTests {
    func numberFormatTest(
        _ amount: String,
        _ expectedResult: NSNumber?
    ) throws {
        if let number = NumberFormatter.zcashNumberFormatter.number(from: amount) {
            XCTAssertEqual(number, expectedResult)
            return
        } else {
            XCTAssertEqual(nil, expectedResult, "NumberFormatterClient.liveValue.number(\(amount)) unexpected result.")
        }
    }
}
