import Foundation

/// A single vote option within a proposal (e.g. "Support", "Oppose").
/// Maps to VoteOption message (zvote/v1/types.proto).
struct VoteOption: Equatable, Sendable {
    let index: UInt32
    let label: String

    init(index: UInt32, label: String) {
        self.index = index
        self.label = label
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
