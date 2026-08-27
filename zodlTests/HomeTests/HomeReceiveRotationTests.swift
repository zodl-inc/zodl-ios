//
//  HomeReceiveRotationTests.swift
//  zodlTests
//
//  Covers the rotate-ahead-by-one UA flow on Home's Receive entry (MOB-1803,
//  Features/Home/HomeStore.swift `.receiveScreenRequested`): a tap promotes the
//  pre-generated `nextPrivateUA` stash into the displayed `privateUA` slot
//  synchronously and navigates immediately — `getCustomUnifiedAddress` is a
//  wallet-DB write that can stall for seconds behind the sync engine, so it must
//  only ever run as a background refill, never in front of navigation.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

// Mutates the process-global `@Shared(.inMemory(.selectedWalletAccount))` slot.
@Suite(.serialized) struct HomeReceiveRotationTests {
    private enum Const {
        /// Sentinel UAs built through the SDK's internal `init(validatedEncoding:networkType:)`
        /// (reachable via `@testable import ZcashLightClientKit`) — the rotation logic treats
        /// addresses as opaque tokens, so no FFI validation is involved and the encodings only
        /// need to be distinct.
        static let previousVisitUA = UnifiedAddress(validatedEncoding: "u1previousvisitrotationfixture", networkType: .mainnet)
        static let stashUA = UnifiedAddress(validatedEncoding: "u1stashrotationfixture", networkType: .mainnet)
        static let freshUA = UnifiedAddress(validatedEncoding: "u1freshrotationfixture", networkType: .mainnet)
        static let secondFreshUA = UnifiedAddress(validatedEncoding: "u1secondfreshrotationfixture", networkType: .mainnet)
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

    // a. With a stash: the tap promotes it into the displayed slot synchronously and
    // `.receiveTapped` (navigation) arrives while address generation is still blocked —
    // proving the tap no longer awaits the wallet-DB write. The refill then lands in the
    // stash, never in the displayed slot.
    @MainActor @Test func tapWithStashPromotesAndNavigatesWithoutAwaitingGeneration() async {
        let generationGateOpen = LockIsolated(false)
        let generationCalls = LockIsolated(0)

        let state = Home.State.initial
        let previousAccount = state.selectedWalletAccount
        var account = testWalletAccount
        account.privateUA = Const.previousVisitUA
        account.nextPrivateUA = Const.stashUA
        state.$selectedWalletAccount.withLock { $0 = account }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            Home()
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

        await store.send(.receiveScreenRequested)

        // The stash was promoted synchronously — the visit shows a fresh, never-displayed UA.
        #expect(store.state.selectedWalletAccount?.privateUA == Const.stashUA)
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == nil)

        // Navigation arrives while the generation mock is still gated shut.
        await store.receive(\.receiveTapped, timeout: .seconds(5))
        #expect(!generationGateOpen.value)

        generationGateOpen.setValue(true)
        await store.receive(\.updateNextPrivateUA, timeout: .seconds(5))

        // The refill went to the stash; the displayed address never changed mid-visit.
        #expect(store.state.selectedWalletAccount?.privateUA == Const.stashUA)
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == Const.freshUA)
        #expect(generationCalls.value == 1)

        await store.finish()
    }

    // b. Without a stash: the displayed slot goes nil immediately (never the previous
    // visit's address), navigation is still immediate, then generation live-fills the
    // displayed slot first and a second generation self-heals the stash — in that order.
    @MainActor @Test func tapWithoutStashClearsDisplayedSlotThenLiveFillsAndSelfHeals() async {
        let generationGateOpen = LockIsolated(false)
        let generationCalls = LockIsolated(0)

        let state = Home.State.initial
        let previousAccount = state.selectedWalletAccount
        var account = testWalletAccount
        account.privateUA = Const.previousVisitUA
        account.nextPrivateUA = nil
        state.$selectedWalletAccount.withLock { $0 = account }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            Home()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getCustomUnifiedAddress: { _, _ in
                    let call = generationCalls.withValue { value -> Int in
                        value += 1
                        return value
                    }
                    while !generationGateOpen.value {
                        if Task.isCancelled { return nil }
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    return call == 1 ? Const.freshUA : Const.secondFreshUA
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.receiveScreenRequested)

        // The previous visit's address must never survive the tap — asserted while the
        // generation mock is still gated shut, so the live-fill cannot have landed yet.
        #expect(store.state.selectedWalletAccount?.privateUA == nil)
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == nil)

        await store.receive(\.receiveTapped, timeout: .seconds(5))
        #expect(!generationGateOpen.value)

        generationGateOpen.setValue(true)

        // Live-fill of the loading screen first (filling from empty is fine)...
        await store.receive(\.updatePrivateUA, timeout: .seconds(5))
        #expect(store.state.selectedWalletAccount?.privateUA == Const.freshUA)

        // ...then the second generation heals the stash for the next visit.
        await store.receive(\.updateNextPrivateUA, timeout: .seconds(5))
        #expect(store.state.selectedWalletAccount?.privateUA == Const.freshUA)
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == Const.secondFreshUA)
        #expect(generationCalls.value == 2)

        await store.finish()
    }

    // c. Rotation invariant: two consecutive visits never display the same UA.
    @MainActor @Test func consecutiveTapsNeverExposeTheSameAddressTwice() async {
        let generationCalls = LockIsolated(0)

        let state = Home.State.initial
        let previousAccount = state.selectedWalletAccount
        var account = testWalletAccount
        account.privateUA = Const.previousVisitUA
        account.nextPrivateUA = Const.stashUA
        state.$selectedWalletAccount.withLock { $0 = account }
        defer { state.$selectedWalletAccount.withLock { $0 = previousAccount } }

        let store = TestStore(initialState: state) {
            Home()
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

        await store.send(.receiveScreenRequested)
        let firstVisitUA = store.state.selectedWalletAccount?.privateUA
        await store.receive(\.receiveTapped, timeout: .seconds(5))
        await store.receive(\.updateNextPrivateUA, timeout: .seconds(5))

        await store.send(.receiveScreenRequested)
        let secondVisitUA = store.state.selectedWalletAccount?.privateUA
        await store.receive(\.receiveTapped, timeout: .seconds(5))
        await store.receive(\.updateNextPrivateUA, timeout: .seconds(5))

        #expect(firstVisitUA == Const.stashUA)
        #expect(secondVisitUA == Const.freshUA)
        #expect(firstVisitUA != nil)
        #expect(secondVisitUA != nil)
        #expect(firstVisitUA != secondVisitUA)

        await store.finish()
    }
}
