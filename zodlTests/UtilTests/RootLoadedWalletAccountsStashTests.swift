//
//  RootLoadedWalletAccountsStashTests.swift
//  zodlTests
//
//  Covers MOB-1859 at Root's `.initialization(.loadedWalletAccounts)`
//  (Features/Root/RootInitialization.swift): `walletAccounts()` no longer generates each
//  account's rotation stash on every load (a wallet-database write that contended with the sync
//  engine), so the handler must merge in whatever stash the in-memory accounts already had and
//  refill, in the background, only the accounts that still have none. The refill result must be
//  OBSERVABLE in the `walletAccounts` array entry for every account — not only whichever one
//  happens to be selected — because an account switch (`WalletAccountsSheet`) installs the
//  tapped ARRAY entry as the new selection; an array entry that never receives a stash forces
//  the slow live-fill path on every first Receive/Swap visit after a switch.
//
//  `extension Root.State: @retroactive Equatable` already exists, module-wide, at
//  RootInitializeSDKHealTests.swift — this file must NOT redeclare it (duplicate-conformance
//  compile error; see that file's header).
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

// Mutates the process-global `@Shared(.inMemory(.walletAccounts))` / `.selectedWalletAccount` /
// `.zashiWalletAccount` slots.
@Suite(.serialized) @MainActor struct RootLoadedWalletAccountsStashTests {
    private enum Const {
        /// Sentinel UAs built through the SDK's internal `init(validatedEncoding:networkType:)`
        /// (reachable via `@testable import ZcashLightClientKit`) — the rotation logic treats
        /// addresses as opaque tokens, so no FFI validation is involved and the encodings only
        /// need to be distinct.
        static let existingStashUA = UnifiedAddress(validatedEncoding: "u1rootexistingstashfixture", networkType: .mainnet)
        static let refilledStashUA = UnifiedAddress(validatedEncoding: "u1rootrefilledstashfixture", networkType: .mainnet)
    }

