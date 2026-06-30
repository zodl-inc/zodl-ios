//
//  MigrationSDKLiveKey.swift
//  zodl
//
//  Production registration of `MigrationSDKClient`. `liveValue` is backed by the SDK via
//  `LiveMigrationEngine`; `previewValue` keeps the deterministic `DummyMigrationEngine` for SwiftUI
//  previews and tests. The `dummy(...)` factory is also reused by `MigrationSDKClient.ephemeral()`.
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension MigrationSDKClient: DependencyKey {
    static let liveValue: MigrationSDKClient = Self.live()
    static let previewValue: MigrationSDKClient = Self.dummy(store: .ephemeral(), runLogStore: .ephemeral())

    /// Production: the migration is driven by the real SDK behind `LiveMigrationEngine`. The
    /// MigrationDebug controls are inert here — they only make sense against the simulation.
    static func live(
        store: MigrationStateStore = .live(fileURL: MigrationStateStore.defaultFileURL),
        runLogStore: MigrationRunLogStore = .live(fileURL: MigrationRunLogStore.defaultFileURL)
    ) -> MigrationSDKClient {
        let engine = LiveMigrationEngine(store: store, gateway: .live())

        return MigrationSDKClient(
            getMigrationState: { engine.currentState() },
            stateStream: { engine.statePublisher() },
            getMigrationProgress: { engine.progress() },
            isNoteSplitNeeded: { engine.noteSplitNeeded() },
            prepareNoteSplit: { await engine.prepareSplit() },
            submitNoteSplit: { await engine.submitSplit($0) },
            proposeMigrationTransfers: { await engine.propose() },
            signAndStoreMigrationSchedule: { await engine.signAndStore($0) },
            isSyncRequiredBeforeNextTransfer: { engine.syncRequiredBeforeNext() },
            executeNextPendingTransfer: { await engine.executeNext($0) },
            hasOverdueTransfers: { engine.overdue() },
            hasInvalidTransfers: { engine.invalid() },
            restartCurrentMigrationStep: { await engine.restart() },
            rescheduleStalledTransfer: { await engine.rescheduleStalled() },
            recreateInvalidTransfer: { await engine.recreateInvalid() },
            initializePostUpgrade: { engine.initializePostUpgrade() },
            selectMigrationMode: { engine.selectMode($0) },
            simulatedOrchardBalance: { engine.orchardBalance() },
            migrationSummary: { engine.summary() },
            migrationTransfers: { engine.transferRows() },
            isMigrationCompleteAcknowledged: { engine.isCompletionAcknowledged() },
            acknowledgeMigrationComplete: { engine.acknowledgeCompletion() },
            recordBackgroundRun: { runLogStore.append(MigrationBackgroundRun(timestamp: Date(), outcome: $0)) },
            backgroundRunLog: { runLogStore.load() },
            clearBackgroundRunLog: { runLogStore.clear() },
            // Debug controls don't apply to real funds — the MigrationDebug panel goes inert in live.
            debug: MigrationDebugControls(
                snapshotDescription: { "Live migration engine — debug controls are disabled." }
            )
        )
    }

    /// Simulation: backed by `DummyMigrationEngine`. Used by `previewValue`, `ephemeral()`, and tests.
    static func dummy(
        store: MigrationStateStore = .ephemeral(),
        runLogStore: MigrationRunLogStore = .ephemeral()
    ) -> MigrationSDKClient {
        let engine = DummyMigrationEngine(store: store)

        return MigrationSDKClient(
            getMigrationState: { engine.currentState() },
            stateStream: { engine.statePublisher() },
            getMigrationProgress: { engine.progress() },
            isNoteSplitNeeded: { engine.noteSplitNeeded() },
            prepareNoteSplit: { await engine.prepareSplit() },
            submitNoteSplit: { await engine.submitSplit($0) },
            proposeMigrationTransfers: { await engine.propose() },
            signAndStoreMigrationSchedule: { await engine.signAndStore($0) },
            isSyncRequiredBeforeNextTransfer: { engine.syncRequiredBeforeNext() },
            executeNextPendingTransfer: { await engine.executeNext($0) },
            hasOverdueTransfers: { engine.overdue() },
            hasInvalidTransfers: { engine.invalid() },
            restartCurrentMigrationStep: { await engine.restart() },
            rescheduleStalledTransfer: { await engine.rescheduleStalled() },
            recreateInvalidTransfer: { await engine.recreateInvalid() },
            initializePostUpgrade: { engine.initializePostUpgrade() },
            selectMigrationMode: { engine.selectMode($0) },
            simulatedOrchardBalance: { engine.orchardBalance() },
            migrationSummary: { engine.summary() },
            migrationTransfers: { engine.transferRows() },
            isMigrationCompleteAcknowledged: { engine.isCompletionAcknowledged() },
            acknowledgeMigrationComplete: { engine.acknowledgeCompletion() },
            recordBackgroundRun: { runLogStore.append(MigrationBackgroundRun(timestamp: Date(), outcome: $0)) },
            backgroundRunLog: { runLogStore.load() },
            clearBackgroundRunLog: { runLogStore.clear() },
            debug: MigrationDebugControls(
                reset: { await engine.debugReset() },
                seed: { await engine.debugSeed(orchard: $0, noteCount: $1) },
                advanceHeight: { await engine.debugAdvanceHeight($0) },
                confirmSplitNow: { await engine.debugConfirmSplit() },
                armNextTransferResult: { await engine.debugArm($0) },
                jumpTo: { await engine.debugJump($0) },
                snapshotDescription: { engine.debugSnapshotDescription() }
            )
        )
    }
}

