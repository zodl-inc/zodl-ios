//
//  SendFormAddressValidationTests.swift
//  zodlTests
//
//  More tests — send. Covers SendForm address validation + address-book hint
//  (Features/SendForm/SendFormStore.swift). Unblocked by SendForm.State: Equatable.
//  NOTE: amount/isValidForm/isInsufficientFunds remain _XCTIsTesting-poisoned and are not asserted here.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct SendFormAddressValidationTests {
    @MainActor @Test func validateAddressFlagsZcashAddress() async {
        let store = makeStore(address: "zaddr", isZcash: true)
        await store.send(.validateAddress)
        #expect(store.state.isValidAddress)
        #expect(!store.state.isValidTransparentAddress)
        #expect(!store.state.isValidTexAddress)
    }

    @MainActor @Test func validateAddressFlagsTransparentAddress() async {
        let store = makeStore(address: "taddr", isZcash: true, isTransparent: true)
        await store.send(.validateAddress)
        #expect(store.state.isValidAddress)
        #expect(store.state.isValidTransparentAddress)
    }

    @MainActor @Test func validateAddressFlagsTexAddress() async {
        let store = makeStore(address: "texaddr", isTex: true)
        await store.send(.validateAddress)
        #expect(store.state.isValidTexAddress)
    }

    @MainActor @Test func addressUpdatedWithInvalidAddressHidesHint() async {
        let store = makeStore(isZcash: false)
        store.exhaustivity = .off
        await store.send(.addressUpdated("garbage".redacted))
        #expect(!store.state.isValidAddress)
        #expect(!store.state.isNotAddressInAddressBook)
        #expect(!store.state.isAddressBookHintVisible)
    }

    @MainActor @Test func addressUpdatedWithKnownContactHidesHint() async {
        let known = "knownaddress"
        let store = makeStore(isZcash: true, contacts: [Contact(address: known, name: "Alice", lastUpdated: Date(timeIntervalSince1970: 0))])
        store.exhaustivity = .off
        await store.send(.addressUpdated(known.redacted))
        #expect(store.state.isValidAddress)
        #expect(!store.state.isNotAddressInAddressBook) // already a saved contact
        #expect(!store.state.isAddressBookHintVisible)
    }

    @MainActor
    private func makeStore(
        address: String = "",
        isZcash: Bool = false,
        isTransparent: Bool = false,
        isTex: Bool = false,
        contacts: [Contact] = []
    ) -> TestStoreOf<SendForm> {
        var state = SendForm.State.initial
        state.address = address.redacted
        state.$addressBookContacts.withLock {
            $0 = AddressBookContacts(
                lastUpdated: Date(timeIntervalSince1970: 0),
                version: 2,
                contacts: IdentifiedArrayOf(uniqueElements: contacts)
            )
        }
        let store = TestStore(initialState: state) {
            SendForm()
        } withDependencies: {
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .testnet) }
            $0.derivationTool.isZcashAddress = { _, _ in isZcash }
            $0.derivationTool.isTransparentAddress = { _, _ in isTransparent }
            $0.derivationTool.isTexAddress = { _, _ in isTex }
        }
        store.exhaustivity = .off
        return store
    }
}