    // `vendor` defaults to `.keystone` but a test can ask for a `.zcash` fixture too: the
    // Zashi-account auto-select loop in `.loadedWalletAccounts` only fires for a `.zcash`-vendor
    // account, and only a `.zcash` account can become `selectedWalletAccount`/`zashiWalletAccount`
    // this way — a test that needs to observe the refill land on BOTH the array entry of a
    // non-selected account and the selected copy needs one fixture of each vendor.
    private func account(idByte: UInt8, vendor: WalletAccount.Vendor = .keystone) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: vendor == .keystone ? "Keystone" : "Zashi",
                keySource: vendor == .keystone ? String(localizable: .accountsKeystone).lowercased() : nil,
                seedFingerprint: [UInt8](repeating: 0x02, count: 32),
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private func freshRootState() -> Root.State {
        Root.State(
            destinationState: Root.DestinationState(internalDestination: .welcome),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
    }

    // Covers the review finding that the original version of this test was blind to: both
    // fixtures were Keystone, so `selectedWalletAccount`/`zashiWalletAccount` stayed nil and the
    // test passed whether or not the refill ever reached anything other than the dispatched
    // action itself. With one Zcash (selected) and one Keystone (not selected) account, this
    // proves the refilled stash is observable in EVERY shared slot it should land in, and that a
    // second load reads that stash back out of the array instead of asking the SDK again.
    @Test func loadRefillsTheArrayAndSelectionThenAReloadWithBothStashesSkipsRefillEntirely() async {
        let generationCalls = LockIsolated(0)
        let generatedForAccountIds = LockIsolated<[AccountUUID]>([])

        let zcashAccount = account(idByte: 0x01, vendor: .zcash)
        let keystoneAccount = account(idByte: 0x02, vendor: .keystone)

        var initialState = freshRootState()
        let previousWalletAccounts = initialState.walletAccounts
        let previousSelected = initialState.selectedWalletAccount
        let previousZashi = initialState.zashiWalletAccount
        defer {
            initialState.$walletAccounts.withLock { $0 = previousWalletAccounts }
            initialState.$selectedWalletAccount.withLock { $0 = previousSelected }
            initialState.$zashiWalletAccount.withLock { $0 = previousZashi }
        }

        initialState.$walletAccounts.withLock { $0 = [] }
        initialState.$selectedWalletAccount.withLock { $0 = nil }
        initialState.$zashiWalletAccount.withLock { $0 = nil }

        let store = TestStore(initialState: initialState) {
            Root()
        } withDependencies: {
            // A `.zcash`-vendor fixture auto-selects, which is exactly the point of this test —
            // but that selection also (harmlessly) wakes the `.loadContacts`/`.loadUserMetadata`/
            // smart-banner-ladder sends `.loadedWalletAccounts` always fires. None of those are
            // what this test is about, so they get just enough to run without tripping an
            // "unimplemented dependency" issue, mirroring RootInitializeSDKColdStartFetchTests.
            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
            $0.userMetadataProvider.load = { _ in }
            $0.readTransactionsStorage = .noOp
            $0.userDefaults = .noOp
            $0.walletStorage = .noOp
            $0.mainQueue = .immediate
            $0.continuousClock = TestClock()
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getCustomUnifiedAddress: { accountId, _ in
                    generationCalls.withValue { $0 += 1 }
                    generatedForAccountIds.withValue { $0.append(accountId) }
                    return Const.refilledStashUA
                }
            )
        }
        store.exhaustivity = .off

        // The freshly "loaded" list, as `walletAccounts()` returns it post-MOB-1859: every
        // account comes back with a nil stash, and neither has been seen before, so the merge
        // leaves both nil too.
        await store.send(.initialization(.loadedWalletAccounts([zcashAccount, keystoneAccount])))

        // No prior selection, so the Zashi-vendor account auto-selects.
        #expect(store.state.selectedWalletAccount?.id == zcashAccount.id)
        #expect(store.state.zashiWalletAccount?.id == zcashAccount.id)

        // Both accounts have a nil stash after the merge, so both need a background refill.
        await store.receive(
            { action in
                guard case .privateUAStashRefilled(_, let accountId) = action else { return false }
                return accountId == zcashAccount.id
            },
            timeout: .seconds(5)
        )
        await store.receive(
            { action in
                guard case .privateUAStashRefilled(_, let accountId) = action else { return false }
                return accountId == keystoneAccount.id
            },
            timeout: .seconds(5)
        )
        #expect(generationCalls.value == 2)
        #expect(generatedForAccountIds.value == [zcashAccount.id, keystoneAccount.id])

        // The refill must be OBSERVABLE, not merely dispatched: the array entry for the
        // NON-selected Keystone account carries it...
        #expect(store.state.walletAccounts.first { $0.id == keystoneAccount.id }?.nextPrivateUA == Const.refilledStashUA)
        // ...and so does the array entry for the selected Zcash account...
        #expect(store.state.walletAccounts.first { $0.id == zcashAccount.id }?.nextPrivateUA == Const.refilledStashUA)
        // ...as well as BOTH of its live copies.
        #expect(store.state.selectedWalletAccount?.nextPrivateUA == Const.refilledStashUA)
        #expect(store.state.zashiWalletAccount?.nextPrivateUA == Const.refilledStashUA)

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)

        // A second load (e.g. a foreground refresh) with the very same accounts:
        // `walletAccounts()` still returns a nil stash for both post-MOB-1859, but the array —
        // now holding both refilled stashes from the first load — is the merge's source of
        // truth. Zero further SDK calls proves the merge actually reads it back, rather than the
        // first load's refill being the only thing that ever populated it.
        await store.send(.initialization(.loadedWalletAccounts([zcashAccount, keystoneAccount])))

