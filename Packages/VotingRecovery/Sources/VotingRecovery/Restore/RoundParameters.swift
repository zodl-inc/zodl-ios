import Foundation

/// The round a delegation belongs to, as the SDK's restore wants it. Built by
/// the app from its own session type at the one call site.
public struct RoundParameters: Equatable, Sendable {
    public let voteRoundId: Data
    public let snapshotHeight: UInt64
    public let eaPK: Data
    public let ncRoot: Data
    public let nullifierIMTRoot: Data

    public init(voteRoundId: Data, snapshotHeight: UInt64, eaPK: Data, ncRoot: Data, nullifierIMTRoot: Data) {
        self.voteRoundId = voteRoundId
        self.snapshotHeight = snapshotHeight
        self.eaPK = eaPK
        self.ncRoot = ncRoot
        self.nullifierIMTRoot = nullifierIMTRoot
    }
}
