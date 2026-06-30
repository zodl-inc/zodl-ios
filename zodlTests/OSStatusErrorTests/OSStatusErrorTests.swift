//
//  OSStatusErrorTests.swift
//  zodlTests
//
//  More tests — settings. Covers the OSStatusError reducer (Features/OSStatusError/OSStatusErrorStore.swift).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite struct OSStatusErrorTests {
    @MainActor @Test func onAppearResetsExporting() async {
        let store = TestStore(initialState: OSStatusError.State(isExportingData: true, message: "e", osStatus: -1)) { OSStatusError() }
        await store.send(.onAppear) { $0.isExportingData = false }
    }

    @MainActor @Test func sendSupportMailTakesOneSupportPath() async {
        let store = TestStore(initialState: OSStatusError.State(message: "e", osStatus: -1)) {
            OSStatusError()
        } withDependencies: {
            $0.walletStorage = .noOp
        }
        store.exhaustivity = .off
        await store.send(.sendSupportMail)
        // Either a mail SupportData was prepared, or the share fallback was taken.
        #expect(store.state.supportData != nil || store.state.isExportingData)
    }

    @MainActor @Test func sendSupportMailFinishedClearsSupportData() async {
        var state = OSStatusError.State(message: "e", osStatus: -1)
        state.supportData = withDependencies { $0.walletStorage = .noOp } operation: { SupportDataGenerator.generate("x") }
        let store = TestStore(initialState: state) { OSStatusError() }
        store.exhaustivity = .off
        await store.send(.sendSupportMailFinished)
        #expect(store.state.supportData == nil)
    }

    @MainActor @Test func shareFinishedResetsExporting() async {
        let store = TestStore(initialState: OSStatusError.State(isExportingData: true, message: "e", osStatus: -1)) { OSStatusError() }
        await store.send(.shareFinished) { $0.isExportingData = false }
    }
}