        #expect(store.state.walletAccounts.first { $0.id == zcashAccount.id }?.nextPrivateUA == Const.refilledStashUA)
        #expect(store.state.walletAccounts.first { $0.id == keystoneAccount.id }?.nextPrivateUA == Const.refilledStashUA)

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)

        #expect(generationCalls.value == 2)
    }

    // Review follow-up (MOB-1859): the shared refill loop (`PrivateUAStash.refill`) used to call
    // its `onGenerated` callback even when generation failed (`try?` produced nil), and every
    // handler writes whatever it receives straight through `PrivateUAStash.write`, which is
    // unconditional — so a failed background refill would clear a stash a different, faster path
    // had already written for the very same account while this call was still resolving. This is
    // exactly what happens right after backgrounding: the synchronizer stops, this call fails,
    // but another path may already have succeeded in the meantime.
    @Test func aFailedRefillLeavesAStashWrittenByAnotherPathDuringItUntouched() async {
        let zcashAccount = account(idByte: 0x05, vendor: .zcash)

        var initialState = freshRootState()
        let previousWalletAccounts = initialState.walletAccounts
        let previousSelected = initialState.selectedWalletAccount
        let previousZashi = initialState.zashiWalletAccount
        defer {
            initialState.$walletAccounts.withLock { $0 = previousWalletAccounts }
            initialState.$selectedWalletAccount.withLock { $0 = previousSelected }
            initialState.$zashiWalletAccount.withLock { $0 = previousZashi }
        }

        initialState.$walletAccounts.withLock { $0 = [] }
        initialState.$selectedWalletAccount.withLock { $0 = nil }
        initialState.$zashiWalletAccount.withLock { $0 = nil }

        let store = TestStore(initialState: initialState) {
            Root()
        } withDependencies: {
            $0.addressBook.allLocalContacts = { _ in (AddressBookContacts.empty, .notAttempted) }
            $0.userMetadataProvider.load = { _ in }
            $0.readTransactionsStorage = .noOp
            $0.userDefaults = .noOp
            $0.walletStorage = .noOp
            $0.mainQueue = .immediate
            $0.continuousClock = TestClock()
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getCustomUnifiedAddress: { accountId, _ in
                    // Simulate a different, faster path (e.g. a Receive visit's own refill)
                    // writing a real stash for this same account while this slower background
                    // call is still resolving, then have THIS call fail — the exact ordering the
                    // bug depended on.
                    @Shared(.inMemory(.walletAccounts)) var sharedWalletAccounts: [WalletAccount] = []
                    $sharedWalletAccounts.withLock { accounts in
                        guard let index = accounts.firstIndex(where: { $0.id == accountId }) else { return }
                        accounts[index].nextPrivateUA = Const.existingStashUA
                    }
                    return nil
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.initialization(.loadedWalletAccounts([zcashAccount])))

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)

        // The failed refill must not have overwritten the stash the other path wrote.
        #expect(store.state.walletAccounts.first { $0.id == zcashAccount.id }?.nextPrivateUA == Const.existingStashUA)
    }

    @Test func loadSkipsTheRefillEntirelyWhenEveryAccountAlreadyHasAStash() async {
        let generationCalls = LockIsolated(0)

        let accountWithStash = account(idByte: 0x03)

        var initialState = freshRootState()
        let previousWalletAccounts = initialState.walletAccounts
        let previousSelected = initialState.selectedWalletAccount
        let previousZashi = initialState.zashiWalletAccount
        defer {
            initialState.$walletAccounts.withLock { $0 = previousWalletAccounts }
            initialState.$selectedWalletAccount.withLock { $0 = previousSelected }
            initialState.$zashiWalletAccount.withLock { $0 = previousZashi }
        }

        var seededWithStash = accountWithStash
        seededWithStash.nextPrivateUA = Const.existingStashUA
        initialState.$walletAccounts.withLock { $0 = [seededWithStash] }
        initialState.$selectedWalletAccount.withLock { $0 = nil }
        initialState.$zashiWalletAccount.withLock { $0 = nil }

        let store = TestStore(initialState: initialState) {
            Root()
        } withDependencies: {
            $0.sdkSynchronizer = SDKSynchronizerClient.mocked(
                getCustomUnifiedAddress: { _, _ in
                    generationCalls.withValue { $0 += 1 }
                    return Const.refilledStashUA
                }
            )
        }
        store.exhaustivity = .off

        await store.send(.initialization(.loadedWalletAccounts([accountWithStash])))

        #expect(store.state.walletAccounts.first?.nextPrivateUA == Const.existingStashUA)

        await store.skipReceivedActions(strict: false)
        await store.skipInFlightEffects(strict: false)

        // No account needed a refill, so `getCustomUnifiedAddress` must never have been called.
        #expect(generationCalls.value == 0)
    }
}
