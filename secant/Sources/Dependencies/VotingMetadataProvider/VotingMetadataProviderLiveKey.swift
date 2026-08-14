#if VOTING_ENABLED
//
//  VotingMetadataProviderLiveKey.swift
//  Zashi
//

import ComposableArchitecture

extension VotingMetadataProviderClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        let storage = VotingMetadataStorage.live

        return VotingMetadataProviderClient(
            load: { try storage.load(account: $0) },
            store: { try storage.store(account: $0) },
            resetAccount: { try storage.resetAccount($0) },
            reset: { storage.clearMemory() },
            loadDrafts: { storage.loadDrafts(roundId: $0) },
            setDrafts: { storage.setDrafts($0, roundId: $1) },
            clearDrafts: { storage.clearDrafts(roundId: $0) },
            loadSubmittedVotes: { storage.loadSubmittedVotes(roundId: $0) },
            setSubmittedVotes: { storage.setSubmittedVotes($0, roundId: $1) },
            clearSubmittedVotes: { storage.clearSubmittedVotes(roundId: $0) },
            record: { storage.record(roundId: $0) },
            allRecords: { storage.allRecords() },
            setRecord: { storage.setRecord($0, roundId: $1) },
            clearRecord: { storage.clearRecord(roundId: $0) }
        )
    }
}

extension VotingMetadataStorage {
    static let live = VotingMetadataStorage()
}
#endif
