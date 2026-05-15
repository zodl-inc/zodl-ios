//
//  UserMetadataStorage.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-01-28.
//

import Foundation
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture
import os

final class UserMetadataStorage: Sendable {
    enum Constants {
        static let int64Size = MemoryLayout<Int64>.size
        static let udUmRTimestamp = "zashi_udUmRTimestamp"
    }

    enum UMError: Error {
        case documentsFolder
        // structure of the encrypted data is either corrupted or version is not present
        case encryptedDataStructuralCorruption
        case encryptionVersionNotSupported
        case fileIdentifier
        case localFileDoesntExist
        case metadataVersionNotSupported
        case missingEncryptionKey
        case subdataRange
        case serialization
    }

    struct MutableState: Sendable {
        var bookmarked: [String: UMBookmark] = [:]
        var annotations: [String: UMAnnotation] = [:]
        var read: [String: String] = [:]
        var swapIds: [String: UMSwapId] = [:]
        var lastUsedAssetHistory: [String] = []
    }

    let state = OSAllocatedUnfairLock(initialState: MutableState())

    var lastUsedAssetHistory: [String] {
        return state.withLock { $0.self.lastUsedAssetHistory }
    }

    init() { }

    // MARK: - General

    func filenameForEncryptedFile(account: Account) throws -> String {
        @Dependency(\.walletStorage) var walletStorage

        guard let encryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account),
                let umKey = encryptionKeys.getCached(account: account) else {
            throw UMError.missingEncryptionKey
        }

        guard let filename = umKey.fileIdentifier(account: account) else {
            throw UMError.fileIdentifier
        }

