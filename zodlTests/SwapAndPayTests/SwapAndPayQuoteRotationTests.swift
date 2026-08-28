//
//  SwapAndPayQuoteRotationTests.swift
//  zodlTests
//
//  Covers the rotate-ahead-by-one UA flow on the quote request (MOB-1803,
//  Features/SwapAndPayForm/SwapAndPayStore.swift `.getQuoteTapped`): `.getQuote`
//  hard-requires `privateUnifiedAddress` (the refund address), so with a stash the
//  tap promotes it synchronously and quotes immediately, while without one it keeps
//  the pre-rotation await-then-quote behavior — plus a stash self-heal either way.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

// Mutates the process-global `@Shared(.inMemory(.selectedWalletAccount))` slot.
@Suite(.serialized) struct SwapAndPayQuoteRotationTests {
    private enum Const {
        /// Sentinel UAs built through the SDK's internal `init(validatedEncoding:networkType:)`
        /// (reachable via `@testable import ZcashLightClientKit`) — the rotation logic treats
        /// addresses as opaque tokens, so no FFI validation is involved and the encodings only
        /// need to be distinct.
        static let stashUA = UnifiedAddress(validatedEncoding: "u1swapstashrotationfixture", networkType: .mainnet)
        static let freshUA = UnifiedAddress(validatedEncoding: "u1swapfreshrotationfixture", networkType: .mainnet)
        static let secondFreshUA = UnifiedAddress(validatedEncoding: "u1swapsecondfreshrotationfixture", networkType: .mainnet)
    }

    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    // d1. With a stash: the refund address is promoted synchronously and `.getQuote`
    // arrives while address generation is still blocked — the quote no longer waits on
    // the wallet-DB write. The background refill lands in the stash afterwards.
    @MainActor @Test func quoteWithStashPromotesRefundAddressAndQuotesWithoutAwaitingGeneration() async {
        let generationGateOpen = LockIsolated(false)
        let generationCalls = LockIsolated(0)

        let state = SwapAndPay.State.initial
        let previousAccount = state.selectedWalletAccount
        var account = testWalletAccount
        account.nextPrivateUA = Const.stashUA
        state.$selectedWalletAccount.withLock { $0 = account }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            SwapAndPay()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getCustomUnifiedAddress: { _, _ in
                    generationCalls.withValue { $0 += 1 }
                    while !generationGateOpen.value {
                        if Task.isCancelled { return nil }
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    return Const.freshUA
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped)

        // The stash became the refund address synchronously.
        #expect(store.state.selectedWalletAccount?.privateUA == Const.stashUA)
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == nil)

        // `.getQuote` proceeds while the generation mock is still gated shut.
        await store.receive(\.getQuote, timeout: .seconds(5))
        #expect(!generationGateOpen.value)

        generationGateOpen.setValue(true)
        await store.receive(\.updateNextPrivateUA, timeout: .seconds(5))

        #expect(store.state.selectedWalletAccount?.privateUA == Const.stashUA)
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == Const.freshUA)
        #expect(generationCalls.value == 1)

        await store.finish()
    }

    // d2. Without a stash: today's behavior is preserved — `.getQuote` fires only AFTER
    // generation has filled the refund address (its guard would silently no-op on nil) —
    // and a second generation self-heals the stash inside the same effect.
    @MainActor @Test func quoteWithoutStashAwaitsGenerationBeforeQuotingAndSelfHeals() async {
        let generationCalls = LockIsolated(0)

        let state = SwapAndPay.State.initial
        let previousAccount = state.selectedWalletAccount
        var account = testWalletAccount
        account.nextPrivateUA = nil
        state.$selectedWalletAccount.withLock { $0 = account }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            SwapAndPay()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getCustomUnifiedAddress: { _, _ in
                    let call = generationCalls.withValue { value -> Int in
                        value += 1
                        return value
                    }
                    return call == 1 ? Const.freshUA : Const.secondFreshUA
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.getQuoteTapped)

        // The refund address arrives first...
        await store.receive(\.updatePrivateUA, timeout: .seconds(5))
        #expect(store.state.selectedWalletAccount?.privateUA == Const.freshUA)

        // ...only then does the quote proceed...
        await store.receive(\.getQuote, timeout: .seconds(5))

        // ...and the stash self-heals so the next quote request promotes instantly.
        await store.receive(\.updateNextPrivateUA, timeout: .seconds(5))
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == Const.secondFreshUA)
        #expect(generationCalls.value == 2)

        await store.finish()
    }
}
