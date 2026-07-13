//
//  SDKSynchronizerLive.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Foundation
@preconcurrency import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
@preconcurrency import KeystoneSDK
import os

private let slipstreamLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "co.ecc.zashi", category: "slipstream")

extension SDKSynchronizerClient: DependencyKey {
    static let liveValue: SDKSynchronizerClient = Self.live()
    
    static func live(
        databaseFiles: DatabaseFilesClient = .liveValue
    ) -> Self {
        @Shared(.inMemory(.swapAPIAccess)) var swapAPIAccess: WalletStorage.SwapAPIAccess = .direct
        @Dependency(\.userStoredPreferences) var userStoredPreferences
        @Dependency(\.walletStorage) var walletStorage
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

        let isTorEnabled = walletStorage.exportTorSetupFlag() ?? false
        let isRateEnabled = userStoredPreferences.exchangeRate()?.automatic ?? false

        $swapAPIAccess.withLock { $0 = isTorEnabled ? .protected : .direct }
        
        let network = zcashSDKEnvironment.network()
        
        #if DEBUG
        let loggingPolicy = Initializer.LoggingPolicy.default(.debug)
        #else
        let loggingPolicy = Initializer.LoggingPolicy.noLogging
        #endif
        
        let initializer = Initializer(
            cacheDbURL: databaseFiles.cacheDbURLFor(network),
            fsBlockDbRoot: databaseFiles.fsBlockDbRootFor(network),
            generalStorageURL: databaseFiles.documentsDirectory(),
            dataDbURL: databaseFiles.dataDbURLFor(network),
            torDirURL: databaseFiles.toDirURLFor(network),
            endpoint: zcashSDKEnvironment.endpoint(),
            network: network,
            spendParamsURL: databaseFiles.spendParamsURLFor(network),
            outputParamsURL: databaseFiles.outputParamsURLFor(network),
            saplingParamsSourceURL: SaplingParamsSourceURL.default,
            loggingPolicy: loggingPolicy,
            isTorEnabled: isTorEnabled,
            isExchangeRateEnabled: isRateEnabled
        )
        
        // [#1755] slipstream: engine selection from the synchronously-readable flag cache (the async
        // WalletConfigProvider.load() can't be awaited here; the cache is the early-construction shortcut).
        let useSlipstream = UserDefaultsWalletConfigStorage.cachedFlag(.useSlipstreamSynchronizer)

        let synchronizer: any Synchronizer
        if useSlipstream {
            slipstreamLogger.info("[#1755] SlipstreamSynchronizer CONSTRUCTED (useSlipstreamSynchronizer=true)")
            LoggerProxy.debug("[#1755] SlipstreamSynchronizer: selected (useSlipstreamSynchronizer=true)")
            synchronizer = SlipstreamSynchronizer(initializer: initializer)
        } else {
            slipstreamLogger.info("[#1755] SDKSynchronizer CONSTRUCTED (useSlipstreamSynchronizer=false)")
            LoggerProxy.debug("[#1755] SDKSynchronizer: selected (useSlipstreamSynchronizer=false)")
            synchronizer = SDKSynchronizer(initializer: initializer)
        }

        return SDKSynchronizerClient(
            stateStream: { synchronizer.stateStream },
            eventStream: { synchronizer.eventStream },
            exchangeRateUSDStream: { synchronizer.exchangeRateUSDStream },
            latestState: { synchronizer.latestState },
            prepareWith: { seedBytes, walletBirtday, name, keySource in
                let result = try await synchronizer.prepare(
                    with: seedBytes,
                    walletBirthday: walletBirtday,
                    name: name,
                    keySource: keySource
                )
                if result != .success { throw ZcashError.synchronizerNotPrepared }
            },
            start: { retry in try await synchronizer.start(retry: retry) },
            stop: { synchronizer.stop() },
            isSyncing: { synchronizer.latestState.syncStatus.isSyncing },
            isInitialized: { synchronizer.latestState.syncStatus != SyncStatus.unprepared },
            importAccount: { ufvk, seedFingerprint, zip32AccountIndex, purpose, name, keySource, birthday in
                try await synchronizer.importAccount(
                    ufvk: ufvk,
                    seedFingerprint: seedFingerprint,
                    zip32AccountIndex: zip32AccountIndex,
                    purpose: purpose,
                    name: name,
                    keySource: keySource,
                    birthday: birthday
                )
            },
            deleteAccount: { accountUUID in
                try await synchronizer.deleteAccount(accountUUID)
            },
            rescanFrom: { blockHeight in
                try await synchronizer.rescanFrom(height: blockHeight)
            },
            rewind: { synchronizer.rewind($0) },
            getAllTransactions: { accountUUID in
                let clearedTransactions = try await synchronizer.allTransactions()
                
                return try await SDKSynchronizerClient.transactionStatesFromZcashTransactions(
                    accountUUID: accountUUID,
                    zcashTransactions: clearedTransactions,
                    synchronizer: synchronizer
                )
            },
            transactionStatesFromZcashTransactions: { accountUUID, zcashTransactions in
                try await SDKSynchronizerClient.transactionStatesFromZcashTransactions(
                    accountUUID: accountUUID,
                    zcashTransactions: zcashTransactions,
                    synchronizer: synchronizer
                )
            },
            getMemos: { try await synchronizer.getMemos(for: $0) },
            txIdExists: { txId in
                guard let txId else {
                    return false
                }
                
                let allTransactions = try await synchronizer.allTransactions()

                return allTransactions.contains(where: { $0.rawID.toHexStringTxId() == txId })
            },
            getUnifiedAddress: { try await synchronizer.getUnifiedAddress(accountUUID: $0) },
            getTransparentAddress: { try await synchronizer.getTransparentAddress(accountUUID: $0) },
            getSaplingAddress: { try await synchronizer.getSaplingAddress(accountUUID: $0) },
            getAccountsBalances: { try await synchronizer.getAccountsBalances() },
            wipe: { synchronizer.wipe() },
            switchToEndpoint: { endpoint in
                try await synchronizer.switchTo(endpoint: endpoint)
            },
            proposeTransfer: { accountUUID, recipient, amount, memo in
                try await synchronizer.proposeTransfer(
                    accountUUID: accountUUID,
                    recipient: recipient,
                    amount: amount,
                    memo: memo
                )
            },
            createAndSubmitProposedTransactions: { proposal, spendingKey in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let transactions = try await synchronizer.broadcaster.createProposedTransactions(
                        proposal: proposal,
                        spendingKey: spendingKey
                    )

                    return await Self.submitCreatedTransactions(
                        transactions,
                        logPrefix: "[MultiSubmit]",
                        userStoredPreferences: userStoredPreferences,
                        zcashSDKEnvironment: zcashSDKEnvironment,
                        submit: { createdTransactions, endpoints in
                            await Self.submitTransactionsIndividually(createdTransactions, to: endpoints) { transaction, endpoints in
                                await synchronizer.broadcaster.submit(transaction: transaction, to: endpoints)
                            }
                        }
                    )
                }
            },
            proposeShielding: { accountUUID, shieldingThreshold, memo, transparentReceiver in
                try await synchronizer.proposeShielding(
                    accountUUID: accountUUID,
                    shieldingThreshold: shieldingThreshold,
                    memo: memo,
                    transparentReceiver: transparentReceiver
                )
            },
            isSeedRelevantToAnyDerivedAccount: { seed in
                try await synchronizer.isSeedRelevantToAnyDerivedAccount(seed: seed)
            },
            refreshExchangeRateUSD: {
                synchronizer.refreshExchangeRateUSD()
            },
            evaluateBestOf: { endpoints, fetchThreshold, nBlocks, kServers, network in
                await synchronizer.evaluateBestOf(
                    endpoints: endpoints,
                    fetchThresholdSeconds: fetchThreshold,
                    nBlocksToFetch: nBlocks,
                    kServers: kServers,
                    network: network
                )
            },
            walletAccounts: {
                // get the Accounts and map it to WalletAccounts
                var walletAccounts = try await synchronizer.listAccounts().map {
                    WalletAccount($0)
                }
                
                // Enrich the WalletAccounts with UnifiedAddresses
                for i in 0..<walletAccounts.count {
                    walletAccounts[i].defaultUA = try? await synchronizer.getUnifiedAddress(accountUUID: walletAccounts[i].id)
                    walletAccounts[i].privateUA = try? await synchronizer.getCustomUnifiedAddress(
                        accountUUID: walletAccounts[i].id,
                        receivers: walletAccounts[i].vendor == .keystone ? [.orchard] : [.sapling, .orchard]
                    )
                }
                
                // Put the Zashi account to the top
                let sortedWalletAccounts = walletAccounts.sorted { $0.vendor.rawValue > $1.vendor.rawValue }

                return sortedWalletAccounts
            },
            estimateBirthdayHeight: { date in
                synchronizer.estimateBirthdayHeight(for: date)
            },
            estimateTimestamp: { blockHeight in
                synchronizer.estimateTimestamp(for: blockHeight)
            },
            createPCZTFromProposal: { accountUUID, proposal in
                try await synchronizer.createPCZTFromProposal(accountUUID: accountUUID, proposal: proposal)
            },
            addProofsToPCZT: { pczt in
                try await synchronizer.addProofsToPCZT(pczt: pczt)
            },
            createAndSubmitTransactionFromPCZT: { pcztWithProofs, pcztWithSigs in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    let transactions = try await synchronizer.broadcaster.createTransactionFromPCZT(
                        pcztWithProofs: pcztWithProofs,
                        pcztWithSigs: pcztWithSigs
                    )

                    return await Self.submitCreatedTransactions(
                        transactions,
                        logPrefix: "[MultiSubmit/PCZT]",
                        userStoredPreferences: userStoredPreferences,
                        zcashSDKEnvironment: zcashSDKEnvironment,
                        submit: { createdTransactions, endpoints in
                            await Self.submitTransactionsIndividually(createdTransactions, to: endpoints) { transaction, endpoints in
                                await synchronizer.broadcaster.submit(transaction: transaction, to: endpoints)
                            }
                        }
                    )
                }
            },
            urEncoderForPCZT: { pczt in
                let keystoneSDK = KeystoneZcashSDK()

                let encoder = try? keystoneSDK.generateZcashPczt(pczt_hex: pczt)
                
                return encoder
            },
            redactPCZTForSigner: { pczt in
                try await synchronizer.redactPCZTForSigner(pczt: pczt)
            },
            fetchTxidsWithMemoContaining: { searchTerm in
                try await synchronizer.fetchTxidsWithMemoContaining(searchTerm: searchTerm)
            },
            getCustomUnifiedAddress: { accountUUID, receivers in
                try await synchronizer.getCustomUnifiedAddress(accountUUID: accountUUID, receivers: receivers)
            },
            torEnabled: { [sharedSwapAPIAccess = $swapAPIAccess] enabled in
                // Keep the app-level HTTP routing flag in sync with every runtime Tor
                // toggle, not only with the stored value read at synchronizer
                // construction. Updated before the SDK call so a failed Tor init
                // fails closed (requests keep using the protected path) instead of
                // silently egressing directly.
                sharedSwapAPIAccess.withLock { $0 = enabled ? .protected : .direct }
                try await synchronizer.tor(enabled: enabled)
            },
            exchangeRateEnabled: { enabled in
                try await synchronizer.exchangeRateOverTor(enabled: enabled)
            },
            isTorSuccessfullyInitialized: {
                await synchronizer.isTorSuccessfullyInitialized()
            },
            httpRequestOverTor: { request in
                // retryLimit passed explicitly — protocol default arguments aren't callable
                // through the `any Synchronizer` existential.
                try await synchronizer.httpRequestOverTor(for: request, retryLimit: 3)
            },
            debugDatabaseSql: { query in
                synchronizer.debugDatabase(sql: query)
            },
            getSingleUseTransparentAddress: { accountUUID in
                try await synchronizer.getSingleUseTransparentAddress(accountUUID: accountUUID)
            },
            checkSingleUseTransparentAddresses: { accountUUID in
                try await synchronizer.checkSingleUseTransparentAddresses(accountUUID: accountUUID)
            },
            updateTransparentAddressTransactions: { address in
                try await synchronizer.updateTransparentAddressTransactions(address: address)
            },
            fetchUTXOsByAddress: { address, accountUUID in
                try await synchronizer.fetchUTXOsBy(address: address, accountUUID: accountUUID)
            },
            enhanceTransactionBy: { txId in
                try await synchronizer.enhanceTransactionBy(txId: TxId(txId))
            },
            // A read, but guarded on purpose: the voting flow's round-snapshot fetch must not
            // race a server switch, and any future caller queues FIFO behind in-flight
            // broadcasts/switches — do not call this from a latency-sensitive path.
            getTreeState: { height in
                @Dependency(\.transactionGuard) var transactionGuard
                return try await transactionGuard.withSubmission {
                    try await synchronizer.getTreeState(height: height)
                }
            },
            // Migration (Orchard → Ironwood) — STUB: the SDK API does not exist yet (MOB-1455).
            // These compile the app against the expected contract and do nothing. When the real
            // SDK lands, replace these closures here. The three broadcast-path stubs
            // (`submitNoteSplit`, `executeNextPendingMigrationTransfer`, `submitSignedNoteSplit`)
            // already acquire the transaction guard below — same `withSubmission` pattern as
            // `createAndSubmitProposedTransactions` — so they are correct-by-construction once
            // real broadcasting lands; every other migration stub here is read-only/non-broadcast
            // and stays unguarded. `storeSignedMigrationTransactions` (Keystone/PCZT path) is
            // local storage, not a broadcast, so it stays unguarded too — MOB-1468. The two batch
            // members (`urEncoderForMigrationPCZTBatch`, `parseMigrationPCZTBatch`) are plain
            // inert stubs — their real implementations belong to KeystoneSDK/the Zcash SDK when
            // the batch UR format exists (joint SDK + Keystone-team ask, unvalidated).
            getMigrationState: { .notStarted },
            migrationStateStream: { Just(MigrationState.notStarted).eraseToAnyPublisher() },
            getMigrationProgress: { nil },
            isNoteSplitNeeded: { false },
            prepareNoteSplit: { NoteSplitProposal(outputNotes: [], fee: Zatoshi.zero) },
            submitNoteSplit: { _ in
                @Dependency(\.transactionGuard) var transactionGuard
                do {
                    return try await transactionGuard.withSubmission {
                        TransferResult.success(txId: "")
                    }
                } catch {
                    return TransferResult.networkError(retryable: true)
                }
            },
            selectMigrationMode: { _ in },
            proposeMigrationTransfers: { MigrationSchedule(transfers: [], estimatedDurationHours: 0) },
            signAndStoreMigrationSchedule: { _ in },
            isSyncRequiredBeforeNextMigrationTransfer: { false },
            executeNextPendingMigrationTransfer: { _ in
                @Dependency(\.transactionGuard) var transactionGuard
                do {
                    return try await transactionGuard.withSubmission {
                        let stubResult: TransferResult? = nil
                        return stubResult
                    }
                } catch {
                    return nil
                }
            },
            hasOverdueMigrationTransfers: { false },
            hasInvalidMigrationTransfers: { false },
            restartCurrentMigrationStep: { MigrationSchedule(transfers: [], estimatedDurationHours: 0) },
            rescheduleStalledMigrationTransfer: { },
            recreateInvalidMigrationTransfer: { },
            migrationSummary: { MigrationSummary.zero },
            migrationTransfers: { [] },
            proposeNoteSplitPCZT: { Pczt() },
            proposeMigrationPCZTs: { _ in [] },
            storeSignedMigrationTransactions: { _ in },
            submitSignedNoteSplit: { _ in
                @Dependency(\.transactionGuard) var transactionGuard
                do {
                    return try await transactionGuard.withSubmission {
                        TransferResult.success(txId: "")
                    }
                } catch {
                    return TransferResult.networkError(retryable: true)
                }
            },
            urEncoderForMigrationPCZTBatch: { _ in nil },
            parseMigrationPCZTBatch: { _ in nil },
            initializeMigrationPostUpgrade: { }
        )
    }
}

