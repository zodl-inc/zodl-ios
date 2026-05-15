import Foundation

struct VotingRound: Equatable {
    let id: String
    let title: String
    let description: String
    let discussionURL: URL?
    let snapshotHeight: UInt64
    let snapshotDate: Date
    let votingStart: Date
    let votingEnd: Date
    let proposals: [VotingProposal]

    init(
        id: String,
        title: String,
        description: String,
        discussionURL: URL? = nil,
        snapshotHeight: UInt64,
        snapshotDate: Date,
        votingStart: Date,
        votingEnd: Date,
        proposals: [VotingProposal]
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.discussionURL = discussionURL
        self.snapshotHeight = snapshotHeight
        self.snapshotDate = snapshotDate
        self.votingStart = votingStart
        self.votingEnd = votingEnd
        self.proposals = proposals
    }

    var daysRemaining: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: votingEnd).day ?? 0
    }
}
