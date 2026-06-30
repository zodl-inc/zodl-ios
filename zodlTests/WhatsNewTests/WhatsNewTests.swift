//
//  WhatsNewTests.swift
//  zodlTests
//
//  More tests — settings. Covers the WhatsNew reducer (Features/WhatsNew/WhatsNewStore.swift).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct WhatsNewTests {
    @MainActor @Test func onAppearLoadsVersionInfo() async {
        let store = TestStore(initialState: WhatsNew.State()) {
            WhatsNew()
        } withDependencies: {
            $0.appVersion.appVersion = { "1.0" }
            $0.appVersion.appBuild = { "7" }
            $0.whatsNewProvider.latest = { .zero }
            $0.whatsNewProvider.all = { .zero }
        }
        store.exhaustivity = .off
        await store.send(.onAppear)
        #expect(store.state.appVersion == "1.0")
        #expect(store.state.appBuild == "7")
    }

    @MainActor @Test func emptyQueryShowsHint() async {
        let store = TestStore(initialState: WhatsNew.State()) { WhatsNew() }
        await store.send(.executeQueryRequested) {
            $0.output = "Fill in some query to execute"
        }
    }

    @MainActor @Test func enableAndExitDebug() async {
        let store = TestStore(initialState: WhatsNew.State()) { WhatsNew() }
        await store.send(.enableDebugMode) { $0.isInDebugMode = true }
        await store.send(.exitDebug) { $0.isInDebugMode = false }
    }

    @MainActor @Test func nonEmptyQueryAuthenticatesThenExecutes() async {
        var state = WhatsNew.State()
        state.query = "SELECT 1"
        let store = TestStore(initialState: state) {
            WhatsNew()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer.debugDatabaseSql = { _ in "result row" }
        }
        store.exhaustivity = .off
        await store.send(.executeQueryRequested)
        await store.receive(\.executeQuery)
        #expect(store.state.output == "result row")
    }
}
