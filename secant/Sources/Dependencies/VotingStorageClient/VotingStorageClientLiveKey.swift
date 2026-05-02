import ComposableArchitecture
import Foundation
import os

private final class VotingStore: Sendable {
    private enum Constants {
        static let storageDirectoryName = "Voting"
        static let storageFileName = "voting-state.json"
        static let legacyDraftPrefix = "voting.draftVotes."
        static let legacyVoteRecordPrefix = "voting.voteRecord."
    }

    private enum StorageError: Error {
        case applicationSupportDirectoryUnavailable
    }

    private struct PersistentState: Codable, Equatable, Sendable {
        var draftVotes: [String: [String: UInt32]] = .init()
        var completedVoteRecords: [String: VotingCompletionRecord] = .init()

        var isEmpty: Bool {
            draftVotes.isEmpty && completedVoteRecords.isEmpty
        }
    }

    private struct MutableState: Sendable {
        var hotkeys: [Data: VotingHotkey] = .init()
        var delegations: [Data: DelegationRegistration] = .init()
        var sessions: [Data: VotingSession] = .init()
        var persistentState: PersistentState?
    }

    private let state = OSAllocatedUnfairLock(initialState: MutableState())
    private let storageURL: URL?

    init(storageURL: URL? = VotingStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    func storeHotkey(roundId: Data, hotkey: VotingHotkey) {
        state.withLock {
            $0.hotkeys[roundId] = hotkey
        }
    }

    func loadHotkey(roundId: Data) -> VotingHotkey? {
        state.withLock {
            $0.hotkeys[roundId]
        }
    }

    func storeDelegation(roundId: Data, registration: DelegationRegistration) {
        state.withLock {
            $0.delegations[roundId] = registration
        }
    }

    func loadDelegation(roundId: Data) -> DelegationRegistration? {
        state.withLock {
            $0.delegations[roundId]
        }
    }

    func storeSession(_ session: VotingSession) {
        state.withLock {
            $0.sessions[session.voteRoundId] = session
        }
    }

    func loadSession(roundId: Data) -> VotingSession? {
        state.withLock {
            $0.sessions[roundId]
        }
    }

    func clearRound(roundId: Data) {
        state.withLock {
            $0.hotkeys.removeValue(forKey: roundId)
            $0.delegations.removeValue(forKey: roundId)
            $0.sessions.removeValue(forKey: roundId)
        }
    }

    func storeDraftVotes(walletId: String, roundId: String, drafts: [UInt32: VoteChoice]) throws {
        try state.withLock { mutable in
            var persistentState = try persistentState(&mutable)
            let key = Self.storageKey(walletId: walletId, roundId: roundId)

            if drafts.isEmpty {
                persistentState.draftVotes.removeValue(forKey: key)
            } else {
                persistentState.draftVotes[key] = Self.encodeDrafts(drafts)
            }

            try writePersistentState(persistentState)
            mutable.persistentState = persistentState
        }
    }

    func loadDraftVotes(walletId: String, roundId: String) throws -> [UInt32: VoteChoice] {
        try state.withLock { mutable in
            let persistentState = try persistentState(&mutable)
            let key = Self.storageKey(walletId: walletId, roundId: roundId)
            return Self.decodeDrafts(persistentState.draftVotes[key] ?? [:])
        }
    }

    func clearDraftVotes(walletId: String, roundId: String) throws {
        try state.withLock { mutable in
            var persistentState = try persistentState(&mutable)
            let key = Self.storageKey(walletId: walletId, roundId: roundId)
            persistentState.draftVotes.removeValue(forKey: key)
            try writePersistentState(persistentState)
            mutable.persistentState = persistentState
        }
    }

    func storeCompletedVoteRecord(walletId: String, roundId: String, record: VotingCompletionRecord) throws {
        try state.withLock { mutable in
            var persistentState = try persistentState(&mutable)
            let key = Self.storageKey(walletId: walletId, roundId: roundId)
            persistentState.completedVoteRecords[key] = record
            try writePersistentState(persistentState)
            mutable.persistentState = persistentState
        }
    }

    func loadCompletedVoteRecord(walletId: String, roundId: String) throws -> VotingCompletionRecord? {
        try state.withLock { mutable in
            var persistentState = try persistentState(&mutable)
            let key = Self.storageKey(walletId: walletId, roundId: roundId)

            if !(persistentState.draftVotes[key] ?? [:]).isEmpty {
                persistentState.completedVoteRecords.removeValue(forKey: key)
                try writePersistentState(persistentState)
                mutable.persistentState = persistentState
                return nil
            }

            return persistentState.completedVoteRecords[key]
        }
    }

    func loadCompletedVoteRecords(walletId: String, roundIds: [String]) throws -> [String: VotingCompletionRecord] {
        try state.withLock { mutable in
            var persistentState = try persistentState(&mutable)
            var records: [String: VotingCompletionRecord] = .init()
            var didRemoveStaleRecords = false

            for roundId in roundIds {
                let key = Self.storageKey(walletId: walletId, roundId: roundId)
                if !(persistentState.draftVotes[key] ?? [:]).isEmpty {
                    if persistentState.completedVoteRecords.removeValue(forKey: key) != nil {
                        didRemoveStaleRecords = true
                    }
                    continue
                }

                if let record = persistentState.completedVoteRecords[key] {
                    records[roundId] = record
                }
            }

            if didRemoveStaleRecords {
                try writePersistentState(persistentState)
                mutable.persistentState = persistentState
            }

            return records
        }
    }

    func clearCompletedVoteRecord(walletId: String, roundId: String) throws {
        try state.withLock { mutable in
            var persistentState = try persistentState(&mutable)
            let key = Self.storageKey(walletId: walletId, roundId: roundId)
            persistentState.completedVoteRecords.removeValue(forKey: key)
            try writePersistentState(persistentState)
            mutable.persistentState = persistentState
        }
    }

    func clearPersistentState() throws {
        state.withLock {
            $0.persistentState = PersistentState()
        }
        Self.clearLegacyUserDefaults()

        guard let storageURL else {
            throw StorageError.applicationSupportDirectoryUnavailable
        }

        if FileManager.default.fileExists(atPath: storageURL.path) {
            try FileManager.default.removeItem(at: storageURL)
        }
    }
}

private extension VotingStore {
    private func persistentState(_ mutable: inout MutableState) throws -> PersistentState {
        if let persistentState = mutable.persistentState {
            return persistentState
        }

        var loadedState = try readPersistentState()
        let migratedLegacyState = Self.migrateLegacyUserDefaults(into: &loadedState)

        if migratedLegacyState {
            try writePersistentState(loadedState)
        }

        mutable.persistentState = loadedState
        return loadedState
    }

