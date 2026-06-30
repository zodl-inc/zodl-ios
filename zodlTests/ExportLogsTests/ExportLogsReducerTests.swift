//
//  ExportLogsReducerTests.swift
//  zodlTests
//
//  More reducers — covers ExportLogs start/finished/failed reducer transitions and the
//  failure alert (Features/ExportLogs/ExportLogsStore.swift). The live exporter / cleanup
//  behaviour is covered separately in ExportLogsTests.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ExportLogsReducerTests {
    private struct ExportFailure: Error { }

    @MainActor @Test func startExportsLogsThenEntersSharing() async {
        let url = URL(fileURLWithPath: "/tmp/zodl-logs.zip")
        let store = TestStore(initialState: ExportLogs.State()) {
            ExportLogs()
        } withDependencies: {
            $0.logsHandler.exportAndStoreLogs = { _, _, _ in url }
        }

        await store.send(.start) {
            $0.exportLogsDisabled = true
        }
        await store.receive(.finished(url)) {
            $0.zippedLogsURLs = [url]
            $0.exportLogsDisabled = false
            $0.isSharingLogs = true
        }
    }

    @MainActor @Test func startFailureReEnablesExportAndAlerts() async {
        let store = TestStore(initialState: ExportLogs.State()) {
            ExportLogs()
        } withDependencies: {
            $0.logsHandler.exportAndStoreLogs = { _, _, _ in throw ExportFailure() }
        }
        store.exhaustivity = .off

        await store.send(.start)
        await store.receive(\.failed)

        #expect(!store.state.exportLogsDisabled)
        #expect(!store.state.isSharingLogs)
        #expect(store.state.alert != nil)
    }

    @MainActor @Test func finishedWithNilURLSharesWithoutStoringURLs() async {
        let store = TestStore(initialState: ExportLogs.State(exportLogsDisabled: true)) { ExportLogs() }

        await store.send(.finished(nil)) {
            $0.exportLogsDisabled = false
            $0.isSharingLogs = true
        }
    }

    @MainActor @Test func failedResetsFlagsAndSetsFailureAlert() async {
        let store = TestStore(
            initialState: ExportLogs.State(exportLogsDisabled: true, isSharingLogs: true)
        ) {
            ExportLogs()
        }

        await store.send(.failed(.synchronizerNotPrepared)) {
            $0.exportLogsDisabled = false
            $0.isSharingLogs = false
            $0.alert = AlertState.failed(.synchronizerNotPrepared)
        }
    }

    @MainActor @Test func shareFinishedStopsSharing() async {
        let store = TestStore(initialState: ExportLogs.State(isSharingLogs: true)) { ExportLogs() }

        await store.send(.shareFinished) {
            $0.isSharingLogs = false
        }
    }
}
