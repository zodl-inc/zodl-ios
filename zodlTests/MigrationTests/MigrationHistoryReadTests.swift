//
//  MigrationHistoryReadTests.swift
//  zodlTests
//
//  MOB-1861: the migration manager's wallet-confirmed set (`walletMinedTxIds`, GROUND_RULES R11)
//  used to come from `getAllTransactions` -- the whole history plus one output query per row --
//  and it was read even for a wallet with NO migration run, because the derivation that returns
//  nil for empty statuses received the set as an argument, evaluated first. On a 1,255-transaction
//  wallet with no run that was a 25 s read on every app open, before sync could start, and one
//  more on every Advanced Settings appearance (field, 2026-09-14). The set now comes from
//  `getMinedTransactionIds` (one `v_transactions` read), and only when a status row exists that
//  can consume it.
//
//  Fixture conventions mirror MigrationSweepBannerFreshnessTests: fixed-bytes AccountUUID, the
//  tip/activation pair, `withDependencies` + `SDKSynchronizerClient.mocked(...)`, a scoped
//  schedule storage, `.serialized` because the wallet-wide candidate set rides
//  `@Shared(.inMemory(...))`.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(2))) struct MigrationHistoryReadTests {
    private static let accountUUID = AccountUUID(id: [UInt8](repeating: 0x6B, count: 16))
    private static let activationHeight: BlockHeight = 4_134_000
    private static let tip: BlockHeight = 4_200_000
    private static let suiteName = "MigrationHistoryReadTests"
    private static let broadcastTxId = Data([0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89])

    private struct ReadFailure: Error { }

    private static func caughtUpState() -> SynchronizerState {
        var state = SynchronizerState.zero
        state.latestBlockHeight = tip
        state.syncStatus = SyncStatus.upToDate
        return state
    }

    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: accountUUID,
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func installCandidateAccount() {
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        $selectedWalletAccount.withLock { $0 = Self.account() }
        $walletAccounts.withLock { $0 = [Self.account()] }
    }

    /// A fresh schedule storage over a wiped named suite: no committed schedule, so the manager
    /// takes the status-only lane, and isolation from the standard defaults.
    private static func makeManager() -> MigrationManagerImpl {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return MigrationManagerImpl(scheduleStorage: MigrationScheduleStorage(userDefaults: defaults))
    }

    private static func transferStatus(state: MigrationTransactionStatus.State) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: 1,
            kind: MigrationTransactionStatus.Kind.transfer(crossing: 0),
            state: state,
            scheduledHeight: 4_199_990,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    private static func preparationStatus(state: MigrationTransactionStatus.State) -> MigrationTransactionStatus {
        MigrationTransactionStatus(
            id: 7,
            kind: MigrationTransactionStatus.Kind.preparation(layer: 0, index: 0),
            state: state,
            scheduledHeight: 4_199_990,
            expiryHeight: nil,
            isReady: false,
            nextAction: nil,
            blockedOn: nil,
            dependsOn: [],
            anchorBoundaryHeight: nil
        )
    }

    // MARK: - (1) No run: no history read at all

    /// Empty statuses and no committed schedule -- every wallet that never migrated. Neither the
    /// full-history read nor the mined-id read may run, on any of the three surfaces that derive
    /// rows: the transfer rows, the preparation rows, and the view snapshot Advanced Settings and
    /// the banner build from.
    @Test func aWalletWithNoRunNeverReadsTheTransactionHistory() async {
        Self.installCandidateAccount()
        let historyReads = LockIsolated<Int>(0)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.caughtUpState() },
                migrationTransactionStatuses: { _ in [] },
                getAllTransactions: { _ in
                    historyReads.withValue { $0 += 1 }
                    return []
                },
                getMinedTransactionIds: { _ in
                    historyReads.withValue { $0 += 1 }
                    return []
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = Self.makeManager()

            let transfers = await manager.migrationTransfers(accountUUID: Self.accountUUID)
            let preparations = await manager.migrationPreparationRows(accountUUID: Self.accountUUID)
            _ = await manager.migrationViewSnapshot(accountUUID: Self.accountUUID)

            #expect(transfers.isEmpty)
            #expect(preparations == nil)
            #expect(historyReads.value == 0, "a wallet with no run must not pay for a transaction-history read")
        }
    }

    // MARK: - (2) A broadcast transfer reads the mined ids once and renders from them

    /// One transfer the engine reports as broadcast. The wallet-confirmed set decides the row:
    /// `.confirming` until the wallet's own store has the txid mined, `.sent` after. The set must
    /// come from `getMinedTransactionIds`, exactly once per derivation, never from
    /// `getAllTransactions`.
    @Test func aBroadcastTransferReadsTheMinedIdsOnceAndRendersFromThem() async {
        Self.installCandidateAccount()
        let minedIdReads = LockIsolated<Int>(0)
        let historyReads = LockIsolated<Int>(0)
        let walletHasSeenIt = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.caughtUpState() },
                migrationTransactionStatuses: { _ in
                    [Self.transferStatus(state: MigrationTransactionStatus.State.broadcast(txid: Self.broadcastTxId))]
                },
                getAllTransactions: { _ in
                    historyReads.withValue { $0 += 1 }
                    return []
                },
                getMinedTransactionIds: { _ in
                    minedIdReads.withValue { $0 += 1 }
                    return walletHasSeenIt.value ? [Self.broadcastTxId.toHexStringTxId()] : []
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = Self.makeManager()

            let confirming = await manager.migrationTransfers(accountUUID: Self.accountUUID)
            #expect(confirming.map(\.status) == [MigrationTransferRow.Status.confirming])
            #expect(minedIdReads.value == 1, "the mined-id read runs once per derivation")
            #expect(historyReads.value == 0, "the whole-history read is gone from this path")

            walletHasSeenIt.setValue(true)
            let sent = await manager.migrationTransfers(accountUUID: Self.accountUUID)
            #expect(sent.map(\.status) == [MigrationTransferRow.Status.sent])
            #expect(minedIdReads.value == 2)
            #expect(historyReads.value == 0)
        }
    }

    // MARK: - (3) A failed mined-id read serves the last known set

    /// R11's degradation rule, unchanged by the cheaper read: a transient failure must not repaint
    /// a green row as "Confirming…" -- the last successfully read set stands.
    @Test func aFailedMinedIdReadServesTheLastKnownSet() async {
        Self.installCandidateAccount()
        let shouldFail = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.caughtUpState() },
                migrationTransactionStatuses: { _ in
                    [Self.transferStatus(state: MigrationTransactionStatus.State.broadcast(txid: Self.broadcastTxId))]
                },
                getMinedTransactionIds: { _ in
                    if shouldFail.value {
                        throw ReadFailure()
                    }
                    return [Self.broadcastTxId.toHexStringTxId()]
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = Self.makeManager()

            let firstRead = await manager.migrationTransfers(accountUUID: Self.accountUUID)
            #expect(firstRead.map(\.status) == [MigrationTransferRow.Status.sent])

            shouldFail.setValue(true)
            let afterFailure = await manager.migrationTransfers(accountUUID: Self.accountUUID)
            #expect(
                afterFailure.map(\.status) == [MigrationTransferRow.Status.sent],
                "a failed read must serve the cached set, never un-confirm the row"
            )
        }
    }

    // MARK: - (4) The preparation lane reads the mined ids too, and renders from them

    /// The transfer lane's mirror for `migrationPreparationRows` — the OTHER gated surface, and the
    /// one whose failure mode is silent. `preparationRows` greens a `.broadcast(txid:)` split only
    /// when the set contains its display-form txid, and greens a `.mined` split only when the set
    /// contains the txid the manager remembered from that split's earlier broadcast; with NO set at
    /// all (`confirmedTxIds == nil`) its `.mined` arm falls back to ENGINE truth and greens
    /// unconditionally. So if `hasPreparationStatus` ever answered false for real preparations, the
    /// set would arrive nil, split rows would green one privacy window early, and R11 would be
    /// silently reverted for preparations. Phase 3 is the assertion that catches exactly that: a
    /// `.mined` split whose txid the wallet has NOT seen must read `.confirming`, which a nil set
    /// could not produce.
    @Test func aBroadcastPreparationReadsTheMinedIdsOnceAndRendersFromThem() async {
        Self.installCandidateAccount()
        let minedIdReads = LockIsolated<Int>(0)
        let historyReads = LockIsolated<Int>(0)
        let walletHasSeenIt = LockIsolated<Bool>(false)
        let engineReportsMined = LockIsolated<Bool>(false)

        await withDependencies {
            $0.sdkSynchronizer = .mocked(
                latestState: { Self.caughtUpState() },
                migrationTransactionStatuses: { _ in
                    if engineReportsMined.value {
                        return [Self.preparationStatus(state: MigrationTransactionStatus.State.mined(height: Self.tip - 2))]
                    }
                    return [Self.preparationStatus(state: MigrationTransactionStatus.State.broadcast(txid: Self.broadcastTxId))]
                },
                getAllTransactions: { _ in
                    historyReads.withValue { $0 += 1 }
                    return []
                },
                getMinedTransactionIds: { _ in
                    minedIdReads.withValue { $0 += 1 }
                    return walletHasSeenIt.value ? [Self.broadcastTxId.toHexStringTxId()] : []
                }
            )
            $0.zcashSDKEnvironment.ironwoodActivationHeight = { Self.activationHeight }
        } operation: {
            let manager = Self.makeManager()

            // (1) Broadcast, wallet has not seen it: `.confirming`, from the mined-id read alone.
            let confirming = await manager.migrationPreparationRows(accountUUID: Self.accountUUID)
            #expect(confirming?.map(\.status) == [MigrationTransferRow.Status.confirming])
            #expect(confirming?.map(\.kind) == [MigrationTransferRow.Kind.splitBalance])
            #expect(minedIdReads.value == 1, "the mined-id read runs once per derivation")
            #expect(historyReads.value == 0, "the whole-history read is gone from this path too")

            // (2) Same broadcast, now in the wallet's own store: green.
            walletHasSeenIt.setValue(true)
            let sent = await manager.migrationPreparationRows(accountUUID: Self.accountUUID)
            #expect(sent?.map(\.status) == [MigrationTransferRow.Status.sent])
            #expect(minedIdReads.value == 2)
            #expect(historyReads.value == 0)

            // (3) The engine now calls it mined while the wallet has NOT seen it — the privacy
            // window R11 exists for. The join is the txid remembered from phases 1-2, and the row
            // must un-green. A nil set here would read `.sent` instead.
            engineReportsMined.setValue(true)
            walletHasSeenIt.setValue(false)
            let engineMinedOnly = await manager.migrationPreparationRows(accountUUID: Self.accountUUID)
            #expect(
                engineMinedOnly?.map(\.status) == [MigrationTransferRow.Status.confirming],
                "engine-mined is not green until the wallet's own store has the remembered txid"
            )
            #expect(minedIdReads.value == 3)
            #expect(historyReads.value == 0)

            // (4) The wallet catches up on the same remembered txid: green.
            walletHasSeenIt.setValue(true)
            let walletConfirmed = await manager.migrationPreparationRows(accountUUID: Self.accountUUID)
            #expect(walletConfirmed?.map(\.status) == [MigrationTransferRow.Status.sent])
            #expect(minedIdReads.value == 4)
            #expect(historyReads.value == 0)
        }
    }
}
