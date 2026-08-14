#if VOTING_ENABLED
//
//  ProposalDetailStore.swift
//  Zashi
//

import ComposableArchitecture
import Combine

@Reducer
struct ProposalDetail {
    /// Whether the user can change their answer here.
    /// - `.voting`: editable, Next CTA advances through the proposal stack.
    /// - `.review`: read-only — the round has been submitted and editing
    ///   would invalidate the completed-vote marker (see
    ///   `Voting.loadCompletedVoteRecord`, which returns nil whenever drafts
    ///   are non-empty).
    /// - `.reviewDrafts`: pre-submission edit-one mode opened from the
    ///   Review and submit vote screen. Editable like `.voting` but with no
    ///   Next CTA — the user toggles a single answer and dismisses with X.
    enum Mode: Equatable { case voting, review, reviewDrafts }

    @ObservableState
    struct State: Equatable {
        let roundId: String
        let proposalId: UInt32
        let mode: Mode

        init(roundId: String, proposalId: UInt32, mode: Mode = .voting) {
            self.roundId = roundId
            self.proposalId = proposalId
            self.mode = mode
        }
    }

    enum Action: Equatable {}

    var body: some ReducerOf<Self> {
        EmptyReducer()
    }
}
#endif