// MARK: - Live gateway

extension LiveMigrationEngine.Gateway {
    /// Wires the engine's `Gateway` to the real SDK via `@Dependency(\.sdkSynchronizer)`, plus account
    /// and spending-key sourcing from the currently selected account (the Send flow's path). Each
    /// closure resolves its dependencies at call time so test overrides apply. The transaction guard
    /// for the two broadcasting calls lives in `SDKSynchronizerLive` — never here.
    static func live() -> LiveMigrationEngine.Gateway {
        LiveMigrationEngine.Gateway(
            currentAccountID: {
                @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount?
                return selectedWalletAccount?.id
            },
            orchardBalance: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                let balances = try await sdkSynchronizer.getAccountsBalances()
                return balances[account]?.orchardBalance.spendableValue ?? .zero
            },
            state: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationState(account)
            },
            progress: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationProgress(account)
            },
            isNoteSplitNeeded: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationIsNoteSplitNeeded(account)
            },
            prepareNoteSplit: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationPrepareNoteSplit(account)
            },
            submitNoteSplit: { proposal, options, account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                let spendingKey = try MigrationSDKClient.currentAccountSpendingKey()
                return try await sdkSynchronizer.migrationSubmitNoteSplit(proposal, spendingKey, options, account)
            },
            proposeTransfers: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationProposeTransfers(account)
            },
            signAndStore: { schedule, account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                let spendingKey = try MigrationSDKClient.currentAccountSpendingKey()
                try await sdkSynchronizer.migrationSignAndStoreSchedule(schedule, spendingKey, account)
            },
            isSyncRequiredBeforeNextTransfer: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationIsSyncRequiredBeforeNextTransfer(account)
            },
            executeNext: { options, account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationExecuteNextPendingTransfer(options, account)
            },
            hasOverdueTransfers: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationHasOverdueTransfers(account)
            },
            hasInvalidTransfers: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationHasInvalidTransfers(account)
            },
            restartCurrentStep: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                return try await sdkSynchronizer.migrationRestartCurrentStep(account)
            },
            refreshStale: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                let spendingKey = try MigrationSDKClient.currentAccountSpendingKey()
                return try await sdkSynchronizer.migrationRefreshStaleTransfers(spendingKey, account)
            },
            initializePostUpgrade: { account in
                @Dependency(\.sdkSynchronizer) var sdkSynchronizer
                try await sdkSynchronizer.migrationInitializePostUpgrade(account)
            }
        )
    }
}

// MARK: - Account spending key (Send-flow parity)

extension MigrationSDKClient {
    enum LiveError: Error {
        /// No wallet account is currently selected, so a spending key cannot be derived.
        case noActiveAccount
    }

    /// Derives the `UnifiedSpendingKey` for the currently selected account, exactly as the Send flow
    /// does (walletStorage → mnemonic seed → derivationTool). Used by the two signing migration calls.
    static func currentAccountSpendingKey() throws -> UnifiedSpendingKey {
        @Dependency(\.walletStorage) var walletStorage
        @Dependency(\.mnemonic) var mnemonic
        @Dependency(\.derivationTool) var derivationTool
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount?

        guard let zip32AccountIndex = selectedWalletAccount?.zip32AccountIndex else {
            throw LiveError.noActiveAccount
        }
        let storedWallet = try walletStorage.exportWallet()
        let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
        let network = zcashSDKEnvironment.network().networkType
        return try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, network)
    }
}
