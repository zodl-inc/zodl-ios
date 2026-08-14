#if VOTING_ENABLED
//
//  ConfirmSubmissionView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture
import ZcashLightClientKit

/// Final review screen before vote submission. Renders four visual states from
/// the same body, driven by `RoundSession.batchSubmissionStatus`:
///   • `.idle` — Poll/Memo card + Confirm CTA
///   • `.authorizing` / `.submitting` — Poll/VotingPower card + monotonic
///     progress bar + disabled CTA reflecting the current sub-step
///   • `.completed` — Poll/VotingPower card + green-check icon + Done CTA
/// `.authorizationFailed` / `.submissionFailed` keep the in-progress chrome
/// underneath while a `votingSheet` drives retry/cancel.
struct ConfirmSubmissionView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    let store: StoreOf<VotingCoordFlow>
    let roundId: String

    var body: some View {
        WithPerceptionTracking {
            let session = store.roundCache[roundId]
            let status = session?.batchSubmissionStatus ?? .idle
            let pollTitle = store.allRounds.first { $0.id == roundId }?.title ?? ""
            let weightString = Self.formatZec(session?.votingWeight ?? 0)
            let drafts = session?.draftVotes ?? [:]
            let submittedVotes = session?.votes ?? [:]
            let bundleCount = session?.bundleCount ?? 0
            let delegationStatus = session?.delegationProofStatus ?? .notStarted
            let isKeystoneUser = store.isKeystoneUser

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerSection(status: status)
                        detailsCard(
                            status: status,
                            pollTitle: pollTitle,
                            weightString: weightString,
                            isKeystoneUser: isKeystoneUser
                        )
                        .padding(.top, 24)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

                Spacer(minLength: 0)

                bottomSection(
                    status: status,
                    delegationStatus: delegationStatus,
                    drafts: drafts,
                    submittedVotes: submittedVotes,
                    bundleCount: bundleCount
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .applyScreenBackground()
            .screenTitle(navTitle(status: status))
            .zashiBack {
                guard !status.isInFlight else { return }
                dismiss()
            }
            .votingSheet(
                isPresented: authorizationFailedBinding(status: status),
                title: String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedTitle),
                message: failureMessage(
                    status: status,
                    fallback: String(localizable: .coinVoteConfirmSubmissionAuthorizationFailedMessage)
                ),
                primary: .init(title: String(localizable: .coinVoteCommonTryAgain), style: .primary) {
                    store.send(.retryBatchSubmission(roundId: roundId))
                },
                secondary: .init(title: String(localizable: .coinVoteCommonCancel), style: .secondary) {
                    store.send(.dismissBatchResults(roundId: roundId))
                },
                visualStyle: .unverifiedWarning
            )
            .votingSheet(
                isPresented: submissionFailedBinding(status: status),
                title: String(localizable: .coinVoteConfirmSubmissionSubmissionFailedTitle),
                message: failureMessage(
                    status: status,
                    fallback: String(localizable: .coinVoteConfirmSubmissionSubmissionFailedMessage)
                ),
                primary: .init(title: String(localizable: .coinVoteCommonTryAgain), style: .primary) {
                    store.send(.retryBatchSubmission(roundId: roundId))
                },
                secondary: .init(title: String(localizable: .coinVoteCommonCancel), style: .secondary) {
                    store.send(.dismissBatchResults(roundId: roundId))
                },
                visualStyle: .unverifiedWarning
            )
            // Authorization + per-proposal submission can take several seconds
            // to tens of seconds; if the device locks mid-flight the user is
            // left with no visible progress and may not realize submission is
            // continuing. Keep the display awake while we're working.
            .onAppear { PlatformIdleTimer.disabled = status.isInFlight }
            .onChange(of: status.isInFlight) { newValue in
                PlatformIdleTimer.disabled = newValue
            }
            .onDisappear { PlatformIdleTimer.disabled = false }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerSection(status: BatchSubmissionStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VotingHeaderIcons(
                isKeystone: store.isKeystoneUser,
                showCheckmark: status.isCompleted
            )
            .padding(.top, 12)
            .padding(.bottom, 24)

            Text(headerTitle(status: status))
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(headerSubtitle(status: status))
                .zFont(size: 14, style: Design.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func navTitle(status: BatchSubmissionStatus) -> String {
        if case .idle = status {
            return String(localizable: .coinVoteCommonConfirmation)
        }
        return String(localizable: .coinVoteCommonSubmission)
    }

    private func headerTitle(status: BatchSubmissionStatus) -> String {
        switch status {
        case .idle:
            return String(localizable: .coinVoteConfirmSubmissionHeaderTitleIdle)
        case .authorizing, .submitting, .authorizationFailed, .submissionFailed:
            return String(localizable: .coinVoteConfirmSubmissionHeaderTitleSubmitting)
        case .completed:
            return String(localizable: .coinVoteConfirmSubmissionHeaderTitleCompleted)
        }
    }

    private func headerSubtitle(status: BatchSubmissionStatus) -> String {
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
    private func detailsCard(
        status: BatchSubmissionStatus,
        pollTitle: String,
        weightString: String,
        isKeystoneUser: Bool
    ) -> some View {
        let isIdle: Bool = {
            if case .idle = status { return true }
            return false
        }()

        VStack(spacing: 0) {
            detailRow(
                label: String(localizable: .coinVoteConfirmSubmissionDetailPoll),
                value: pollTitle
            )

            if isIdle && isKeystoneUser {
                EmptyView()
            } else if isIdle {
                detailsDivider()
                memoRow(pollTitle: pollTitle, weightString: weightString)
            } else {
                detailsDivider()
                detailRow(
                    label: String(localizable: .coinVoteConfirmSubmissionDetailVotingPower),
                    value: String(localizable: .coinVoteConfirmSubmissionDetailVotingPowerValue(weightString))
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
    private func memoRow(pollTitle: String, weightString: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizable: .coinVoteConfirmSubmissionDetailMemo)
                .zFont(size: 14, style: Design.Text.tertiary)
                .tracking(-0.224)

            Text(localizable: .coinVoteConfirmSubmissionMemoMessage(pollTitle, weightString))
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

    /// Authorization gets its own label until it finishes; submission then
    /// drives the bar from the (currentIndex, totalCount) pair. The 30%
    /// reservation for the delegation phase keeps the bar monotonic when
    /// the screen flips from authorizing to submitting mid-flight.
    private func submissionProgress(
        status: BatchSubmissionStatus,
        delegationStatus: ProofStatus
    ) -> (progress: Double, title: String) {
        let delegationWeight = 0.3

        switch status {
        case .authorizing:
            let proof: Double
            switch delegationStatus {
            case .generating(let value): proof = value
            case .complete: proof = 1.0
            default: proof = 0
            }
            return (
                proof * delegationWeight,
                String(localizable: .coinVoteStoreSubmissionAuthorizingVote)
            )

        case let .submitting(currentIndex, totalCount, _):
            let offset = delegationStatus == .complete ? delegationWeight : 0.0
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
    private func bottomSection(
        status: BatchSubmissionStatus,
        delegationStatus: ProofStatus,
        drafts: [UInt32: VoteChoice],
        submittedVotes: [UInt32: VoteChoice],
        bundleCount: UInt32
    ) -> some View {
        switch status {
        case .idle:
            ZashiButton(
                store.isKeystoneUser
                    ? String(localizable: .coinVoteConfirmSubmissionConfirmWithKeystone)
                    : String(localizable: .coinVoteCommonConfirm)
            ) {
                store.send(.submitAllDraftsTapped(roundId: roundId))
            }
            .disabled(drafts.isEmpty || bundleCount == 0)

        case .authorizing, .submitting, .authorizationFailed, .submissionFailed:
            // Progress card stays on screen while the error sheets (driven
            // by the `authorizationFailed` / `submissionFailed` bindings)
            // own retry / cancel.
            let progressInfo = submissionProgress(
                status: status,
                delegationStatus: delegationStatus
            )
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
                store.send(.submissionDoneTapped(roundId: roundId))
            }
        }
    }

    // MARK: - Sheet bindings

    private func authorizationFailedBinding(status: BatchSubmissionStatus) -> Binding<Bool> {
        Binding(
            get: {
                if case .authorizationFailed = status { return true }
                return false
            },
            set: { newValue in
                if !newValue {
                    store.send(.dismissBatchResults(roundId: roundId))
                }
            }
        )
    }

    private func submissionFailedBinding(status: BatchSubmissionStatus) -> Binding<Bool> {
        Binding(
            get: {
                if case .submissionFailed = status { return true }
                return false
            },
            set: { newValue in
                if !newValue {
                    store.send(.dismissBatchResults(roundId: roundId))
                }
            }
        )
    }

    /// The reducer pre-maps backend errors through `VotingErrorMapper` before
    /// storing them in `BatchSubmissionStatus`, so when a specific user-friendly
    /// string is available (e.g. the "nullifier already spent" → "wallet already
    /// registered" copy) it lives directly on the status. Fall back to the
    /// generic sheet copy only when no error string was carried.
    private func failureMessage(status: BatchSubmissionStatus, fallback: String) -> String {
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

    // MARK: - Helpers

    /// Zatoshi → "X.XXX" ZEC string. Three fractional digits matches the
    /// Polls list copy so the in-app voting-power values stay consistent.
    private static func formatZec(_ zatoshi: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 3
        formatter.maximumFractionDigits = 3
        formatter.usesGroupingSeparator = true
        let value = Zatoshi(Int64(zatoshi)).decimalValue.roundedZec
        return formatter.string(from: value) ?? "0.000"
    }
}

// MARK: - Header Icons

/// Restored from the agency build (deleted in `MOB-1105 Phase 5D`). Renders
/// the white Zashi disc + thumbs-up bubble, swapping the thumbs-up for a
/// green checkmark seal once submission succeeds. The Keystone variant uses
/// the brandmark disc instead of the white Zashi mark.
private struct VotingHeaderIcons: View {
    @Environment(\.colorScheme) var colorScheme
    var isKeystone: Bool = false
    var showCheckmark: Bool = false

    var body: some View {
        // Mirrors the disc-pair pattern from `TransactionDetailsView.headerView`:
        // the left disc has a `destinationOut` circle overlay that carves a
        // notch where the right disc sits, `compositingGroup()` scopes the
        // blend, and the foreground symbol is re-overlaid on top so it isn't
        // cut. The right disc is `offset(x: -4)` so it overlaps the notch
        // with a ~1.5pt halo (51pt mask vs. 48pt right disc).
        HStack(spacing: 0) {
            leftDisc
                .overlay {
                    Circle()
                        .frame(width: 51, height: 51)
                        .offset(x: 42)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .overlay { leftSymbol }

            rightDisc
                .offset(x: -4)
        }
    }

    @ViewBuilder
    private var leftDisc: some View {
        if isKeystone {
            Asset.Assets.Brandmarks.brandmarkKeystone.image
                .resizable()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Design.Text.primary.color(colorScheme))
                .frame(width: 48, height: 48)
        }
    }

    @ViewBuilder
    private var leftSymbol: some View {
        if !isKeystone {
            Asset.Assets.zashiLogo.image
                .zImage(size: 22, color: Design.Surfaces.bgPrimary.color(colorScheme))
        }
    }

    @ViewBuilder
    private var rightDisc: some View {
        if showCheckmark {
            ZStack {
                Circle()
                    .fill(Design.Utility.SuccessGreen._500.color(colorScheme).opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Design.Utility.SuccessGreen._500.color(colorScheme))
            }
        } else {
            ZStack {
                Circle()
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                    .frame(width: 48, height: 48)
                Image(systemName: "hand.thumbsup")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Design.Text.primary.color(colorScheme))
            }
        }
    }
}

private extension BatchSubmissionStatus {
    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    /// True while we're actively making network/proving progress — used by
    /// the view to disable the back gesture and CTA.
    var isInFlight: Bool {
        switch self {
        case .authorizing, .submitting:
            return true
        case .idle, .completed, .authorizationFailed, .submissionFailed:
            return false
        }
    }
}
#endif