        return filename
    }

    func reset() throws {
        state.withLock { state in
            state.bookmarked.removeAll()
            state.annotations.removeAll()
            state.read.removeAll()
            state.swapIds.removeAll()
            state.lastUsedAssetHistory.removeAll()
        }

        @Dependency(\.userDefaults) var userDefaults

        userDefaults.remove(Constants.udUmRTimestamp)
    }

    func resetAccount(_ account: Account) throws {
        // store encrypted data to the local storage
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw UMError.documentsFolder
        }

        let filenameForEncryptedFile = try filenameForEncryptedFile(account: account)
        let fileURL = documentsDirectory.appendingPathComponent(filenameForEncryptedFile)

        try FileManager.default.removeItem(at: fileURL)

        @Dependency(\.remoteStorage) var remoteStorage

        // try to remove the remote as well
        try? remoteStorage.removeFile(filenameForEncryptedFile)
    }

    func store(account: Account) throws {
        // store encrypted data to the local storage
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw UMError.documentsFolder
        }

        let filenameForEncryptedFile = try filenameForEncryptedFile(account: account)
        let fileURL = documentsDirectory.appendingPathComponent(filenameForEncryptedFile)

        let metadata = userMetadataFromMemory()

        let encryptedUMData = try UserMetadata.encryptUserMetadata(metadata, account: account)

        try encryptedUMData.write(to: fileURL, options: .atomic)

        @Dependency(\.remoteStorage) var remoteStorage

        // always push the latest data to the remote
        try? remoteStorage.storeDataToFile(encryptedUMData, filenameForEncryptedFile)
    }

    func load(account: Account) throws {
        resolveReadTimestamp()
        clearMemory()

        do {
            guard let localData = try loadLocal(account: account) else {
                checkRemoteAndEventuallyFillMemory(account: account)
                return
            }
            fillMemoryWith(localData)
        } catch UMError.localFileDoesntExist {
            checkRemoteAndEventuallyFillMemory(account: account)
        } catch {
            checkRemoteAndEventuallyFillMemory(account: account)
        }

        return
    }

    func loadLocal(account: Account) throws -> UserMetadata? {
        // load local data
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw UMError.documentsFolder
        }

        // Try to find and get the data from the encrypted file with the latest encryption version
        let encryptedFileURL = documentsDirectory.appendingPathComponent(try filenameForEncryptedFile(account: account))

        if !FileManager.default.fileExists(atPath: encryptedFileURL.path) {
            throw UMError.localFileDoesntExist
        }

        if let encryptedUMData = try? Data(contentsOf: encryptedFileURL) {
            let loadResult = try UserMetadata.userMetadataFrom(encryptedData: encryptedUMData, account: account)
            // store needed
            if let localData = loadResult.0, loadResult.1 {
                fillMemoryWith(localData)
                try? store(account: account)
            }
            return loadResult.0
        }

        return nil
    }

    func resolveReadTimestamp() {
        @Dependency(\.userDefaults) var userDefaults

        guard let _ = userDefaults.objectForKey(Constants.udUmRTimestamp) as? TimeInterval else {
            userDefaults.setValue(Date().timeIntervalSince1970, Constants.udUmRTimestamp)
            return
        }
    }

    func checkRemoteAndEventuallyFillMemory(account: Account) {
        @Dependency(\.remoteStorage) var remoteStorage

        guard let filenameForEncryptedFile = try? filenameForEncryptedFile(account: account) else {
            return
        }

        if let encryptedUMData = try? remoteStorage.loadDataFromFile(filenameForEncryptedFile),
            let loadResult = try? UserMetadata.userMetadataFrom(encryptedData: encryptedUMData, account: account), let umData = loadResult.0 {
            fillMemoryWith(umData)
            try? store(account: account)
        }
    }

    func fillMemoryWith(_ umData: UserMetadata) {
        state.withLock { state in
            umData.accountMetadata.bookmarked.forEach { bookmark in
                state.bookmarked[bookmark.txId] = bookmark
            }

            umData.accountMetadata.read.forEach { umRead in
                state.read[umRead] = umRead
            }

            umData.accountMetadata.annotations.forEach { annotation in
                state.annotations[annotation.txId] = annotation
            }

            umData.accountMetadata.swaps.swapIds.forEach { swapId in
                state.swapIds[swapId.depositAddress] = swapId
            }

            state.lastUsedAssetHistory = umData.accountMetadata.swaps.lastUsedAssetHistory
        }
    }

    func clearMemory() {
        state.withLock { state in
            state.bookmarked.removeAll()
            state.read.removeAll()
            state.annotations.removeAll()
            state.swapIds.removeAll()
            state.lastUsedAssetHistory.removeAll()
        }
    }

    func userMetadataFromMemory() -> UserMetadata {
        state.withLock { state in
            let umBookmarked = state.bookmarked.map { $0.value }
            let umAnnotations = state.annotations.map { $0.value }
            let umRead = state.read.map { $0.value }
            let umSwapIds = state.swapIds.map { $0.value }

            let umAccount = UMAccount(
                bookmarked: umBookmarked,
                annotations: umAnnotations,
                read: umRead,
                swaps: UMSwaps(
                    swapIds: umSwapIds,
                    lastUsedAssetHistory: state.lastUsedAssetHistory,
                    lastUpdated: Int64(Date().timeIntervalSince1970 * 1000)
                )
            )

            return UserMetadata(
                version: UserMetadata.Constants.version,
                lastUpdated: Int64(Date().timeIntervalSince1970 * 1000),
                accountMetadata: umAccount
            )
        }
    }

    // MARK: - Bookmarking

    func isBookmarked(txId: String) -> Bool {
        state.withLock { $0.bookmarked[txId]?.isBookmarked ?? false }
    }

    func toggleBookmarkFor(txId: String) {
        state.withLock { state in
            guard let existingBookmark = state.bookmarked[txId] else {
                state.bookmarked[txId] = UMBookmark(
                    txId: txId,
                    lastUpdated: Int64(Date().timeIntervalSince1970 * 1000),
                    isBookmarked: true
                )
                return
            }

            state.bookmarked[txId] = UMBookmark(
                txId: txId,
                lastUpdated: Int64(Date().timeIntervalSince1970 * 1000),
                isBookmarked: !existingBookmark.isBookmarked
            )
        }
    }

    // MARK: - Annotations

    func annotationFor(txId: String) -> String? {
        state.withLock { $0.annotations[txId]?.content }
    }

    func add(annotation: String, for txId: String) {
        state.withLock { state in
            state.annotations[txId] = UMAnnotation(
                txId: txId,
                content: annotation,
                lastUpdated: Int64(Date().timeIntervalSince1970 * 1000)
            )
        }
    }

    func deleteAnnotationFor(txId: String) {
        _ = state.withLock { state in
            state.annotations.removeValue(forKey: txId)
        }
    }

    // MARK: - Unread

    func isRead(txId: String, txTimestamp: TimeInterval?) -> Bool {
        @Dependency(\.userDefaults) var userDefaults

        // read because the transaction happened before user metadata were introduced
        if let umRTimestamp = userDefaults.objectForKey(Constants.udUmRTimestamp) as? TimeInterval, let txTimestamp {
            if txTimestamp < umRTimestamp {
                return true
            }
        }

        return state.withLock { $0.read[txId] != nil }
    }

    func readTx(txId: String) {
        state.withLock { $0.read[txId] = txId }
    }

    // MARK: - Swap Id

    func allSwaps() -> [UMSwapId] {
        state.withLock { $0.swapIds.values.compactMap(\.self) }
    }

    func isSwapTransaction(depositAddress: String) -> Bool {
        state.withLock { state in
            guard let swapDepositAddress = state.swapIds[depositAddress]?.depositAddress else {
                return false
            }

            return swapDepositAddress == depositAddress
        }
    }

    func swapDetailsForTransaction(depositAddress: String) -> UMSwapId? {
        state.withLock { $0.swapIds[depositAddress] }
    }

    func markTransactionAsSwapFor(
        depositAddress: String,
        provider: String,
        totalFees: Int64,
        totalUSDFees: String,
        fromAsset: String,
        toAsset: String,
        exactInput: Bool,
        status: String,
        amountOutFormatted: String
    ) {
        state.withLock { state in
            state.swapIds[depositAddress] = UMSwapId(
                depositAddress: depositAddress,
                provider: provider,
                totalFees: totalFees,
                totalUSDFees: totalUSDFees,
                lastUpdated: Int64(Date().timeIntervalSince1970 * 1000),
                fromAsset: fromAsset,
                toAsset: toAsset,
                exactInput: exactInput,
                status: status,
                amountOutFormatted: amountOutFormatted
            )
        }
    }

    func update(_ swap: UMSwapId) {
        state.withLock { $0.swapIds[swap.depositAddress] = swap }
    }

    // Last Used Asset History
    func addLastUsedSwap(asset: String) {
        state.withLock { state in
            state.lastUsedAssetHistory.removeAll { $0 == asset }
            state.lastUsedAssetHistory.insert(asset, at: 0)

            if state.lastUsedAssetHistory.count > 10 {
                state.lastUsedAssetHistory = Array(state.lastUsedAssetHistory.prefix(10))
            }
        }
    }
}
