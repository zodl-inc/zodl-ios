#if VOTING_ENABLED
//
//  ConfirmSubmissionDisplay.swift
//  Zashi
//

import Foundation

/// What the Confirm screen shows for a submission status: the header, and the
/// bottom of the screen, which is a button or the progress card.
///
/// Kept apart from the view so every status can be pinned by a test without
/// rendering anything. The progress card follows the Android app: a running
/// round starts from ``authorizationWeight`` and fills the rest from the
/// submission's measured share, titled with the questions done so far.
enum ConfirmSubmissionDisplay {
    /// The slice of the bar the old authorization phase owned. A running round
    /// starts from it, as the Android app's does.
    static let authorizationWeight = 0.3

    struct Header: Equatable {
        let title: String
        let subtitle: String
    }

    /// The bottom of the screen.
    enum Bottom: Equatable {
        /// The Confirm button, enabled when there is work to submit.
        case confirm
        /// The Confirm button, disabled behind a spinner while local
        /// authentication runs.
        case confirmInProgress
        /// The progress card, with a disabled button repeating its title.
        case progress(value: Double, title: String)
        /// The Done button.
        case done
    }

    static func header(status: BatchSubmissionStatus, isKeystone: Bool) -> Header {
        switch status {
        case .idle, .requested:
            return Header(
                title: String(localizable: .coinVoteConfirmSubmissionHeaderTitleIdle),
                subtitle: isKeystone
                    ? String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleIdleKeystone)
                    : String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleIdle)
            )
        case .authorizing, .submitting:
            return Header(
                title: String(localizable: .coinVoteConfirmSubmissionHeaderTitleSubmitting),
                subtitle: String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleSubmitting)
            )
        case .authorizationFailed:
            // The header says what the sheet says, rather than still reading as
            // a submission in progress behind it.
            return Header(
                title: String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedTitle),
                subtitle: failureMessage(
                    status: status,
                    fallback: String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedMessage)
                )
            )
        case .submissionFailed:
            return Header(
                title: String(localizable: .coinVoteConfirmSubmissionSubmissionFailedTitle),
                subtitle: failureMessage(
                    status: status,
                    fallback: String(localizable: .coinVoteConfirmSubmissionSubmissionFailedMessage)
                )
            )
        case .completed:
            return Header(
                title: String(localizable: .coinVoteConfirmSubmissionHeaderTitleCompleted),
                subtitle: String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleCompleted)
            )
        }
    }

    static func bottom(status: BatchSubmissionStatus, submission: VotingSubmissionProgress) -> Bottom {
        switch status {
        case .idle:
            return Bottom.confirm
        case .requested:
            // An automatic re-run passes through here without asking the voter
            // anything, so the card stays up with the bar it had.
            return submission.isRetrying ? running(submission) : Bottom.confirmInProgress
        case .authorizing:
            if submission.isRetrying {
                return running(submission)
            }
            return Bottom.progress(value: 0, title: String(localizable: .coinVoteStoreSubmissionAuthorizingVote))
        case .submitting:
            return running(submission)
        case .authorizationFailed:
            return Bottom.progress(value: 0, title: String(localizable: .coinVoteStoreSubmissionAuthorizingVote))
        case let .submissionFailed(_, submittedCount, totalCount):
            let fraction = Double(submittedCount) / Double(max(totalCount, 1))
            return Bottom.progress(
                value: min(1, authorizationWeight + fraction * (1 - authorizationWeight)),
                title: String(localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount(
                    String(submittedCount),
                    String(totalCount)
                ))
            )
        case .completed:
            return Bottom.done
        }
    }

    /// The failure a status carries, or `fallback` when it carries none.
    static func failureMessage(status: BatchSubmissionStatus, fallback: String) -> String {
        let storedError: String
        switch status {
        case .authorizationFailed(let error):
            storedError = error
        case .submissionFailed(let error, _, _):
            storedError = error
        default:
            return fallback
        }
        return storedError.isEmpty ? fallback : storedError
    }

    /// The card while a run drives the round, or waits to be run again.
    private static func running(_ submission: VotingSubmissionProgress) -> Bottom {
        let value = min(max(authorizationWeight + (submission.fraction ?? 0) * (1 - authorizationWeight), 0), 1)
        let title: String
        if submission.isRetrying {
            title = String(localizable: .coinVoteConfirmSubmissionProgressRetrying)
        } else if let total = submission.totalProposals, total > 0 {
            title = String(localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount(
                String(submission.estimatedCompletedProposals ?? 0),
                String(total)
            ))
        } else {
            title = String(localizable: .coinVoteSubmissionContinuedProcessingTitle)
        }
        return Bottom.progress(value: value, title: title)
    }
}
#endif