// MARK: - Multi-server submission

extension SDKSynchronizerClient {
    enum MultiServerSubmission {
        static let noTransactionsDescription = "No transactions created"
        static let notAttemptedStatus = "notAttempted"
        static let timeoutDescription = "Timed out waiting for endpoint response; transaction may still have been broadcast"
        // The SDK reports `.unreachable` when every endpoint failed at the transport level and
        // no server-level rejection was observed — never label that "rejected" in support data.
        static let unreachableStatus = "all servers unreachable"
        static let cancelledStatus = "submission cancelled"
    }

    /// Submits one transaction at a time so every one of them gets its retry plan recorded by the
    /// SDK. The SDK's batch `submit(transactions:to:)` stops at the first transaction that isn't
    /// accepted and leaves the remaining ones awaiting — excluded from the SDK's background
    /// resubmission until the app submits them, which it never does separately. Submitting each
    /// transaction restores the pre-Broadcaster behavior where background resubmission kept
    /// rebroadcasting every created transaction until it mined or expired.
    static func submitTransactionsIndividually(
        _ transactions: [CreatedTransaction],
        to endpoints: [LightWalletEndpoint],
        submitSingle: (CreatedTransaction, [LightWalletEndpoint]) async -> TransactionSubmissionOutcome
    ) async -> [(txId: Data, outcome: TransactionSubmissionOutcome)] {
        var reports: [(txId: Data, outcome: TransactionSubmissionOutcome)] = []
        for transaction in transactions {
            let outcome = await submitSingle(transaction, endpoints)
            reports.append((txId: transaction.txId, outcome: outcome))
        }

        return reports
    }

