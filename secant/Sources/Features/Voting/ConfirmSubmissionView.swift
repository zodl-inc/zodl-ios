import SwiftUI
import ComposableArchitecture

struct ConfirmSubmissionView: View {
    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerSection()
                        detailsCard()
                            .padding(.top, 24)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

                Spacer(minLength: 0)

                bottomSection()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
            .applyScreenBackground()
            .screenTitle(navTitle)
            .zashiBack {
                if !isInFlight { store.send(.backToList) }
            }
            .votingSheet(
                isPresented: authorizationFailedBinding,
                title: String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedTitle),
                message: String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedMessage),
                primary: .init(title: String(localizable: .coinVoteCommonTryAgain), style: .primary) {
                    store.send(.retryBatchSubmission)
                },
                secondary: .init(title: String(localizable: .coinVoteCommonCancel), style: .secondary) {
                    store.send(.dismissBatchResults)
                },
                visualStyle: .unverifiedWarning
            )
            .votingSheet(
                isPresented: submissionFailedBinding,
                title: String(localizable: .coinVoteConfirmSubmissionSubmissionFailedTitle),
                message: String(localizable: .coinVoteConfirmSubmissionSubmissionFailedMessage),
                primary: .init(title: String(localizable: .coinVoteCommonTryAgain), style: .primary) {
                    store.send(.retryBatchSubmission)
                },
                secondary: .init(title: String(localizable: .coinVoteCommonCancel), style: .secondary) {
                    store.send(.dismissBatchResults)
                },
                visualStyle: .unverifiedWarning
            )
        }
    }

    // MARK: - Sheet bindings

    private var authorizationFailedBinding: Binding<Bool> {
        Binding(
            get: { if case .authorizationFailed = status { return true } else { return false } },
            set: { newValue in
                if !newValue { store.send(.dismissBatchResults) }
            }
        )
    }

    private var submissionFailedBinding: Binding<Bool> {
        Binding(
            get: { if case .submissionFailed = status { return true } else { return false } },
            set: { newValue in
                if !newValue { store.send(.dismissBatchResults) }
            }
        )
    }

    // MARK: - Computed

    private var status: Voting.State.BatchSubmissionStatus {
        store.batchSubmissionStatus
    }

    private var isInFlight: Bool {
        store.isBatchSubmitting
    }

    private var isCompleted: Bool {
        if case .completed = status { return true }
        return false
    }

    private var navTitle: String {
        if case .idle = status {
            return String(localizable: .coinVoteCommonConfirmation)
        }
        return String(localizable: .coinVoteCommonSubmission)
    }

    // MARK: - Header

    @ViewBuilder
    private func headerSection() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VotingHeaderIcons(isKeystone: store.isKeystoneUser, showCheckmark: isCompleted)
                .padding(.top, 12)
                .padding(.bottom, 24)

            Text(headerTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(headerSubtitle)
                .zFont(size: 14, style: Design.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerTitle: String {
        switch status {
        case .idle:
            return String(localizable: .coinVoteConfirmSubmissionHeaderTitleIdle)
        case .authorizing, .submitting, .authorizationFailed, .submissionFailed:
            // Failure overlays (.authorizationFailed / .submissionFailed) keep
            // the in-progress appearance underneath while the sheet drives UX.
            return String(localizable: .coinVoteConfirmSubmissionHeaderTitleSubmitting)
        case .completed:
            return String(localizable: .coinVoteConfirmSubmissionHeaderTitleCompleted)
        }
    }

    private var headerSubtitle: String {
        switch status {
        case .idle:
            if store.isKeystoneUser {
                return String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleIdleKeystone)
            }
            return String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleIdle)
        case .authorizing, .submitting, .authorizationFailed, .submissionFailed:
            return String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleSubmitting)
        case .completed:
            return String(localizable: .coinVoteConfirmSubmissionHeaderSubtitleCompleted)
        }
    }

    // MARK: - Details Card

    @ViewBuilder
    private func detailsCard() -> some View {
        let isIdle = { if case .idle = status { return true }; return false }()

        VStack(spacing: 0) {
            detailRow(label: String(localizable: .coinVoteConfirmSubmissionDetailPoll), value: store.votingRound.title)

            if isIdle {
                detailsDivider()
                memoRow()
            } else {
                detailsDivider()
                detailRow(
                    label: String(localizable: .coinVoteConfirmSubmissionDetailVotingPower),
                    value: String(localizable: .coinVoteConfirmSubmissionDetailVotingPowerValue(store.votingWeightZECString))
                )
            }
        }
        .background(Design.Surfaces.bgSecondary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .zFont(size: 14, style: Design.Text.tertiary)
                .tracking(-0.224)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func memoRow() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizable: .coinVoteConfirmSubmissionDetailMemo)
                .zFont(size: 14, style: Design.Text.tertiary)
                .tracking(-0.224)

            Text(localizable: .coinVoteConfirmSubmissionMemoMessage(store.votingRound.title, store.votingWeightZECString))
                .zFont(.medium, size: 12, style: Design.Text.primary)
                .tracking(-0.072)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func detailsDivider() -> some View {
        Design.Surfaces.bgPrimary.color(colorScheme)
            .frame(height: 1)
    }

    // MARK: - Progress

    // Authorization has its own label; after that, the user-facing progress is
    // proposal count only, regardless of the protocol phase inside each vote.
    private var submissionProgress: (progress: Double, title: String) {
        let delegationWeight = 0.3

        switch status {
        case .authorizing:
            let p: Double
            switch store.delegationProofStatus {
            case .generating(let pp): p = pp
            case .complete: p = 1.0
            default: p = 0
            }
            return (p * delegationWeight, String(localizable: .coinVoteStoreSubmissionAuthorizingVote))

        case let .submitting(currentIndex, totalCount, _):
            let offset = store.delegationProofStatus == .complete ? delegationWeight : 0.0
            let fraction = Double(currentIndex + 1) / Double(max(totalCount, 1))
            let overall = min(1.0, offset + fraction * (1.0 - offset))
            return (
                overall,
                String(
                    localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount(
                        String(currentIndex + 1),
                        String(totalCount)
                    )
                )
            )

        case .authorizationFailed:
            return (0, String(localizable: .coinVoteStoreSubmissionAuthorizingVote))

        case let .submissionFailed(_, submittedCount, totalCount):
            let fraction = Double(submittedCount) / Double(max(totalCount, 1))
            let overall = min(1.0, delegationWeight + fraction * (1.0 - delegationWeight))
            return (
                overall,
                String(
                    localizable: .coinVoteConfirmSubmissionProgressSubmittingVoteCount(
                        String(submittedCount),
                        String(totalCount)
                    )
                )
            )

        default:
            return (0, "")
        }
    }

    // MARK: - Bottom Section

    @ViewBuilder
    private func bottomSection() -> some View {
        switch status {
        case .idle:
            ZashiButton(
                store.isKeystoneUser
                    ? String(localizable: .coinVoteConfirmSubmissionConfirmWithKeystone)
                    : String(localizable: .coinVoteCommonConfirm)
            ) {
                store.send(.submitAllDrafts)
            }

        case .authorizing, .submitting, .authorizationFailed, .submissionFailed:
            // Progress card stays on screen underneath the error sheet, which
            // is driven by the authorizationFailed / submissionFailed bindings
            // and owns the retry/cancel affordance.
            let progressInfo = submissionProgress
            VStack(spacing: Design.Spacing._lg) {
                VStack(alignment: .leading, spacing: Design.Spacing._lg) {
                    Text(progressInfo.title)
                        .zFont(.semiBold, size: 15, style: Design.Text.primary)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Design.Text.primary.color(colorScheme))
                                .frame(width: geo.size.width * progressInfo.progress)
                                .animation(.easeInOut(duration: 0.3), value: progressInfo.progress)
                        }
                    }
                    .frame(height: 8)
                }
                .padding(Design.Spacing._2xl)
                .background(Design.Surfaces.bgSecondary.color(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius._xl))

                ZashiButton(progressInfo.title) {}
                    .disabled(true)
            }

        case .completed:
            ZashiButton(String(localizable: .coinVoteCommonDone)) {
                store.send(.doneTapped)
            }
        }
    }
}
