#if VOTING_ENABLED
//
//  VotingMetadataStorage.swift
//  Zashi
//

import Foundation
import CryptoKit
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import os

/// Encrypted, per-account, local-only storage for the voting flow's drafts,
/// submitted choices, and per-round vote records. Mirrors `UserMetadataStorage`
/// but writes a separate file (`<prefix>-voting-<hkdf>`) and skips the
/// remote-storage path because voting history is intentionally per-device
/// with no iCloud sync.
final class VotingMetadataStorage: Sendable {
    enum Constants {
        static let int64Size = MemoryLayout<Int64>.size
    }

    enum VMError: Error {
        case documentsFolder
        case encryptedDataStructuralCorruption
        case encryptionVersionNotSupported
        case fileIdentifier
        case localFileDoesntExist
        case schemaVersionNotSupported
        case missingEncryptionKey
        case serialization
        case subdataRange
    }

    struct MutableState: Sendable {
        var drafts: [String: [String: UInt32]] = [:]
        var submittedVotes: [String: [String: UInt32]] = [:]
        var records: [String: PersistedVotingRecord] = [:]
    }

    let state = OSAllocatedUnfairLock(initialState: MutableState())

    init() {}

    // MARK: - General

    func filenameForEncryptedFile(account: Account) throws -> String {
        @Dependency(\.walletStorage) var walletStorage

        guard let encryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account),
              let umKey = encryptionKeys.getCached(account: account) else {
            throw VMError.missingEncryptionKey
        }

        guard let filename = umKey.votingFileIdentifier(account: account) else {
            throw VMError.fileIdentifier
        }

        return filename
    }

    func clearMemory() {
        state.withLock { state in
            state.drafts.removeAll()
            state.submittedVotes.removeAll()
            state.records.removeAll()
        }
    }

    func resetAccount(_ account: Account) throws {
        guard let documentsDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        else {
            throw VMError.documentsFolder
        }

        let filename = try filenameForEncryptedFile(account: account)
        let fileURL = documentsDirectory.appendingPathComponent(filename)

        try? FileManager.default.removeItem(at: fileURL)
    }

    func store(account: Account) throws {
        guard let documentsDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        else {
            throw VMError.documentsFolder
        }

        let filename = try filenameForEncryptedFile(account: account)
        let fileURL = documentsDirectory.appendingPathComponent(filename)

        let metadata = votingMetadataFromMemory()
        let encrypted = try VotingMetadata.encrypt(metadata, account: account)
        try encrypted.write(to: fileURL, options: .atomic)
        try excludeFromBackup(fileURL: fileURL)
    }

    /// Voting metadata is intentionally local-only — unlike Address Book and
    /// User Metadata, it has no iCloud Drive sync path, no merge strategy, and
    /// no propagation of Reset Zashi to remote copies. Excluding the file from
    /// iCloud Backup keeps that contract end-to-end so an orphaned encrypted
    /// blob can't outlive the wallet in the user's Apple backup.
    ///
    /// Called after every atomic write because `.atomic` writes to a temp file
    /// and renames into place, which can drop the resource attribute on some
    /// iOS versions.
    private func excludeFromBackup(fileURL: URL) throws {
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func load(account: Account) throws {
        clearMemory()

        guard let documentsDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        else {
            throw VMError.documentsFolder
        }

        let filename = try filenameForEncryptedFile(account: account)
        let fileURL = documentsDirectory.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let encryptedData = try? Data(contentsOf: fileURL) else { return }

        let decoded = try VotingMetadata.decrypt(encryptedData: encryptedData, account: account)
        if let decoded {
            fillMemoryWith(decoded)
        }
    }

    // MARK: - In-memory helpers

    private func fillMemoryWith(_ metadata: VotingMetadata) {
        state.withLock { state in
            state.drafts = metadata.drafts
            state.submittedVotes = metadata.submittedVotes
            state.records = metadata.records
        }
    }

    func votingMetadataFromMemory() -> VotingMetadata {
        state.withLock { state in
            VotingMetadata(
                drafts: state.drafts,
                submittedVotes: state.submittedVotes,
                records: state.records
            )
        }
    }

    // MARK: - Drafts

    func loadDrafts(roundId: String) -> [String: UInt32] {
        state.withLock { $0.drafts[roundId] ?? [:] }
    }

    func setDrafts(_ drafts: [String: UInt32], roundId: String) {
        state.withLock { state in
            if drafts.isEmpty {
                state.drafts.removeValue(forKey: roundId)
            } else {
                state.drafts[roundId] = drafts
            }
        }
    }

    func clearDrafts(roundId: String) {
        state.withLock { _ = $0.drafts.removeValue(forKey: roundId) }
    }

    // MARK: - Submitted votes

    func loadSubmittedVotes(roundId: String) -> [String: UInt32] {
        state.withLock { $0.submittedVotes[roundId] ?? [:] }
    }

    func setSubmittedVotes(_ votes: [String: UInt32], roundId: String) {
        state.withLock { state in
            if votes.isEmpty {
                state.submittedVotes.removeValue(forKey: roundId)
            } else {
                state.submittedVotes[roundId] = votes
            }
        }
    }

    func clearSubmittedVotes(roundId: String) {
        state.withLock { _ = $0.submittedVotes.removeValue(forKey: roundId) }
    }

    // MARK: - Records

    func record(roundId: String) -> PersistedVotingRecord? {
        state.withLock { $0.records[roundId] }
    }

    func allRecords() -> [String: PersistedVotingRecord] {
        state.withLock { $0.records }
    }

    func setRecord(_ record: PersistedVotingRecord, roundId: String) {
        state.withLock { $0.records[roundId] = record }
    }

    func clearRecord(roundId: String) {
        state.withLock { _ = $0.records.removeValue(forKey: roundId) }
    }
}

