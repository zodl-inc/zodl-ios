//
//  UserMetadataStorage.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-01-28.
//

import Foundation
import ZcashLightClientKit
import ComposableArchitecture
import WalletStorage
import RemoteStorage
import UserDefaults
import Models

public class UserMetadataStorage {
    enum Constants {
        static let int64Size = MemoryLayout<Int64>.size
        static let udUmRTimestamp = "zashi_udUmRTimestamp"
    }
    
    public enum UMError: Error {
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

    // Bookmarks
    var bookmarked: [String: UMBookmark] = [:]
    
    // Annotations
    var annotations: [String: UMAnnotation] = [:]

    // Read
    var read: [String: String] = [:]

    // Swap Ids
    var swapIds: [String: UMSwapId] = [:]
    
    // Last User SwapAssets
    var lastUsedAssetHistory: [String] = []

    public init() { }
    
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
    
    public func reset() throws {
        bookmarked.removeAll()
        annotations.removeAll()
        read.removeAll()
        swapIds.removeAll()
        lastUsedAssetHistory.removeAll()
        
        @Dependency(\.userDefaults) var userDefaults

        userDefaults.remove(Constants.udUmRTimestamp)
    }
    
    public func resetAccount(_ account: Account) throws {
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

    public func store(account: Account) throws {
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
    
    public func load(account: Account) throws {
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
    
    public func fillMemoryWith(_ umData: UserMetadata) {
        umData.accountMetadata.bookmarked.forEach { bookmark in
            bookmarked[bookmark.txId] = bookmark
        }
        
        umData.accountMetadata.read.forEach { umRead in
            read[umRead] = umRead
        }
        
        umData.accountMetadata.annotations.forEach { annotation in
            annotations[annotation.txId] = annotation
        }

        umData.accountMetadata.swaps.swapIds.forEach { swapId in
            swapIds[swapId.depositAddress] = swapId
        }
        
        lastUsedAssetHistory = umData.accountMetadata.swaps.lastUsedAssetHistory
    }
    
    public func clearMemory() {
        bookmarked.removeAll()
        read.removeAll()
        annotations.removeAll()
        swapIds.removeAll()
        lastUsedAssetHistory.removeAll()
    }

    public func userMetadataFromMemory() -> UserMetadata {
        let umBookmarked = bookmarked.map { $0.value }
        let umAnnotations = annotations.map { $0.value }
        let umRead = read.map { $0.value }
        let umSwapIds = swapIds.map { $0.value }

        let umAccount = UMAccount(
            bookmarked: umBookmarked,
            annotations: umAnnotations,
            read: umRead,
            swaps: UMSwaps(
                swapIds: umSwapIds,
                lastUsedAssetHistory: lastUsedAssetHistory,
                lastUpdated: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )
        
        return UserMetadata(
            version: UserMetadata.Constants.version,
            lastUpdated: Int64(Date().timeIntervalSince1970 * 1000),
            accountMetadata: umAccount
        )
    }

    // MARK: - Bookmarking
    
    public func isBookmarked(txId: String) -> Bool {
        bookmarked[txId]?.isBookmarked ?? false
    }
    
    public func toggleBookmarkFor(txId: String) {
        guard let existingBookmark = bookmarked[txId] else {
            bookmarked[txId] = UMBookmark(
                txId: txId,
                lastUpdated: Int64(Date().timeIntervalSince1970 * 1000),
                isBookmarked: true
            )
            return
        }
        
        bookmarked[txId] = UMBookmark(
            txId: txId,
            lastUpdated: Int64(Date().timeIntervalSince1970 * 1000),
            isBookmarked: !existingBookmark.isBookmarked
        )
    }
    
    // MARK: - Annotations
    
    public func annotationFor(txId: String) -> String? {
        annotations[txId]?.content
    }
    
    public func add(annotation: String, for txId: String) {
        annotations[txId] = UMAnnotation(
            txId: txId,
            content: annotation,
            lastUpdated: Int64(Date().timeIntervalSince1970 * 1000) 
        )
    }
    
    public func deleteAnnotationFor(txId: String) {
        annotations.removeValue(forKey: txId)
    }
    
    // MARK: - Unread
    
    public func isRead(txId: String, txTimestamp: TimeInterval?) -> Bool {
        @Dependency(\.userDefaults) var userDefaults

        // read because the transaction happened before user metadata were introduced
        if let umRTimestamp = userDefaults.objectForKey(Constants.udUmRTimestamp) as? TimeInterval, let txTimestamp {
            if txTimestamp < umRTimestamp {
                return true
            }
        }

        return read[txId] != nil
    }
    
    public func readTx(txId: String) {
        read[txId] = txId
    }
    
    // MARK: - Swap Id
    
    public func allSwaps() -> [UMSwapId] {
        swapIds.values.compactMap(\.self)
    }
    
    public func isSwapTransaction(depositAddress: String) -> Bool {
        guard let swapDepositAddress = swapIds[depositAddress]?.depositAddress else {
            return false
        }
        
        return swapDepositAddress == depositAddress
    }
    
    public func swapDetailsForTransaction(depositAddress: String) -> UMSwapId? {
        swapIds[depositAddress]
    }
    
    public func markTransactionAsSwapFor(
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
        swapIds[depositAddress] = UMSwapId(
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
    
    public func update(_ swap: UMSwapId) -> Void {
        swapIds[swap.depositAddress] = swap
    }

    // Last Used Asset History
    public func addLastUsedSwap(asset: String) {
        lastUsedAssetHistory.removeAll { $0 == asset }
        lastUsedAssetHistory.insert(asset, at: 0)
        
        if lastUsedAssetHistory.count > 10 {
            lastUsedAssetHistory = Array(lastUsedAssetHistory.prefix(10))
        }
    }
}