    private func readPersistentState() throws -> PersistentState {
        guard let storageURL else {
            throw StorageError.applicationSupportDirectoryUnavailable
        }

        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return PersistentState()
        }

        let data = try Data(contentsOf: storageURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(PersistentState.self, from: data)
    }

    private func writePersistentState(_ persistentState: PersistentState) throws {
        guard let storageURL else {
            throw StorageError.applicationSupportDirectoryUnavailable
        }

        if persistentState.isEmpty {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                try FileManager.default.removeItem(at: storageURL)
            }
            return
        }

        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(persistentState)
        try data.write(to: storageURL, options: .atomic)

        var resourceURL = storageURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(resourceValues)
    }

    private static func defaultStorageURL() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Constants.storageDirectoryName, isDirectory: true)
            .appendingPathComponent(Constants.storageFileName, isDirectory: false)
    }

    private static func storageKey(walletId: String, roundId: String) -> String {
        "\(walletId)|\(roundId)"
    }

    private static func encodeDrafts(_ drafts: [UInt32: VoteChoice]) -> [String: UInt32] {
        drafts.reduce(into: [String: UInt32]()) { encoded, entry in
            encoded[String(entry.key)] = entry.value.index
        }
    }

    private static func decodeDrafts(_ drafts: [String: UInt32]) -> [UInt32: VoteChoice] {
        drafts.reduce(into: [UInt32: VoteChoice]()) { decoded, entry in
            if let proposalId = UInt32(entry.key) {
                decoded[proposalId] = .option(entry.value)
            }
        }
    }

    private static func migrateLegacyUserDefaults(into persistentState: inout PersistentState) -> Bool {
        let defaults = UserDefaults.standard
        var didMigrate = false

        for (key, value) in defaults.dictionaryRepresentation() {
            if key.hasPrefix(Constants.legacyDraftPrefix) {
                let storageKey = String(key.dropFirst(Constants.legacyDraftPrefix.count))
                if let drafts = legacyDrafts(from: value), !drafts.isEmpty {
                    persistentState.draftVotes[storageKey] = drafts
                }
                defaults.removeObject(forKey: key)
                didMigrate = true
            } else if key.hasPrefix(Constants.legacyVoteRecordPrefix) {
                let storageKey = String(key.dropFirst(Constants.legacyVoteRecordPrefix.count))
                if let record = legacyVoteRecord(from: value) {
                    persistentState.completedVoteRecords[storageKey] = record
                }
                defaults.removeObject(forKey: key)
                didMigrate = true
            }
        }

        return didMigrate
    }

    private static func clearLegacyUserDefaults() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(Constants.legacyDraftPrefix) || key.hasPrefix(Constants.legacyVoteRecordPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func legacyDrafts(from value: Any) -> [String: UInt32]? {
        guard let rawDrafts = value as? [String: Any] else {
            return nil
        }

        return rawDrafts.reduce(into: [String: UInt32]()) { drafts, entry in
            if let choice = entry.value as? UInt32 {
                drafts[entry.key] = choice
            } else if let choice = entry.value as? Int,
                choice >= 0,
                choice <= Int(UInt32.max) {
                drafts[entry.key] = UInt32(choice)
            } else if let choice = entry.value as? NSNumber {
                drafts[entry.key] = choice.uint32Value
            }
        }
    }

    private static func legacyVoteRecord(from value: Any) -> VotingCompletionRecord? {
        guard
            let rawRecord = value as? [String: Any],
            let votedAtUnix = doubleValue(rawRecord["votedAt"]),
            let votingWeight = uint64Value(rawRecord["votingWeight"])
        else {
            return nil
        }

        return VotingCompletionRecord(
            votedAt: Date(timeIntervalSince1970: votedAtUnix),
            votingWeight: votingWeight,
            proposalCount: intValue(rawRecord["proposalCount"]) ?? 0
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        } else if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        } else if let value = value as? Int, value >= 0 {
            return UInt64(value)
        } else if let value = value as? NSNumber {
            return value.uint64Value
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        } else if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

extension VotingStorageClient: DependencyKey {
    static var liveValue: Self {
        let store = VotingStore()

        return Self(
            storeHotkey: { roundId, hotkey in
                store.storeHotkey(roundId: roundId, hotkey: hotkey)
            },
            loadHotkey: { roundId in
                store.loadHotkey(roundId: roundId)
            },
            storeDelegation: { roundId, registration in
                store.storeDelegation(roundId: roundId, registration: registration)
            },
            loadDelegation: { roundId in
                store.loadDelegation(roundId: roundId)
            },
            storeSession: { session in
                store.storeSession(session)
            },
            loadSession: { roundId in
                store.loadSession(roundId: roundId)
            },
            clearRound: { roundId in
                store.clearRound(roundId: roundId)
            },
            storeDraftVotes: { walletId, roundId, drafts in
                try store.storeDraftVotes(walletId: walletId, roundId: roundId, drafts: drafts)
            },
            loadDraftVotes: { walletId, roundId in
                try store.loadDraftVotes(walletId: walletId, roundId: roundId)
            },
            clearDraftVotes: { walletId, roundId in
                try store.clearDraftVotes(walletId: walletId, roundId: roundId)
            },
            storeCompletedVoteRecord: { walletId, roundId, record in
                try store.storeCompletedVoteRecord(walletId: walletId, roundId: roundId, record: record)
            },
            loadCompletedVoteRecord: { walletId, roundId in
                try store.loadCompletedVoteRecord(walletId: walletId, roundId: roundId)
            },
            loadCompletedVoteRecords: { walletId, roundIds in
                try store.loadCompletedVoteRecords(walletId: walletId, roundIds: roundIds)
            },
            clearCompletedVoteRecord: { walletId, roundId in
                try store.clearCompletedVoteRecord(walletId: walletId, roundId: roundId)
            },
            clearPersistentState: {
                try store.clearPersistentState()
            }
        )
    }
}
