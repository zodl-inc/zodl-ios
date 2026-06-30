//
//  AddressDetailsTests.swift
//  zodlTests
//
//  More reducers — covers AddressDetails address expansion, share, and copy-to-pasteboard
//  (Features/AddressDetails/AddressDetailsStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) struct AddressDetailsTests {
    @MainActor @Test func addressTappedTogglesExpansion() async {
        let store = TestStore(initialState: AddressDetails.State(address: "u1addr".redacted)) { AddressDetails() }

        await store.send(.addressTapped) { $0.isAddressExpanded = true }
        await store.send(.addressTapped) { $0.isAddressExpanded = false }
    }

    @MainActor @Test func shareQRSetsAddressToShareAndFinishedClearsIt() async {
        let address = "u1shareme".redacted
        let store = TestStore(initialState: AddressDetails.State(address: address)) { AddressDetails() }

        await store.send(.shareQR) { $0.addressToShare = address }
        await store.send(.shareFinished) { $0.addressToShare = nil }
    }

    @MainActor @Test func copyToPastboardCopiesAddressAndShowsToast() async {
        let address = "u1copyme".redacted
        let copied = LockIsolated<RedactableString?>(nil)
        let store = TestStore(initialState: AddressDetails.State(address: address)) { AddressDetails() } withDependencies: {
            $0.pasteboard.setString = { copied.setValue($0) }
        }
        store.exhaustivity = .off

        await store.send(.copyToPastboard)

        #expect(copied.value == address)
        #expect(store.state.toast == .top(String(localizable: .generalCopiedToTheClipboard)))
    }
}
