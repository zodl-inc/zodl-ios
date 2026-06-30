//
//  ExportTransactionHistoryReducerTests.swift
//  zodlTests
//
//  More reducers — covers ExportTransactionHistory export request guard, CSV preparation
//  success/failure transitions and derived state
//  (Features/ExportTransactionHistory/ExportTransactionHistoryStore.swift). The live CSV
//  exporter is covered separately in ExportTransactionHistoryTests.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) struct ExportTransactionHistoryReducerTests {
    private struct ExportFailure: Error { }

    @MainActor @Test func exportRequestedWithoutAccountIsNoOp() async {
        var state = ExportTransactionHistory.State()
        state.$selectedWalletAccount.withLock { $0 = nil }
        let store = TestStore(initialState: state) { ExportTransactionHistory() }

        await store.send(.exportRequested)
    }

    @MainActor @Test func exportRequestedWithAccountPreparesUrlAndBindsShare() async {
        let url = URL(fileURLWithPath: "/tmp/zodl-history.csv")
        var state = ExportTransactionHistory.State()
        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }
        let store = TestStore(initialState: state) {
            ExportTransactionHistory()
        } withDependencies: {
            $0.taxExporter.cointrackerCSVfor = { _, _ in url }
        }

        await store.send(.exportRequested) {
            $0.isExportingData = true
        }
        await store.receive(.urlsPrepared(url)) {
            $0.dataURL = url
            $0.exportBinding = true
        }
    }

    @MainActor @Test func exportRequestedCsvFailureStopsExporting() async {
        var state = ExportTransactionHistory.State()
        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }
        let store = TestStore(initialState: state) {
            ExportTransactionHistory()
        } withDependencies: {
            $0.taxExporter.cointrackerCSVfor = { _, _ in throw ExportFailure() }
        }

        await store.send(.exportRequested) {
            $0.isExportingData = true
        }
        await store.receive(.preparationOfUrlsFailed) {
            $0.isExportingData = false
        }
    }

    @MainActor @Test func urlsPreparedSetsDataUrlAndExportBinding() async {
        let url = URL(fileURLWithPath: "/tmp/zodl-ready.csv")
        let store = TestStore(initialState: ExportTransactionHistory.State()) { ExportTransactionHistory() }

        await store.send(.urlsPrepared(url)) {
            $0.dataURL = url
            $0.exportBinding = true
        }
    }

    @MainActor @Test func shareFinishedResetsExportState() async {
        var state = ExportTransactionHistory.State()
        state.isExportingData = true
        state.exportBinding = true
        let store = TestStore(initialState: state) { ExportTransactionHistory() }

        await store.send(.shareFinished) {
            $0.isExportingData = false
            $0.exportBinding = false
        }
    }

    @Test func isExportPossibleReflectsExportingFlag() {
        var state = ExportTransactionHistory.State()
        #expect(state.isExportPossible)
        state.isExportingData = true
        #expect(!state.isExportPossible)
    }

    @Test func accountNameReflectsSelectedAccountVendor() {
        var state = ExportTransactionHistory.State()
        state.$selectedWalletAccount.withLock { $0 = nil }
        #expect(state.accountName.isEmpty)

        state.$selectedWalletAccount.withLock { $0 = keystoneAccount() }
        #expect(!state.accountName.isEmpty)
    }

    private func keystoneAccount() -> WalletAccount {
        WalletAccount(Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "Keystone",
            keySource: String(localizable: .accountsKeystone).lowercased(),
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        ))
    }
}