    /// Submits already-created transactions to the endpoints selected by the user's connection
    /// mode and maps the SDK submission reports onto `CreateProposedTransactionsResult`.
    ///
    /// Note on the transaction guard: the SDK resumes each submission as soon as its outcome is
    /// decided; after a first acceptance, the remaining in-flight broadcasts continue for a short
    /// grace window in the background, slightly outliving the caller's `withSubmission` window.
    /// That tail is safe — those broadcasts run on their own ephemeral connections, so a server
    /// switch that follows the guard release cannot corrupt them.
    static func submitCreatedTransactions(
        _ transactions: [CreatedTransaction],
        logPrefix: String,
        userStoredPreferences: UserPreferencesStorageClient,
        zcashSDKEnvironment: ZcashSDKEnvironment,
        submit: ([CreatedTransaction], [LightWalletEndpoint]) async -> [(txId: Data, outcome: TransactionSubmissionOutcome)]
    ) async -> CreateProposedTransactionsResult {
        guard !transactions.isEmpty else {
            return .failure(txIds: [], code: -1, description: MultiServerSubmission.noTransactionsDescription)
        }

        let txIds = transactions.map { $0.txId.toHexStringTxId() }
        let endpoints = selectedSubmissionEndpoints(
            userStoredPreferences: userStoredPreferences,
            zcashSDKEnvironment: zcashSDKEnvironment
        )

        LoggerProxy.event("\(logPrefix) Submitting \(transactions.count) transaction(s) to \(endpoints.count) server(s).")

        let reports = await submit(transactions, endpoints)

        // Pair each transaction with its report through the report's txId — never by position.
        // A transaction the SDK didn't report on counts as not attempted.
        let outcomesByTxId = Dictionary(
            reports.map { ($0.txId.toHexStringTxId(), $0.outcome) },
            uniquingKeysWith: { first, _ in first }
        )
        let outcomes = txIds.map { outcomesByTxId[$0] ?? TransactionSubmissionOutcome.notAttempted }
        if outcomesByTxId.count != transactions.count {
            LoggerProxy.error(
                "\(logPrefix) Expected reports for \(transactions.count) transaction(s), got \(reports.count); missing ones treated as not attempted."
            )
        }

        let result = mapSubmissionOutcomes(
            txIds: txIds,
            outcomes: outcomes,
            endpoints: endpoints
        )

        switch result {
        case .success:
            LoggerProxy.event("\(logPrefix) All \(transactions.count) transaction(s) accepted.")
        case let .failure(_, code, _):
            LoggerProxy.error("\(logPrefix) Submission rejected with code \(code).")
        case let .grpcFailure(_, reason):
            if reason == .timeout {
                LoggerProxy.error("\(logPrefix) Timed out waiting for any server to respond.")
            } else {
                LoggerProxy.error("\(logPrefix) Submission failed on all \(endpoints.count) server(s).")
            }
        case let .partial(_, statuses):
            LoggerProxy.error("\(logPrefix) Partial submission: \(statuses.joined(separator: ", ")).")
        }

        return result
    }

