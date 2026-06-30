//
//  DeleteWalletTests.swift
//  zodlTests
//
//  More tests — settings. Covers the DeleteWallet sheet/processing state machine
//  (Features/DeleteWallet/DeleteWalletStore.swift).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct DeleteWalletTests {
    @MainActor @Test func deleteRequestedShowsSheet() async {
        let store = TestStore(initialState: DeleteWallet.State()) { DeleteWallet() }
        await store.send(.deleteRequested) { $0.isSheetUp = true }
    }

    @MainActor @Test func dismissSheetHidesSheet() async {
        let store = TestStore(initialState: DeleteWallet.State()) { DeleteWallet() }
        await store.send(.deleteRequested) { $0.isSheetUp = true }
        await store.send(.dismissSheet) { $0.isSheetUp = false }
    }

    @MainActor @Test func deleteCanceledStopsProcessing() async {
        let store = TestStore(initialState: DeleteWallet.State(areMetadataPreserved: true, isProcessing: true)) { DeleteWallet() }
        await store.send(.deleteCanceled) { $0.isProcessing = false }
    }

    @MainActor @Test func deleteTappedDelayedProcessesThenDelegatesDelete() async {
        let store = TestStore(initialState: DeleteWallet.State()) { DeleteWallet() }
        store.exhaustivity = .off
        await store.send(.deleteTappedDelayed(true)) {
            $0.isProcessing = true
            $0.isSheetUp = false
        }
        await store.receive(\.deleteTapped, timeout: .seconds(2))
    }
}
