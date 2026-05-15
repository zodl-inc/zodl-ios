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
        
        let network = zcashSDKEnvironment.network
        
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
                    keySource: keySource
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