// MARK: - Encryption / Decryption

extension VotingMetadata {
    /// File layout (mirrors `UserMetadata.encryptUserMetadata`):
    ///   [Unencrypted] encryption version  (8 bytes, big-endian Int)
    ///   [Unencrypted] salt                 (32 bytes)
    ///   [Unencrypted] schema version       (8 bytes, big-endian Int)
    ///   [Encrypted]   serialized voting metadata (ChaChaPoly sealed box)
    static func encrypt(_ metadata: VotingMetadata, account: Account) throws -> Data {
        @Dependency(\.walletStorage) var walletStorage

        guard let encryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account),
              let umKey = encryptionKeys.getCached(account: account)
        else {
            throw VotingMetadataStorage.VMError.missingEncryptionKey
        }

        let encryptionVersionData = Data(Serializer.intToBytes(UserMetadataEncryptionKeys.Constants.version))
        let schemaVersionData = Data(Serializer.intToBytes(VotingMetadata.Constants.version))

        // Fresh 32-byte salt per write so each on-disk blob is independently
        // sub-keyed.
        let salt = SymmetricKey(size: SymmetricKeySize.bits256)

        guard let payload = try? JSONEncoder().encode(metadata) else {
            throw VotingMetadataStorage.VMError.serialization
        }

        return try salt.withUnsafeBytes { saltBytes in
            let salt = Data(saltBytes)
            let subKey = umKey.deriveEncryptionKey(salt: salt)
            let sealed = try ChaChaPoly.seal(payload, using: subKey)
            return encryptionVersionData + salt + schemaVersionData + sealed.combined
        }
    }

    /// Decrypt and decode. Returns `nil` if no key in the account's key set
    /// could decrypt the sealed box.
    static func decrypt(encryptedData: Data, account: Account) throws -> VotingMetadata? {
        @Dependency(\.walletStorage) var walletStorage

        guard let encryptionKeys = try? walletStorage.exportUserMetadataEncryptionKeys(account),
              let umKey = encryptionKeys.getCached(account: account)
        else {
            throw VotingMetadataStorage.VMError.missingEncryptionKey
        }

        var offset = 0
        let intSize = VotingMetadataStorage.Constants.int64Size

        // Encryption version
        let encryptionVersionBytes = try subdata(of: encryptedData, in: offset..<(offset + intSize))
        offset += intSize
        guard let encryptionVersion = bytesToInt(Array(encryptionVersionBytes)) else {
            throw VotingMetadataStorage.VMError.encryptedDataStructuralCorruption
        }
        guard encryptionVersion == UserMetadataEncryptionKeys.Constants.version else {
            throw VotingMetadataStorage.VMError.encryptionVersionNotSupported
        }

        // Salt
        let salt = try subdata(of: encryptedData, in: offset..<(offset + 32))
        offset += 32

        // Schema version (advisory — keep loader fail-soft on unknown versions
        // so a future on-disk shape change doesn't crash older builds reading
        // newer files; they'll just return nil and start fresh).
        let schemaVersionBytes = try subdata(of: encryptedData, in: offset..<(offset + intSize))
        offset += intSize
        guard let schemaVersion = bytesToInt(Array(schemaVersionBytes)) else {
            throw VotingMetadataStorage.VMError.encryptedDataStructuralCorruption
        }
        guard schemaVersion == VotingMetadata.Constants.version else {
            throw VotingMetadataStorage.VMError.schemaVersionNotSupported
        }

        let sealedData = encryptedData.subdata(in: offset..<encryptedData.count)
        let sealedBox = try ChaChaPoly.SealedBox(combined: sealedData)

        // Try every key in the account's key set; the first one that opens
        // the sealed box wins. Mirrors the user-metadata decrypt strategy.
        for decryptionKey in umKey.deriveDecryptionKeys(salt: salt) {
            if let opened = try? ChaChaPoly.open(sealedBox, using: decryptionKey) {
                guard let decoded = try? JSONDecoder().decode(VotingMetadata.self, from: opened) else {
                    throw VotingMetadataStorage.VMError.serialization
                }
                // Defense-in-depth: the envelope's outer schema version and
                // the in-payload `schemaVersion` are written together, so a
                // mismatch implies either tampering or a producer bug. Fail
                // closed rather than serve potentially malformed data.
                guard decoded.schemaVersion == schemaVersion else {
                    throw VotingMetadataStorage.VMError.schemaVersionNotSupported
                }
                return decoded
            }
        }
        return nil
    }

    // MARK: - Helpers

    static func subdata(of data: Data, in range: Range<Int>) throws -> Data {
        guard data.count >= range.upperBound else {
            throw VotingMetadataStorage.VMError.subdataRange
        }
        return data.subdata(in: range)
    }

    static func bytesToInt(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == VotingMetadataStorage.Constants.int64Size else { return nil }
        return bytes.withUnsafeBytes { ptr -> Int? in
            Int(exactly: ptr.loadUnaligned(as: Int64.self).bigEndian)
        }
    }
}
#endif
