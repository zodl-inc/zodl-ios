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

    // d. MOB-1859 (review): the `walletAccounts` array entry is the source of truth an account
    // switch installs as the new selection (`WalletAccountsSheet`), so both the promotion step
    // and the background refill must keep it in sync, not only `selectedWalletAccount`'s live
    // copy — otherwise a switch away and back from this account would either re-show an address
    // already displayed (breaking the MOB-1803 guarantee) or find a stash that never arrived
    // (forcing the slow live-fill path again instead of just once).
    @MainActor @Test func promotionClearsTheArrayEntryStashAndTheRefillWritesItBack() async {
        // Gated exactly like `tapWithStashPromotesAndNavigatesWithoutAwaitingGeneration` above:
        // without the gate, the un-awaited refill can race ahead of the assertions checking the
        // state right after `.receiveScreenRequested`, since this mock has no delay of its own.
        let generationGateOpen = LockIsolated(false)
        let generationCalls = LockIsolated(0)

        let state = Home.State.initial
        let previousAccount = state.selectedWalletAccount
        let previousAccounts = state.walletAccounts
        var account = testWalletAccount
        account.privateUA = Const.previousVisitUA
        account.nextPrivateUA = Const.stashUA
        state.$selectedWalletAccount.withLock { $0 = account }
        // The array entry starts with the SAME stash as the selected copy — what a merged load
        // (`RootInitialization.swift`) or an earlier refill would already have left behind.
        state.$walletAccounts.withLock { $0 = [account] }
        defer {
            state.$selectedWalletAccount.withLock { $0 = previousAccount }
            state.$walletAccounts.withLock { $0 = previousAccounts }
        }

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

        // Promotion consumed the stash — the array entry must lose it too, not only the selected
        // copy, or a switch away and back would re-install and re-show `Const.stashUA`. Checked
        // while the refill mock is still gated shut, so this can only reflect the synchronous
        // promotion step, never the background refill landing early.
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == nil)
        #expect(store.state.walletAccounts.first { $0.id == account.id }?.nextPrivateUA == nil)

        await store.receive(\.receiveTapped, timeout: .seconds(5))
        #expect(!generationGateOpen.value)

        generationGateOpen.setValue(true)
        await store.receive(\.updateNextPrivateUA, timeout: .seconds(5))

        // The refill wrote the fresh stash back into the array entry too — not only the selected
        // copy — so the next account switch installs a real stash instead of forcing a live-fill.
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == Const.freshUA)
        #expect(store.state.walletAccounts.first { $0.id == account.id }?.nextPrivateUA == Const.freshUA)
        #expect(generationCalls.value == 1)

        await store.finish()
    }

    // e. Review follow-up (MOB-1859): a failed refill must not clobber a stash a different,
    // faster path already wrote for the same account while this one was still in flight —
    // typical right after backgrounding, when the synchronizer has already stopped and this
    // slower call is the one that ends up failing.
    @MainActor @Test func failedRefillLeavesAConcurrentlyWrittenStashUntouched() async {
        let state = Home.State.initial
        let previousAccount = state.selectedWalletAccount
        let previousAccounts = state.walletAccounts
        var account = testWalletAccount
        account.privateUA = Const.previousVisitUA
        account.nextPrivateUA = Const.stashUA
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        defer {
            state.$selectedWalletAccount.withLock { $0 = previousAccount }
            state.$walletAccounts.withLock { $0 = previousAccounts }
        }

        let store = TestStore(initialState: state) {
            Home()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getCustomUnifiedAddress: { accountId, _ in
                    // Simulate a different, faster path writing a real stash for this same
                    // account while this attempt is still resolving, then have THIS attempt fail.
                    @Shared(.inMemory(.walletAccounts)) var sharedWalletAccounts: [WalletAccount] = []
                    $sharedWalletAccounts.withLock { accounts in
                        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
                        accounts[index].nextPrivateUA = Const.secondFreshUA
                    }
                    return nil
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.receiveScreenRequested)
        await store.receive(\.receiveTapped, timeout: .seconds(5))
        await store.finish()

        // The failed refill must not have overwritten the stash the other path wrote.
        #expect(store.state.walletAccounts.first { $0.id == account.id }?.nextPrivateUA == Const.secondFreshUA)
    }
}
