//
//  WhatsNewTests.swift
//  zodlTests
//
//  More tests — settings. Covers the WhatsNew reducer (Features/WhatsNew/WhatsNewStore.swift).
//

import Testing
import Foundation
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

    @MainActor @Test func printNotifsCommandPrintsReportInsteadOfSql() async {
        var state = WhatsNew.State()
        state.query = "print_notifs"
        let sqlCalled = LockIsolated(false)
        let store = TestStore(initialState: state) {
            WhatsNew()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.sdkSynchronizer.debugDatabaseSql = { _ in
                sqlCalled.setValue(true)
                return "sql"
            }
            $0.date.now = { Date(timeIntervalSince1970: 0) }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.userNotifications.pendingMigrationNotifications = {
                [
                    PendingMigrationNotification(
                        identifier: "migration.stepReady_aabbcc",
                        title: "Step ready",
                        body: "Open Zodl.",
                        fireDate: Date(timeIntervalSince1970: 300),
                        accountUUID: "aabbcc"
                    )
                ]
            }
        }
        store.exhaustivity = .off
        await store.send(.executeQueryRequested)
        await store.receive(\.notifsReportReady)
        #expect(store.state.output.contains("Notification authorization: authorized"))
        #expect(store.state.output.contains("1 pending migration notification(s):"))
        #expect(store.state.output.contains("#1 migration.stepReady_aabbcc"))
        #expect(sqlCalled.value == false)
    }

    @MainActor @Test func printNotifsCommandToleratesWhitespaceAndCase() async {
        var state = WhatsNew.State()
        state.query = "  PRINT_NOTIFS\n"
        let store = TestStore(initialState: state) {
            WhatsNew()
        } withDependencies: {
            $0.localAuthentication = .mockAuthenticationSucceeded
            $0.date.now = { Date(timeIntervalSince1970: 0) }
            $0.userNotifications.authorizationStatus = { .authorized }
            $0.userNotifications.pendingMigrationNotifications = { [] }
        }
        store.exhaustivity = .off
        await store.send(.executeQueryRequested)
        await store.receive(\.notifsReportReady)
        #expect(store.state.output.contains("No pending migration notifications."))
    }
}
