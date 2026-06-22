//
//  SwapAccountBindingTests.swift
//  zodlTests
//
//  MOB-1353 — a swap quote is bound to the account it was requested for. If the selected account
//  changes between quote and signing, the swap must fail closed rather than spending from / refunding
//  to a different account than the one the quote (and its refund address) was built for.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: drives the SwapAndPay reducer which reads the process-global `selectedWalletAccount`
// @Shared state. Each test binds `@Shared` to a fresh in-memory store so parallel suites can't clobber it.
@Suite(.serialized) @MainActor struct SwapAccountBindingTests {
    private let testnetAddress =
        "utest1vergg5jkp4xy8sqfasw6s5zkdpnxvfxlxh35uuc3me7dp596y2r05t6dv9htwe3pf8ksrfr8ksca2lskzjanqtl8uqp5vln3zyy246ejtx86vqftp73j7jg9099jxafyjhfm6u956j3"

    private func account(byte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: byte, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private let zecAsset = SwapAsset(provider: "near", chain: "zec", token: "ZEC", assetId: "zec.id", usdPrice: Decimal(30), decimals: 8)
    private let btcAsset = SwapAsset(provider: "near", chain: "btc", token: "BTC", assetId: "btc.id", usdPrice: Decimal(60_000), decimals: 8)

    private func matchingQuote() -> SwapQuote {
        SwapQuote(
            depositAddress: testnetAddress,
            amountIn: Decimal(100_000_000),
            amountInUsd: "10",
            minAmountIn: Decimal(0),
            amountOut: Decimal(1),
            amountOutUsd: "1",
            timeEstimate: 0,
            recipient: "recipient-addr",
            originAssetId: "zec.id",
            destinationAssetId: "btc.id"
        )
    }

    private func makeState(selected: WalletAccount, quoteAccountId: AccountUUID?) -> SwapAndPay.State {
        var state = SwapAndPayCoordFlow.State().swapAndPayState
        state.$selectedWalletAccount.withLock { $0 = selected }
        state.quoteAccountId = quoteAccountId
        state.selectedAsset = btcAsset
        state.zecAsset = zecAsset
        state.address = "recipient-addr"
        state.isSwapExperienceEnabled = true
        state.isSwapToZecExperienceEnabled = false
        return state
    }

    private func makeStore(_ state: SwapAndPay.State, proposeCalls: LockIsolated<Int>) -> StoreOf<SwapAndPay> {
        Store(initialState: state) {
            SwapAndPay()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.sdkSynchronizer = .noOp
            $0.sdkSynchronizer.proposeTransfer = { _, _, _, _ in
                proposeCalls.withValue { $0 += 1 }
                return .testOnlyFakeProposal(totalFee: 0)
            }
        }
    }

    /// Account switched after the quote was requested → fail closed, no proposal built.
    @Test func rejectsWhenAccountSwitchedAfterQuote() async {
        let accountA = account(byte: 0)
        let accountB = account(byte: 1)
        let proposeCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(makeState(selected: accountB, quoteAccountId: accountA.id), proposeCalls: proposeCalls)
            store.send(.swapQuoteLoaded(matchingQuote()))
            await waitForSwapStore { store.state.isQuoteUnavailablePresented }

            #expect(proposeCalls.withValue { $0 } == 0) // never builds a proposal for the wrong account
            #expect(store.state.proposal == nil)
        }
    }

    /// Selected account still matches the quote account → proceeds to build the proposal (regression).
    @Test func proposesWhenAccountMatchesQuote() async {
        let accountA = account(byte: 0)
        let proposeCalls = LockIsolated<Int>(0)

        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore(makeState(selected: accountA, quoteAccountId: accountA.id), proposeCalls: proposeCalls)
            store.send(.swapQuoteLoaded(matchingQuote()))
            await waitForSwapStore { proposeCalls.withValue { $0 == 1 } }

            #expect(proposeCalls.withValue { $0 } == 1)
        }
    }
}

@MainActor
private func waitForSwapStore(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for SwapAndPay store state", sourceLocation: sourceLocation)
}
