#if VOTING_ENABLED
import Foundation

/// A single vote option within a proposal (e.g. "Support", "Oppose").
/// Maps to VoteOption message (zvote/v1/types.proto).
///
/// `description` is optional richer copy that policy-heavy polls (NU7, NSM,
/// etc.) use to explain the consequences of choosing the option. UI renders
/// it as a second line below `label` when present.
struct VoteOption: Equatable, Sendable {
    let index: UInt32
    let label: String
    let description: String?

    init(index: UInt32, label: String, description: String? = nil) {
        self.index = index
        self.label = label
        self.description = description
    }
}

/// Maps to Proposal message (zvote/v1/types.proto).
/// Chain uses uint32 id. UI-only metadata (zipNumber, forumURL) comes from off-chain sources.
struct VotingProposal: Equatable, Identifiable, Sendable {
    let id: UInt32
    let title: String
    let description: String
    let options: [VoteOption]
    let zipNumber: String?
    let forumURL: URL?

    init(
        id: UInt32,
        title: String,
        description: String,
        options: [VoteOption] = [],
        zipNumber: String? = nil,
        forumURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.options = options
        self.zipNumber = zipNumber
        self.forumURL = forumURL
    }
}

#endif
