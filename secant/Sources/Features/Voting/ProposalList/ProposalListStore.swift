#if VOTING_ENABLED
//
//  ProposalListStore.swift
//  Zashi
//

import ComposableArchitecture
import Combine

@Reducer
struct ProposalList {
    @ObservableState
    struct State: Equatable {
        let roundId: String

        init(roundId: String) {
            self.roundId = roundId
        }
    }

    enum Action: Equatable {}

    var body: some ReducerOf<Self> {
        EmptyReducer()
    }
}
#endif