    /// Endpoint selection policy for multi-server submission:
    /// - Automatic connection mode -> all known endpoints for the current network
    /// - Manual connection mode (or mode not yet initialized) -> the currently selected endpoint
    static func selectedSubmissionEndpoints(
        userStoredPreferences: UserPreferencesStorageClient,
        zcashSDKEnvironment: ZcashSDKEnvironment
    ) -> [LightWalletEndpoint] {
        if userStoredPreferences.automaticServerSelection() == true {
            return ZcashSDKEnvironment.endpoints(for: zcashSDKEnvironment.network().networkType)
        }

        return [zcashSDKEnvironment.endpoint()]
    }

    /// Pure mapping of per-transaction SDK submission outcomes onto the app-side result contract.
    /// `outcomes[i]` belongs to `txIds[i]`; `endpoints` is the ordered list the transactions were
    /// submitted to and is only used to derive redacted "endpoint N" labels (never hostnames).
    ///
    /// `.partial` requires at least one acceptance; with zero acceptances the result is decided
    /// by the first not-accepted outcome (`.rejected` -> definitive failure, transport-level
    /// failures -> `.grpcFailure`, which routes to "pending" because the transactions are in the
    /// wallet and keep being rebroadcast by the SDK's background resubmission).
    ///
    /// `.cancelled` deliberately maps like `.unreachable`: the previous app-side implementation
    /// resumed a nil winner on cancellation and routed it through the same branch as a transport
    /// failure, and the caller was being torn down anyway.
    static func mapSubmissionOutcomes(
        txIds: [String],
        outcomes: [TransactionSubmissionOutcome],
        endpoints: [LightWalletEndpoint]
    ) -> CreateProposedTransactionsResult {
        guard !txIds.isEmpty else {
            return .failure(txIds: [], code: -1, description: MultiServerSubmission.noTransactionsDescription)
        }

        // The SDK reports one outcome per submitted transaction. Should it ever return fewer,
        // treat the missing ones as not attempted rather than silently reporting success.
        var outcomes = outcomes
        if outcomes.count < txIds.count {
            outcomes.append(contentsOf: Array(repeating: .notAttempted, count: txIds.count - outcomes.count))
        }

        let firstNotAcceptedIndex = outcomes.firstIndex { outcome in
            if case .accepted = outcome { return false }
            return true
        }

        guard let firstNotAcceptedIndex else {
            return .success(txIds: txIds)
        }

        let statuses = outcomes.map { status(for: $0, endpoints: endpoints) }
        let acceptedCount = outcomes.filter { outcome in
            if case .accepted = outcome { return true }
            return false
        }
        .count

        switch outcomes[firstNotAcceptedIndex] {
        case .accepted:
            // Unreachable: `firstNotAcceptedIndex` never points at an accepted outcome. Keep the
            // compiler-required branch loud so a refactor of the index derivation cannot silently
            // turn a failed submission into a reported success.
            assertionFailure("mapSubmissionOutcomes: first not-accepted outcome resolved to .accepted")
            return .partial(txIds: txIds, statuses: statuses)
        case let .rejected(code, message):
            return acceptedCount == 0
                ? .failure(txIds: txIds, code: code, description: message)
                : .partial(txIds: txIds, statuses: statuses)
        case .timedOut:
            return acceptedCount == 0
                ? .grpcFailure(txIds: txIds, reason: .timeout)
                : .partial(txIds: txIds, statuses: statuses)
        case .unreachable, .cancelled, .notAttempted:
            return acceptedCount == 0
                ? .grpcFailure(txIds: txIds)
                : .partial(txIds: txIds, statuses: statuses)
        }
    }

