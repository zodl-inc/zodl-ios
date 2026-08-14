//
//  RootSendCompletionRefreshTests.swift
//  zodlTests
//
//  MOB-1581: the Activity list only refreshed on sync events and on the send flows' result-screen
//  Close buttons -- never at the moment a send reaches a terminal outcome, and never on the View
//  Transaction -> transaction detail -> close exit. An idle wallet emits no sync event until the
//  next block (~75s), so a just-sent transaction (already stored in the local DB at creation time)
//  could stay invisible in Activity for over a minute. The fix dispatches
//  `.fetchTransactionsForTheSelectedAccount` (a) the moment `sendDone` / `sendPartial` /
//  `sendFailed(_, true)` fires on any send-capable element, and (b) on every flow's
//  `transactionDetails(.closeDetailTapped)` arm. `sendFailed(_, false)` stored nothing, so it must
//  stay silent -- the one negative test below covers that.
//
//  Mirrors `RootTransactionsTests/RootTransactionsAccountSwitchTests.swift`'s established pattern:
//  a plain `Store` (not `TestStore`) driven with `LockIsolated` spies and polling, plus its own
//  file-private `baseNoOpDependencies` baseline and `.serialized` (Root.State touches the
//  process-global `@Shared(.inMemory(...))` keys).
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootSendCompletionRefreshTests {
    private static func walletAccount(idByte: UInt8) -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    // MARK: - Send Coord Flow -- send-terminal outcomes

    @Test func sendDoneInSendFlowRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 80)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.sendCoordFlowState.path.append(.sendConfirmation(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.sendCoordFlowState.path.ids.first)
        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .sendConfirmation(.sendDone)))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    @Test func requestZecSendDoneInSendFlowRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 81)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.sendCoordFlowState.path.append(.requestZecConfirmation(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.sendCoordFlowState.path.ids.first)
        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .requestZecConfirmation(.sendDone)))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    @Test func sendFailedWithStoredTransactionRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 82)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.sendCoordFlowState.path.append(.sendConfirmation(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.sendCoordFlowState.path.ids.first)
        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .sendConfirmation(.sendFailed(nil, true))))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    /// The negative case: `sendFailed(_, false)` means nothing was ever stored in the local DB, so
    /// there is nothing new for the Activity list to show -- no refetch must fire.
    @Test func sendFailedWithoutStoredTransactionDoesNotRefetch() async throws {
        let account = Self.walletAccount(idByte: 83)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.sendCoordFlowState.path.append(.sendConfirmation(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.sendCoordFlowState.path.ids.first)
        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .sendConfirmation(.sendFailed(nil, false))))))

        // No polling helper here on purpose -- there is nothing to wait FOR. Give a wrongly-firing
        // refetch a brief moment to land, then confirm nothing did.
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(fetchedAccounts.value.isEmpty)
    }

    @Test func sendPartialInSendFlowRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 84)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.sendCoordFlowState.path.append(.sendConfirmation(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.sendCoordFlowState.path.ids.first)
        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .sendConfirmation(.sendPartial([], []))))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    // MARK: - Scan Coord Flow

    @Test func scanFlowSendDoneRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 85)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.scanCoordFlowState.path.append(.sendConfirmation(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.scanCoordFlowState.path.ids.first)
        store.send(.scanCoordFlow(.path(.element(id: elementId, action: .sendConfirmation(.sendDone)))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    // MARK: - Sign with Keystone Coord Flow

    /// `SignWithKeystoneCoordFlow`'s send confirmation is a DIRECT child action
    /// (`.signWithKeystoneCoordFlow(.sendConfirmation(...))`), not a path element -- no element id
    /// to look up, unlike every other flow tested in this file.
    @Test func keystoneSignFlowSendDoneRefetchesTransactions() async {
        let account = Self.walletAccount(idByte: 86)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        store.send(.signWithKeystoneCoordFlow(.sendConfirmation(.sendDone)))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    // MARK: - Swap and Pay Coord Flow

    /// The Swap flow runs its own send with FLOW-LEVEL actions (`.swapAndPayCoordFlow(.sendDone)`),
    /// not a path element -- distinct from its Keystone path below.
    @Test func swapFlowOwnSendDoneRefetchesTransactions() async {
        let account = Self.walletAccount(idByte: 87)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        store.send(.swapAndPayCoordFlow(.sendDone))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    @Test func swapFlowKeystoneSendDoneRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 88)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.swapAndPayCoordFlowState.path.append(.confirmWithKeystone(SendConfirmation.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.swapAndPayCoordFlowState.path.ids.first)
        store.send(.swapAndPayCoordFlow(.path(.element(id: elementId, action: .confirmWithKeystone(.sendDone)))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    // MARK: - Transaction-detail close arms
    //
    // MOB-1581's second gap: closing the transaction detail screen reached via View Transaction
    // (from any of the four send-capable flows) previously refreshed nothing at all.

    @Test func detailCloseInSendFlowRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 89)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.sendCoordFlowState.path.append(.transactionDetails(TransactionDetails.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.sendCoordFlowState.path.ids.first)
        store.send(.sendCoordFlow(.path(.element(id: elementId, action: .transactionDetails(.closeDetailTapped)))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    @Test func detailCloseInScanFlowRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 90)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.scanCoordFlowState.path.append(.transactionDetails(TransactionDetails.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.scanCoordFlowState.path.ids.first)
        store.send(.scanCoordFlow(.path(.element(id: elementId, action: .transactionDetails(.closeDetailTapped)))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    /// Unlike the other three flows, this arm also flips `state.signWithKeystoneCoordFlowBinding`
    /// back to `false` -- that mutation is pre-existing behavior and not this test's concern; only
    /// the refetch is asserted here.
    @Test func detailCloseInKeystoneSignFlowRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 91)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.signWithKeystoneCoordFlowState.path.append(.transactionDetails(TransactionDetails.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.signWithKeystoneCoordFlowState.path.ids.first)
        store.send(.signWithKeystoneCoordFlow(.path(.element(id: elementId, action: .transactionDetails(.closeDetailTapped)))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }

    @Test func detailCloseInSwapFlowRefetchesTransactions() async throws {
        let account = Self.walletAccount(idByte: 92)
        let fetchedAccounts = LockIsolated<[AccountUUID?]>([])

        var initialState = Root.State.initial
        initialState.$selectedWalletAccount.withLock { $0 = account }
        initialState.swapAndPayCoordFlowState.path.append(.transactionDetails(TransactionDetails.State.initial))

        let store = Store(initialState: initialState) {
            Root()
        } withDependencies: {
            baseNoOpDependencies(&$0)
            $0.sdkSynchronizer.getAllTransactions = { accountUUID in
                fetchedAccounts.withValue { $0.append(accountUUID) }
                return []
            }
        }

        let elementId = try #require(store.state.swapAndPayCoordFlowState.path.ids.first)
        store.send(.swapAndPayCoordFlow(.path(.element(id: elementId, action: .transactionDetails(.closeDetailTapped)))))

        await waitForRefetch { fetchedAccounts.value.contains(account.id) }

        #expect(fetchedAccounts.value.contains(account.id))
    }
}

/// Shared no-op dependency baseline for every test in this file. Kept as a private, file-scoped
/// helper rather than something shared globally, the same way
/// `RootTransactionsTests/RootTransactionsAccountSwitchTests.swift` keeps its own private
/// `baseNoOpDependencies` local to that file.
@MainActor
private func baseNoOpDependencies(_ values: inout DependencyValues) {
    // Every positive test in this file dispatches an action that reaches `SendConfirmation`'s real
    // reducer (`.sendDone` / `.sendFailed` / `.sendPartial` all funnel into `.updateResult`, which
    // calls `audioServices.systemSoundVibrate()`) -- `AudioServicesClient` has no `testValue`, so
    // without this override every such test fails on "no test implementation" instead of on the
    // refetch assertion. Same override already used for the same reason in
    // `SendTests/MultiServerSubmitRoutingTests.swift` and `ScanTests/ScanCoordFlowZip321Tests.swift`.
    values.audioServices = AudioServicesClient(systemSoundVibrate: { })
    values.databaseFiles = .noOp
    values.derivationTool = .liveValue
    values.diskSpaceChecker = .mockFullDisk
    values.flexaHandler = .noOp
    values.localAuthentication = .mockAuthenticationSucceeded
    values.mainQueue = .immediate
    values.mnemonic = .mock
    values.readTransactionsStorage.resetZashi = { }
    values.sdkSynchronizer = .noOp
    values.userMetadataProvider.load = { _ in }
    values.walletStorage = .noOp
    values.zcashSDKEnvironment = .testnet
}

@MainActor
private func waitForRefetch(
    timeoutNanoseconds: UInt64 = 15_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for the send-completion transactions refetch", sourceLocation: sourceLocation)
}
