//
//  SendFeedbackTests.swift
//  zodlTests
//
//  More tests — feedback. Covers SendFeedback form validity + support-message assembly
//  (Features/SendFeedback/SendFeedbackStore.swift).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct SendFeedbackTests {
    @Test func invalidForm() {
        var state = SendFeedback.State()
        #expect(state.invalidForm) // no rating selected
        state.selectedRating = 2
        #expect(state.invalidForm) // memo still empty
        state.memoState.text = "great app"
        #expect(!state.invalidForm)
    }

    @MainActor @Test func ratingTappedSetsRating() async {
        let store = TestStore(initialState: SendFeedback.State()) { SendFeedback() }
        await store.send(.ratingTapped(3)) { $0.selectedRating = 3 }
    }

    @MainActor @Test func sendTappedWithMailBuildsSupportData() async {
        let store = TestStore(initialState: feedbackState(canSendMail: true)) {
            SendFeedback()
        } withDependencies: {
            $0.walletStorage = .noOp
        }
        store.exhaustivity = .off
        await store.send(.sendTapped)
        #expect(store.state.supportData != nil)
        #expect(store.state.messageToBeShared == nil)
    }

    @MainActor @Test func sendTappedWithoutMailBuildsShareMessage() async {
        let store = TestStore(initialState: feedbackState(canSendMail: false)) {
            SendFeedback()
        } withDependencies: {
            $0.walletStorage = .noOp
        }
        store.exhaustivity = .off
        await store.send(.sendTapped)
        #expect(store.state.messageToBeShared != nil)
        #expect(store.state.supportData == nil)
    }

    @MainActor @Test func sendTappedWithoutRatingIsNoOp() async {
        let store = TestStore(initialState: SendFeedback.State()) { SendFeedback() }
        await store.send(.sendTapped) // no rating -> guard returns .none, no state change
    }

    @MainActor @Test func sendSupportMailFinishedClearsSupportData() async {
        let supportData = withDependencies {
            $0.walletStorage = .noOp
        } operation: {
            SupportDataGenerator.generate("x")
        }
        var state = SendFeedback.State()
        state.supportData = supportData
        let store = TestStore(initialState: state) { SendFeedback() }
        store.exhaustivity = .off
        await store.send(.sendSupportMailFinished)
        #expect(store.state.supportData == nil)
    }

    private func feedbackState(canSendMail: Bool) -> SendFeedback.State {
        var state = SendFeedback.State()
        state.canSendMail = canSendMail
        state.selectedRating = 2
        state.memoState.text = "great app"
        return state
    }
}
