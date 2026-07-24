//
//  RootCheckFundsToastTests.swift
//  zodlTests
//
//  The Settings → Recover Funds flow (RootCheckFunds.swift) surfaces its four results as
//  toasts. These tests pin every toast to its Localizable.xcstrings entry — the messages were
//  hardcoded English literals bypassing the catalog, so Spanish users saw untranslated text
//  ("Tor required" instead of the recoverFunds.tor message the sheet itself shows).
//
//  Mirrors the FlexaSecurityTests / RootTransactionsAccountSwitchTests pattern for Root-level
//  tests: a plain `Store` (Root's init effects are too heavy for exhaustive `TestStore`
//  assertion); the toast cases are pure synchronous state writes, so no polling is needed.
//
//  `.serialized`: constructing/driving `Root.State` touches process-global `@Shared(.inMemory)`
//  keys, same precedent as the sibling Root-level test files.
//

import Foundation
import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootCheckFundsToastTests {
    private func makeStore() -> StoreOf<Root> {
        Store(initialState: Root.State.initial) {
            Root()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.sdkSynchronizer = .noOp
        }
    }

    @Test func torRequiredToastShowsTheLocalizedTorProtectionMessage() {
        let store = makeStore()

        store.send(.checkFundsTorRequired)

        #expect(store.withState { $0.toast } == .topDelayed5(String(localizable: .recoverFundsTor)))
    }

    @Test func failedToastFormatsTheErrorThroughTheCatalogKey() {
        let store = makeStore()

        store.send(.checkFundsFailed("boom"))

        #expect(store.withState { $0.toast } == .topDelayed5(String(localizable: .recoverFundsError("boom"))))
    }

    @Test func foundToastUsesTheCatalogString() {
        let store = makeStore()

        store.send(.checkFundsFoundSomething)

        #expect(store.withState { $0.toast } == .topDelayed5(String(localizable: .recoverFundsFound)))
    }

    @Test func nothingFoundToastUsesTheCatalogString() {
        let store = makeStore()

        store.send(.checkFundsNothingFound)

        #expect(store.withState { $0.toast } == .topDelayed5(String(localizable: .recoverFundsNotFound)))
    }
}
