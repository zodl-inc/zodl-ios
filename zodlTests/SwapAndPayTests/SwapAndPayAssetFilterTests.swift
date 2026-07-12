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

    // MARK: - Last-used asset vs the source-curated set (MOB-1472)

    // The last-used asset is stored as a `SwapAsset.id` and pre-selected at the #1
    // spot. After curation at the source, a previously-used-but-now-dropped asset is
    // no longer in the loaded list, so its lookup returns nil and the BTC fallback
    // must win — the dropped asset can never be pre-selected.
    @MainActor @Test func lastUsedDroppedAssetIsIgnoredAndFallsBackToBtc() async {
        let store = makeLoadStore(lastUsed: ["near.doge.doge"]) // dropped id, absent from `curatedAssets`
        store.exhaustivity = .off
        await store.send(.swapAssetsLoaded(curatedAssets))
        await store.skipReceivedActions(strict: false)

        #expect(store.state.selectedAsset?.token.lowercased() == "btc")
        #expect(store.state.selectedAsset?.chain.lowercased() == "btc")
        #expect(!store.state.swapAssetsToPresent.contains { $0.id == "near.doge.doge" })
    }

    // Control: a last-used asset that IS still supported stays pre-selected — proving
    // the fallback above is driven by the drop, not by a broken lookup.
    @MainActor @Test func lastUsedSupportedAssetStaysPreselected() async {
        let store = makeLoadStore(lastUsed: ["near.eth.eth"]) // supported id, present in `curatedAssets`
        store.exhaustivity = .off
        await store.send(.swapAssetsLoaded(curatedAssets))
        await store.skipReceivedActions(strict: false)

        #expect(store.state.selectedAsset?.token.lowercased() == "eth")
        #expect(store.state.selectedAsset?.chain.lowercased() == "eth")
    }

    @MainActor
    private func makeStore(assets: [SwapAsset], searchTerm: String) -> TestStoreOf<SwapAndPay> {
        var state = SwapAndPay.State.initial
        state.searchTerm = searchTerm
        state.$swapAssets.withLock { $0 = IdentifiedArrayOf(uniqueElements: assets) }
        return TestStore(initialState: state) { SwapAndPay() }
    }

    @MainActor
    private func makeLoadStore(lastUsed: [String]) -> TestStoreOf<SwapAndPay> {
        TestStore(initialState: SwapAndPay.State.initial) {
            SwapAndPay()
        } withDependencies: {
            $0.userMetadataProvider.lastUsedAssetHistory = { lastUsed }
        }
    }

    // Stand-in for the assets that survive Near1Click's source-level curation.
    private var curatedAssets: IdentifiedArrayOf<SwapAsset> {
        IdentifiedArrayOf(uniqueElements: [
            swapAsset(chain: "btc", token: "BTC"),
            swapAsset(chain: "eth", token: "ETH"),
            swapAsset(chain: "sol", token: "SOL"),
            swapAsset(chain: "eth", token: "USDC")
        ])
    }

    private func asset(_ chainToken: String) -> SwapAsset {
        SwapAsset(provider: "near", chain: chainToken, token: chainToken, assetId: "\(chainToken)-id", usdPrice: 0, decimals: 18)
    }

    private func swapAsset(chain: String, token: String) -> SwapAsset {
        SwapAsset(provider: "near", chain: chain, token: token, assetId: "\(chain).\(token)-id", usdPrice: 1, decimals: 6)
    }
}
