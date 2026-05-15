import ComposableArchitecture
import Foundation

private actor VotingStore {
    var hotkeys: [Data: VotingHotkey] = [:]
    var delegations: [Data: DelegationRegistration] = [:]
    var sessions: [Data: VotingSession] = [:]

    func storeHotkey(roundId: Data, hotkey: VotingHotkey) {
        hotkeys[roundId] = hotkey
    }

    func loadHotkey(roundId: Data) -> VotingHotkey? {
        hotkeys[roundId]
    }

    func storeDelegation(roundId: Data, registration: DelegationRegistration) {
        delegations[roundId] = registration
    }

    func loadDelegation(roundId: Data) -> DelegationRegistration? {
        delegations[roundId]
    }

    func storeSession(_ session: VotingSession) {
        sessions[session.voteRoundId] = session
    }

    func loadSession(roundId: Data) -> VotingSession? {
        sessions[roundId]
    }

    func clearRound(roundId: Data) {
        hotkeys.removeValue(forKey: roundId)
        delegations.removeValue(forKey: roundId)
        sessions.removeValue(forKey: roundId)
    }
}

extension VotingStorageClient: DependencyKey {
    static var liveValue: Self {
        let store = VotingStore()

        return Self(
            storeHotkey: { roundId, hotkey in
                await store.storeHotkey(roundId: roundId, hotkey: hotkey)
            },
            loadHotkey: { roundId in
                await store.loadHotkey(roundId: roundId)
            },
            storeDelegation: { roundId, registration in
                await store.storeDelegation(roundId: roundId, registration: registration)
            },
            loadDelegation: { roundId in
                await store.loadDelegation(roundId: roundId)
            },
            storeSession: { session in
                await store.storeSession(session)
            },
            loadSession: { roundId in
                await store.loadSession(roundId: roundId)
            },
            clearRound: { roundId in
                await store.clearRound(roundId: roundId)
            }
        )
    }
}