    private static func status(for outcome: TransactionSubmissionOutcome, endpoints: [LightWalletEndpoint]) -> String {
        switch outcome {
        case .accepted(let endpoint):
            return "accepted by \(endpointLabel(for: endpoint, in: endpoints))"
        case let .rejected(code, _):
            return "rejected code: \(code)"
        case .unreachable:
            return MultiServerSubmission.unreachableStatus
        case .cancelled:
            return MultiServerSubmission.cancelledStatus
        case .timedOut:
            return MultiServerSubmission.timeoutDescription
        case .notAttempted:
            return MultiServerSubmission.notAttemptedStatus
        }
    }

    /// Redacted label for an endpoint: its 1-based position in the submission list. The label never
    /// exposes the hostname, so a privately configured server cannot leak into support emails.
    private static func endpointLabel(for endpoint: LightWalletEndpoint, in endpoints: [LightWalletEndpoint]) -> String {
        guard let index = endpoints.firstIndex(of: endpoint) else { return "endpoint" }

        return "endpoint \(index + 1)"
    }
}

extension SDKSynchronizerClient {
    static func transactionStatesFromZcashTransactions(
        accountUUID: AccountUUID?,
        zcashTransactions: [ZcashTransaction.Overview],
        synchronizer: any Synchronizer
    ) async throws -> IdentifiedArrayOf<TransactionState> {
        guard let accountUUID else {
            return []
        }
        
        let clearedTransactions = zcashTransactions.compactMap { rawTransaction in
            rawTransaction.accountUUID == accountUUID ? rawTransaction : nil
        }

        var clearedTxs: [TransactionState] = []
        // Snapshot the chain tip once so TransactionState can fall back to an expiry-vs-tip
        // check when the SDK's `expired_unmined` column hasn't caught up (post-hardfork case
        // tracked in PRO-334). `latestBlockHeight == 0` means we haven't synced yet, so
        // hand nil to the init in that case to disable the fallback.
        let tipNow = synchronizer.latestState.latestBlockHeight
        let currentChainTip: BlockHeight? = tipNow > 0 ? tipNow : nil

        for clearedTransaction in clearedTransactions {
            var hasTransparentOutputs = false
            let outputs = await synchronizer.getTransactionOutputs(for: clearedTransaction)
            for output in outputs {
                if case .transaparent = output.pool {
                    hasTransparentOutputs = true
                    break
                }
            }

            var transaction = TransactionState.init(
                transaction: clearedTransaction,
                memos: nil,
                hasTransparentOutputs: hasTransparentOutputs,
                currentChainTip: currentChainTip
            )

            let recipients = await synchronizer.getRecipients(for: clearedTransaction)
            let addresses = recipients.compactMap {
                if case let .address(address) = $0 {
                    return address
                } else {
                    return nil
                }
            }
            
            transaction.rawID = clearedTransaction.rawID
            transaction.zAddress = addresses.first?.stringEncoded
            if let someAddress = addresses.first,
               case .transparent = someAddress {
                transaction.isTransparentRecipient = true
            }
            
            clearedTxs.append(transaction)
        }

        return IdentifiedArrayOf<TransactionState>(uniqueElements: clearedTxs)
    }
}
