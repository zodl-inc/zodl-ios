//
//  SwapAndPayAssetFilterTests.swift
//  zodlTests
//
//  More tests — swap. Covers SwapAndPay.updateAssetsAccordingToSearchTerm filtering
//  (Features/SwapAndPayForm/SwapAndPayStore.swift). Unblocked by SwapAndPay.State: Equatable.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized) struct SwapAndPayAssetFilterTests {
    @MainActor @Test func emptyAssetsIsNoOp() async {
        let store = makeStore(assets: [], searchTerm: "eth")
        store.exhaustivity = .off
        await store.send(.updateAssetsAccordingToSearchTerm)
        #expect(store.state.swapAssetsToPresent.isEmpty)
    }

    @MainActor @Test func emptySearchShowsAllAssets() async {
        let store = makeStore(assets: [asset("eth"), asset("btc")], searchTerm: "")
        store.exhaustivity = .off
        await store.send(.updateAssetsAccordingToSearchTerm)
        #expect(store.state.swapAssetsToPresent.count == 2)
    }

    @MainActor @Test func searchFiltersByTokenName() async {
        let store = makeStore(assets: [asset("eth"), asset("btc")], searchTerm: "eth")
        store.exhaustivity = .off
        await store.send(.updateAssetsAccordingToSearchTerm)
        let ids = store.state.swapAssetsToPresent.map(\.assetId)
        #expect(ids.contains("eth-id"))
        #expect(!ids.contains("btc-id"))
    }

    @MainActor @Test func searchWithNoMatchIsEmpty() async {
        let store = makeStore(assets: [asset("eth"), asset("btc")], searchTerm: "zzz")
        store.exhaustivity = .off
        await store.send(.updateAssetsAccordingToSearchTerm)
        #expect(store.state.swapAssetsToPresent.isEmpty)
    }

    @MainActor
    private func makeStore(assets: [SwapAsset], searchTerm: String) -> TestStoreOf<SwapAndPay> {
        var state = SwapAndPay.State.initial
        state.searchTerm = searchTerm
        state.$swapAssets.withLock { $0 = IdentifiedArrayOf(uniqueElements: assets) }
        return TestStore(initialState: state) { SwapAndPay() }
    }

    private func asset(_ chainToken: String) -> SwapAsset {
        SwapAsset(provider: "near", chain: chainToken, token: chainToken, assetId: "\(chainToken)-id", usdPrice: 0, decimals: 18)
    }
}
