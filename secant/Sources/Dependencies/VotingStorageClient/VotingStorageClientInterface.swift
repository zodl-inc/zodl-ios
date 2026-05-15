import ComposableArchitecture
import Foundation

extension DependencyValues {
    var votingStorage: VotingStorageClient {
        get { self[VotingStorageClient.self] }
        set { self[VotingStorageClient.self] = newValue }
    }
}

@DependencyClient
struct VotingStorageClient {
    var storeHotkey: @Sendable (_ roundId: Data, _ hotkey: VotingHotkey) async throws -> Void
    var loadHotkey: @Sendable (_ roundId: Data) async -> VotingHotkey?
    var storeDelegation: @Sendable (_ roundId: Data, _ registration: DelegationRegistration) async throws -> Void
    var loadDelegation: @Sendable (_ roundId: Data) async -> DelegationRegistration?
    var storeSession: @Sendable (_ session: VotingSession) async throws -> Void
    var loadSession: @Sendable (_ roundId: Data) async -> VotingSession?
    var clearRound: @Sendable (_ roundId: Data) async -> Void
}
