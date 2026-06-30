//
//  ResyncWalletTests.swift
//  zodlTests
//
//  More tests — settings. Covers ResyncWallet support routing + retry
//  (Features/ResyncWallet/ResyncWalletStore.swift).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct ResyncWalletTests {
    @MainActor @Test func contactSupportBranchesOnCanSendMail() async {
        let mailStore = makeStore(canSendMail: true)
        mailStore.exhaustivity = .off
        await mailStore.send(.contactSupport)
        #expect(mailStore.state.supportData != nil)

        let shareStore = makeStore(canSendMail: false)
        shareStore.exhaustivity = .off
        await shareStore.send(.contactSupport)
        #expect(shareStore.state.messageToBeShared != nil)
    }

    @MainActor @Test func tryAgainHidesFailureSheetThenRetries() async {
        var state = ResyncWallet.State()
        state.isFailureSheetUp = true
        let store = TestStore(initialState: state) { ResyncWallet() }
        store.exhaustivity = .off
        await store.send(.tryAgain)
        #expect(!store.state.isFailureSheetUp)
        await store.receive(\.startResyncTapped, timeout: .seconds(2))
    }

    @MainActor @Test func sendSupportMailFinishedClearsSupportData() async {
        var state = ResyncWallet.State()
        state.supportData = withDependencies { $0.walletStorage = .noOp } operation: { SupportDataGenerator.generate("x") }
        let store = TestStore(initialState: state) { ResyncWallet() }
        store.exhaustivity = .off
        await store.send(.sendSupportMailFinished)
        #expect(store.state.supportData == nil)
    }

    @MainActor @Test func shareFinishedClearsMessage() async {
        var state = ResyncWallet.State()
        state.messageToBeShared = "msg"
        let store = TestStore(initialState: state) { ResyncWallet() }
        await store.send(.shareFinished) { $0.messageToBeShared = nil }
    }

    @MainActor
    private func makeStore(canSendMail: Bool) -> TestStoreOf<ResyncWallet> {
        var state = ResyncWallet.State()
        state.canSendMail = canSendMail
        state.errMsg = "boom"
        return TestStore(initialState: state) {
            ResyncWallet()
        } withDependencies: {
            $0.walletStorage = .noOp
        }
    }
}
