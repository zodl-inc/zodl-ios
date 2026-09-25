import Foundation

enum SubmissionStatus: Equatable {
    case idle
    case submitting(proposalIndex: Int, total: Int)
    case complete
    case failed(String)
}
