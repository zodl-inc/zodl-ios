import Foundation

enum ProofStatus: Equatable {
    case notStarted
    case generating(progress: Double)
    case complete
    case failed(String)
}

enum SubmissionStatus: Equatable {
    case idle
    case submitting(proposalIndex: Int, total: Int)
    case complete
    case failed(String)
}
