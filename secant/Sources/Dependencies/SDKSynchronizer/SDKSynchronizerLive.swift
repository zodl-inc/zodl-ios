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
        
        let synchronizer = SDKSynchronizer(initializer: initializer)

        return SDKSynchronizerClient(
            stateStream: { synchronizer.stateStream },
            eventStream: { synchronizer.eventStream },
            exchangeRateUSDStream: { synchronizer.exchangeRateUSDStream },
            latestState: { synchronizer.latestState },
            prepareWith: { seedBytes, walletBirtday, walletMode, name, keySource in
                let result = try await synchronizer.prepare(
                    with: seedBytes,
                    walletBirthday: walletBirtday,
                    for: walletMode,
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
            createProposedTransactions: { proposal, spendingKey in
                let stream = try await synchronizer.createProposedTransactions(
                    proposal: proposal,
                    spendingKey: spendingKey
                )

                let transactionCount = proposal.transactionCount()
                var successCount = 0
                var iterator = stream.makeAsyncIterator()
                
                var txIds: [String] = []
                var statuses: [String] = []
                var errCode = 0
                var errDesc = ""
                var resubmitableFailure = false
                
                for _ in 1...transactionCount {
                    if let transactionSubmitResult = try await iterator.next() {
                        switch transactionSubmitResult {
                        case .success(txId: let id):
                            successCount += 1
                            txIds.append(id.toHexStringTxId())
                            statuses.append("success")
                        case let .grpcFailure(txId: id, error: error):
                            txIds.append(id.toHexStringTxId())
                            statuses.append(error.localizedDescription)
                            resubmitableFailure = true
                        case let .submitFailure(txId: id, code: code, description: description):
                            txIds.append(id.toHexStringTxId())
                            statuses.append("code: \(code) desc: \(description)")
                            errCode = code
                            errDesc = description
                        case .notAttempted(txId: let id):
                            txIds.append(id.toHexStringTxId())
                            statuses.append("notAttempted")
                        }
                    }
                }
                
                if successCount == 0 {
                    if resubmitableFailure {
                        return .grpcFailure(txIds: txIds)
                    } else {
                        return .failure(txIds: txIds, code: errCode, description: errDesc)
                    }
                } else if successCount == transactionCount {
                    return .success(txIds: txIds)
                } else {
                    return .partial(txIds: txIds, statuses: statuses)
                }
            },
            broadcasterCreateProposedTransactions: { proposal, spendingKey in
                try await synchronizer.broadcaster.createProposedTransactions(
                    proposal: proposal,
                    spendingKey: spendingKey
                )
            },
            createAndSubmitProposedTransactions: { proposal, spendingKey in
                let transactions = try await synchronizer.broadcaster.createProposedTransactions(
                    proposal: proposal,
                    spendingKey: spendingKey
                )

                return await Self.createAndSubmitTransactions(
                    transactions,
                    logPrefix: "[MultiSubmit]",
                    userStoredPreferences: userStoredPreferences,
                    zcashSDKEnvironment: zcashSDKEnvironment,
                    submit: { rawTx, endpoint in
                        try await synchronizer.broadcaster.submit(rawTx, to: endpoint)
                    }
                )
            },
            proposeShielding: { accountUUID, shieldingThreshold, memo, transparentReceiver in
                try await synchronizer.proposeShielding(
                    accountUUID: accountUUID,
                    shieldingThreshold: shieldingThreshold,
                    memo: memo,
                    transparentReceiver: transparentReceiver
                )
            },
            broadcasterSubmit: { rawTx, endpoint in
                try await synchronizer.broadcaster.submit(rawTx, to: endpoint)
            },
            isSeedRelevantToAnyDerivedAccount: { seed in
                try await synchronizer.isSeedRelevantToAnyDerivedAccount(seed: seed)
            },
            refreshExchangeRateUSD: {
                synchronizer.refreshExchangeRateUSD()
            },
            evaluateBestOf: { endpoints, latencyThreshold, fetchThreshold, nBlocks, kServers, network in
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
            createTransactionFromPCZT: { pcztWithProofs, pcztWithSigs in
                let stream = try await synchronizer.createTransactionFromPCZT(
                    pcztWithProofs: pcztWithProofs,
                    pcztWithSigs: pcztWithSigs
                )

                var successCount = 0
                var iterator = stream.makeAsyncIterator()
                
                var txIds: [String] = []
                var statuses: [String] = []
                var errCode = 0
                var errDesc = ""
                var resubmitableFailure = false
                
                if let transactionSubmitResult = try await iterator.next() {
                    switch transactionSubmitResult {
                    case .success(txId: let id):
                        successCount += 1
                        txIds.append(id.toHexStringTxId())
                        statuses.append("success")
                    case let .grpcFailure(txId: id, error: error):
                        txIds.append(id.toHexStringTxId())
                        statuses.append(error.localizedDescription)
                        resubmitableFailure = true
                    case let .submitFailure(txId: id, code: code, description: description):
                        txIds.append(id.toHexStringTxId())
                        statuses.append("code: \(code) desc: \(description)")
                        errCode = code
                        errDesc = description
                    case .notAttempted(txId: let id):
                        txIds.append(id.toHexStringTxId())
                        statuses.append("notAttempted")
                    }
                }
                
                if successCount == 0 {
                    if resubmitableFailure {
                        return .grpcFailure(txIds: txIds)
                    } else {
                        return .failure(txIds: txIds, code: errCode, description: errDesc)
                    }
                } else if successCount == 1 {
                    return .success(txIds: txIds)
                } else {
                    return .partial(txIds: txIds, statuses: statuses)
                }
            },
            broadcasterCreateTransactionFromPCZT: { pcztWithProofs, pcztWithSigs in
                try await synchronizer.broadcaster.createTransactionFromPCZT(
                    pcztWithProofs: pcztWithProofs,
                    pcztWithSigs: pcztWithSigs
                )
            },
            createAndSubmitTransactionFromPCZT: { pcztWithProofs, pcztWithSigs in
                let transactions = try await synchronizer.broadcaster.createTransactionFromPCZT(
                    pcztWithProofs: pcztWithProofs,
                    pcztWithSigs: pcztWithSigs
                )

                return await Self.createAndSubmitTransactions(
                    transactions,
                    logPrefix: "[MultiSubmit/PCZT]",
                    userStoredPreferences: userStoredPreferences,
                    zcashSDKEnvironment: zcashSDKEnvironment,
                    submit: { rawTx, endpoint in
                        try await synchronizer.broadcaster.submit(rawTx, to: endpoint)
                    }
                )
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
            torEnabled: { enabled in
                try await synchronizer.tor(enabled: enabled)
            },
            exchangeRateEnabled: { enabled in
                try await synchronizer.exchangeRateOverTor(enabled: enabled)
            },
            isTorSuccessfullyInitialized: {
                await synchronizer.isTorSuccessfullyInitialized()
            },
            httpRequestOverTor: { request in
                try await synchronizer.httpRequestOverTor(for: request)
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
            getTreeState: { height in
                try await synchronizer.getTreeState(height: height)
            }
        )
    }
}

extension SDKSynchronizerClient {
    private enum MultiServerSubmissionTiming {
        static let postAcceptanceGraceDelay: Duration = .seconds(5)
        static let firstResponseTimeout: Duration = .seconds(30)
        static let timeoutDrainDelay: Duration = .seconds(2)
    }

    private enum SubmitResult {
        case server(String?)
        case graceExpired
        case timedOut
    }

    private actor AcceptedSubmitStore {
        private var server: String?

        func record(_ server: String) {
            self.server = self.server ?? server
        }

        func recordedServer() -> String? {
            server
        }
    }

    private final class SubmitTaskCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func set(_ task: Task<Void, Never>) {
            lock.lock()
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    static func createAndSubmitTransactions(
        _ transactions: [ZcashTransaction.Overview],
        logPrefix: String,
        userStoredPreferences: UserPreferencesStorageClient,
        zcashSDKEnvironment: ZcashSDKEnvironment,
        graceDelay: Duration = MultiServerSubmissionTiming.postAcceptanceGraceDelay,
        responseTimeout: Duration = MultiServerSubmissionTiming.firstResponseTimeout,
        timeoutDrainDelay: Duration = MultiServerSubmissionTiming.timeoutDrainDelay,
        submit: @escaping (Data, LightWalletEndpoint) async throws -> Void
    ) async -> CreateProposedTransactionsResult {
        guard !transactions.isEmpty else {
            return .failure(txIds: [], code: -1, description: "No transactions created")
        }

        let txIds = transactions.map { $0.rawID.toHexStringTxId() }
        let endpoints = selectedSubmissionEndpoints(
            userStoredPreferences: userStoredPreferences,
            zcashSDKEnvironment: zcashSDKEnvironment
        )

        LoggerProxy.event("\(logPrefix) Submitting \(transactions.count) transaction(s) to \(endpoints.count) server(s).")

        var acceptedCount = 0
        var statuses: [String] = []

        for (index, transaction) in transactions.enumerated() {
            guard let rawTx = transaction.raw else {
                let status = "Transaction \(index) created but raw bytes unavailable"
                statuses.append(status)
                LoggerProxy.error("\(logPrefix) \(status).")
                return acceptedCount == 0
                    ? .failure(txIds: txIds, code: -1, description: status)
                    : .partial(txIds: txIds, statuses: statuses)
            }

            let accepted = await submitToAllEndpoints(
                rawTx: rawTx,
                endpoints: endpoints,
                logPrefix: logPrefix,
                graceDelay: graceDelay,
                responseTimeout: responseTimeout,
                timeoutDrainDelay: timeoutDrainDelay,
                submit: submit
            )

            if let winner = accepted {
                acceptedCount += 1
                statuses.append("accepted by \(winner)")
                LoggerProxy.event("\(logPrefix) Transaction \(index) accepted by \(winner).")
            } else {
                statuses.append("rejected by all servers")
                LoggerProxy.error("\(logPrefix) Transaction \(index) rejected by all \(endpoints.count) server(s).")
                return acceptedCount == 0
                    ? .grpcFailure(txIds: txIds)
                    : .partial(txIds: txIds, statuses: statuses)
            }
        }

        return acceptedCount == transactions.count
            ? .success(txIds: txIds)
            : .partial(txIds: txIds, statuses: statuses)
    }

    static func selectedSubmissionEndpoints(
        userStoredPreferences: UserPreferencesStorageClient,
        zcashSDKEnvironment: ZcashSDKEnvironment
    ) -> [LightWalletEndpoint] {
        let streamingTimeout = ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
        if let config = userStoredPreferences.selectedServers() {
            switch config.mode {
            case .automatic:
                return ZcashSDKEnvironment.endpoints(
                    for: zcashSDKEnvironment.network().networkType
                )
            case .manual:
                if let server = config.servers.first {
                    return [server.endpoint(streamingCallTimeoutInMillis: streamingTimeout)]
                }
            }
        }

        return [zcashSDKEnvironment.endpoint()]
    }

    static func submitToAllEndpoints(
        rawTx: Data,
        endpoints: [LightWalletEndpoint],
        logPrefix: String,
        graceDelay: Duration = MultiServerSubmissionTiming.postAcceptanceGraceDelay,
        responseTimeout: Duration = MultiServerSubmissionTiming.firstResponseTimeout,
        timeoutDrainDelay: Duration = MultiServerSubmissionTiming.timeoutDrainDelay,
        submit: @escaping (Data, LightWalletEndpoint) async throws -> Void
    ) async -> String? {
        guard !endpoints.isEmpty else { return nil }

        let serverCount = endpoints.count
        let acceptedSubmitStore = AcceptedSubmitStore()
        let submitTaskCancellation = SubmitTaskCancellation()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let task = Task {
                    var hasResumed = false

                    await withTaskGroup(of: SubmitResult.self) { group in
                        for endpoint in endpoints {
                            let server = "\(endpoint.host):\(endpoint.port)"
                            group.addTask {
                                do {
                                    try await submit(rawTx, endpoint)
                                    await acceptedSubmitStore.record(server)
                                    LoggerProxy.event("\(logPrefix) \(server) SUCCESS.")
                                    return .server(server)
                                } catch {
                                    LoggerProxy.warn("\(logPrefix) \(server) FAILED: \(error)")
                                    return .server(nil)
                                }
                            }
                        }

                        group.addTask {
                            do {
                                try await Task.sleep(for: responseTimeout)
                                try await Task.sleep(for: timeoutDrainDelay)
                                if let server = await acceptedSubmitStore.recordedServer() {
                                    return .server(server)
                                }
                                LoggerProxy.error("\(logPrefix) Timed out waiting for any server to respond.")
                                return .timedOut
                            } catch {
                                return .timedOut
                            }
                        }

                        var failedCount = 0
                        for await result in group {
                            switch result {
                            case .server(let winner?):
                                if !hasResumed {
                                    hasResumed = true
                                    continuation.resume(returning: winner)
                                    group.addTask {
                                        try? await Task.sleep(for: graceDelay)
                                        return .graceExpired
                                    }
                                }
                            case .server(nil):
                                failedCount += 1
                                if !hasResumed && failedCount >= serverCount {
                                    hasResumed = true
                                    group.cancelAll()
                                    continuation.resume(returning: nil)
                                    return
                                }
                            case .graceExpired:
                                if !hasResumed {
                                    hasResumed = true
                                    continuation.resume(returning: nil)
                                }
                                group.cancelAll()
                                return
                            case .timedOut:
                                if !hasResumed {
                                    hasResumed = true
                                    continuation.resume(returning: await acceptedSubmitStore.recordedServer())
                                }
                                group.cancelAll()
                                return
                            }
                        }

                        if !hasResumed {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                submitTaskCancellation.set(task)
                if Task.isCancelled {
                    task.cancel()
                }
            }
        } onCancel: {
            submitTaskCancellation.cancel()
        }
    }
}

extension SDKSynchronizerClient {
    static func transactionStatesFromZcashTransactions(
        accountUUID: AccountUUID?,
        zcashTransactions: [ZcashTransaction.Overview],
        synchronizer: SDKSynchronizer
    ) async throws -> IdentifiedArrayOf<TransactionState> {
        guard let accountUUID else {
            return []
        }
        
        let clearedTransactions = zcashTransactions.compactMap { rawTransaction in
            rawTransaction.accountUUID == accountUUID ? rawTransaction : nil
        }
        
        var clearedTxs: [TransactionState] = []

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
                hasTransparentOutputs: hasTransparentOutputs
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
