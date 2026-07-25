//
//  RoundListItem.swift
//  Zashi
//

#if VOTING_ENABLED
import Foundation

/// A single entry in the polls list: a voting round paired with the index
/// assigned at fetch time. The index is used purely as a fallback display
/// label when the round has no human-readable title from the service config.
///
/// Extracted from the old `Voting.State.RoundListItem` so the new
/// `VotingCoordFlow` can use the same type without depending on the legacy
/// monolithic reducer. Both old and new code reference this top-level type
/// during the migration; once the old reducer is deleted, this is the
/// canonical home.
struct RoundListItem: Equatable, Identifiable {
    var id: String { session.voteRoundId.hexString }
    let roundNumber: Int
    let session: VotingSession

    var title: String {
        session.title.isEmpty
            ? String(localizable: .coinVoteStoreRoundTitle(String(roundNumber)))
            : session.title
    }
}
#endif
