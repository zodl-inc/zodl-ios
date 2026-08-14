#if VOTING_ENABLED
//
//  ProposalListView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

/// Proposal list for a single voting round.
///
/// Bound to the new `VotingCoordFlow` parent store. The path destination
/// only carries `roundId`; all data (round metadata, proposals, voting
/// weight, drafts, submitted votes, etc.) is read from the parent's state
/// and cache.
struct ProposalListView: View {
    enum Mode: Equatable {
        /// Active voting — cards editable, sticky CTA reflects draft
        /// progress (Start Voting / Continue Voting / Review Answers).
        case voting

        /// Post-submission read-only — cards locked, no sticky CTA.
        case review

        /// Pre-submission "Review and submit vote" — cards remain
        /// editable (tap to change), sticky CTA is "Confirm & Submit"
        /// which leads to the Confirm Submission screen.
        case reviewDrafts
    }

    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<VotingCoordFlow>
    let roundId: String
    let mode: Mode

    /// Mode to push the ProposalDetail in when the user taps a card on this
    /// list. Review screens (both pre- and post-submission) preserve their
    /// own mode so the detail hides the Next CTA and dismisses with X
    /// straight back to the list.
    private var detailModeForTap: ProposalDetail.Mode {
        switch mode {
        case .voting:       return .voting
        case .review:       return .review
        case .reviewDrafts: return .reviewDrafts
        }
    }

    var body: some View {
        WithPerceptionTracking {
            let item = store.allRounds.first { $0.id == roundId }
            let proposals = item?.session.proposals ?? []
            let session = store.roundCache[roundId]
            let voteRecord = session?.voteRecord ?? store.voteRecords[roundId]
            let weight = displayWeight(
                session: session,
                voteRecord: voteRecord
            )
            let pipelineReady = session?.hotkeyAddress != nil && (session?.bundleCount ?? 0) > 0
            let drafts = session?.draftVotes ?? [:]
            let submittedVotes = session?.votes ?? [:]
            let displayedChoices = displayedChoices(
                drafts: drafts,
                submittedVotes: submittedVotes
            )
            let showCTA = (mode == .voting || mode == .reviewDrafts)
                && pipelineReady
                && !proposals.isEmpty

            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if mode == .reviewDrafts {
                            reviewDraftsHeader()
                        } else {
                            header(
                                title: item?.title ?? "",
                                description: item?.session.description ?? "",
                                snapshotHeight: item?.session.snapshotHeight ?? 0,
                                voteEndTime: item?.session.voteEndTime ?? Date(),
                                votedAt: voteRecord?.votedAt,
                                weight: weight,
                                ready: mode == .review || pipelineReady
                            )
                        }

                        if proposals.isEmpty {
                            Text(localizable: .coinVotePollsListEmptyMessage)
                                .zFont(size: 14, style: Design.Text.tertiary)
                        } else {
                            ForEach(proposals) { proposal in
                                Button {
                                    store.send(.proposalTapped(
                                        roundId: roundId,
                                        proposalId: proposal.id,
                                        mode: detailModeForTap
                                    ))
                                } label: {
                                    proposalCard(
                                        proposal,
                                        choice: displayedChoices[proposal.id]
                                    )
                                }
                                .zashiPlainButtonStyle()
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, showCTA ? 96 : 24)
                    // macOS: cap the scroll CONTENT so the full-width scroller reaches the window edge.
                    .macContentRowCap()
                }
                .padding(.vertical, 1)

                if showCTA {
                    // chrome pinned outside the scroll — cap it too so it stays in the column.
                    bottomCTA(proposals: proposals, choices: displayedChoices)
                        .macContentRowCap()
                }
            }
            .applyScreenBackground(capped: false)
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiBack()
        }
    }

    /// Pre-submission review header per the Figma — just the two text
    /// blocks ("Review and submit vote" + the "Tap to edit / Confirm &
    /// Submit" subtitle). The active-voting header's title + #block +
    /// ends/power row is intentionally omitted on this screen since
    /// the user is no longer setting up the round, they're confirming
    /// answers.
    @ViewBuilder
    private func reviewDraftsHeader() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizable: .coinVoteProposalListReviewTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .tracking(-0.384)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .coinVoteProposalListReviewSubtitle)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                .tracking(-0.224)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func header(
        title: String,
        description: String,
        snapshotHeight: UInt64,
        voteEndTime: Date,
        votedAt: Date?,
        weight: UInt64,
        ready: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row 1: poll title (left) + snapshot block number (right)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .zFont(.semiBold, size: 20, style: Design.Text.primary)
                    .tracking(-0.384)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("#\(snapshotHeight)")
                    .zFont(.medium, size: 20, style: Design.Text.primary)
                    .tracking(-0.224)
            }

            // Row 2: end date + voting power.
            // While the pipeline is still preparing, show the spinner row
            // instead so the user knows their voting power is being computed.
            // Once the user has voted (review mode + persisted vote record),
            // swap "Ends <date>" for "Voted <date>" using the locally-stored
            // `votedAt` from the encrypted metadata.
            if ready {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(headerDateText(voteEndTime: voteEndTime, votedAt: votedAt)) · ")
                    Text("\(String(localizable: .coinVoteProposalListVotingPower(formattedZec(zatoshi: weight)))) ZEC")

                    Spacer()
                }
                .zFont(.medium, size: 12, style: Design.Text.tertiary)
                .tracking(-0.224)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: false)
            } else {
                HStack(spacing: 8) {
                    ZashiSpinner()
                        .scaleEffect(0.75)
                    Text(localizable: .coinVoteProposalListPreparingVotingPower)
                        .zFont(.medium, size: 14, style: Design.Text.tertiary)
                }
            }

            // Row 3: poll description (only when non-empty). Starts collapsed
            // to 2 lines with a "View more" affordance; expands with an
            // animation. Toggle is only rendered when the text actually
            // overflows the collapsed limit.
            if !description.isEmpty {
                ExpandableText(text: description, collapsedLineLimit: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    /// Localized date string for the header end-date cell.
    private func formattedEndDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return formatter.string(from: date)
    }

    /// Header date cell copy. In review mode (i.e. the user has fully
    /// submitted a ballot) we surface the locally-known `votedAt` as
    /// "Voted <date>"; otherwise we fall back to the upcoming end date.
    private func headerDateText(voteEndTime: Date, votedAt: Date?) -> String {
        if mode == .review, let votedAt {
            return String(localizable: .coinVoteCommonVotedDate(formattedEndDate(votedAt)))
        }
        return String(localizable: .coinVoteProposalListHeaderEndsAt(formattedEndDate(voteEndTime)))
    }

    /// Voting power is stored as UInt64 zatoshi; the header copy shows ZEC.
    /// Uses the standard wallet formatter so values like 12_500_000 zatoshi
    /// render as `0.125`, matching the ineligible sheet's number style.
    private func formattedZec(zatoshi: UInt64) -> String {
        Zatoshi(Int64(zatoshi)).decimalZashiFormatted()
    }

    @ViewBuilder
    private func proposalCard(_ proposal: VotingProposal, choice: VoteChoice?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let zip = proposal.zipNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
               !zip.isEmpty {
                zipBadge(zip)
            }

            Text(proposal.title)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                .tracking(-0.256)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !proposal.description.isEmpty {
                Text(proposal.description)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .tracking(-0.224)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let choice, let label = label(for: choice, options: proposal.options) {
                yourVotePill(label: label)
                    .padding(.top, 8)
            }
        }
        .padding(Design.Spacing._xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Surfaces.bgPrimary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
        )
    }

    private func label(for choice: VoteChoice, options: [VoteOption]) -> String? {
        options.first { $0.index == choice.index }?.label
    }

    private func displayWeight(session: RoundSession?, voteRecord: Voting.VoteRecord?) -> UInt64 {
        if mode == .review, let voteRecord {
            return voteRecord.votingWeight
        }
        return session?.votingWeight ?? 0
    }

    private func displayedChoices(
        drafts: [UInt32: VoteChoice],
        submittedVotes: [UInt32: VoteChoice]
    ) -> [UInt32: VoteChoice] {
        guard mode == .voting || mode == .reviewDrafts else { return submittedVotes }

        var choices = submittedVotes
        choices.merge(drafts) { _, draft in draft }
        return choices
    }

    @ViewBuilder
    private func zipBadge(_ text: String) -> some View {
        Text(text)
            .zFont(.medium, size: 12, color: Design.Utility.Gray._700.color(colorScheme))
            .tracking(-0.072)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Design.Utility.Gray._100.color(colorScheme))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Design.Utility.Gray._200.color(colorScheme), lineWidth: 1)
            )
    }

    @ViewBuilder
    private func yourVotePill(label: String) -> some View {
        let tone = pillTone(for: label)
        Group {
            // Yes / No / Abstain are enum-like → one-line HStack.
            // Free-form custom answers (blue tone) are typically long →
            // two-line VStack with the answer below "Your vote:".
            if tone.isInline {
                HStack(spacing: 6) {
                    Text(localizable: .coinVoteProposalListYourVote)
                        .zFont(.medium, size: 12, color: tone.label.color(colorScheme))
                        .tracking(-0.072)

                    Spacer(minLength: 8)

                    Text(label)
                        .zFont(.semiBold, size: 14, color: tone.text.color(colorScheme))
                        .tracking(-0.224)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizable: .coinVoteProposalListYourVote)
                        .zFont(.medium, size: 12, color: tone.label.color(colorScheme))
                        .tracking(-0.072)

                    Text(label)
                        .zFont(.semiBold, size: 14, color: tone.text.color(colorScheme))
                        .tracking(-0.224)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tone.background.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._md))
    }

    /// Color category for the "Your vote:" pill. Picks a non-opinionated
    /// palette so a free-form custom answer (e.g. "Smooth issuance curve")
    /// doesn't get a charged green/red — only literal Yes/Support / No/Oppose
    /// get those tones. `isInline` is true for the enum-like answers
    /// (Yes/No/Abstain) where label + value fit on one line; false for the
    /// long free-form answers that need a stacked layout.
    private func pillTone(for label: String) -> PillTone {
        // TODO: Replace English label matching with backend-provided option
        // semantics once the voting metadata exposes them.
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "support":
            return PillTone(
                background: Design.Utility.SuccessGreen._50,
                label: Design.Utility.SuccessGreen._700,
                text: Design.Utility.SuccessGreen._700,
                isInline: true
            )
        case "no", "oppose":
            return PillTone(
                background: Design.Utility.ErrorRed._50,
                label: Design.Utility.ErrorRed._700,
                text: Design.Utility.ErrorRed._700,
                isInline: true
            )
        case "abstain":
            return PillTone(
                background: Design.Utility.Gray._100,
                label: Design.Utility.Gray._700,
                text: Design.Utility.Gray._700,
                isInline: true
            )
        default:
            return PillTone(
                background: Design.Utility.HyperBlue._50,
                label: Design.Utility.HyperBlue._700,
                text: Design.Utility.HyperBlue._700,
                isInline: false
            )
        }
    }

    private struct PillTone {
        let background: Colorable
        let label: Colorable
        let text: Colorable
        let isInline: Bool
    }

    /// Sticky bottom CTA. Label and action depend on the screen mode and
    /// draft progress:
    /// - `.voting`, no choices yet     → "Start Voting", opens proposal #1
    /// - `.voting`, some choices       → "Continue Voting", opens the
    ///                                   first proposal still missing a
    ///                                   choice
    /// - `.voting`, all answered       → "Review Answers", pushes the
    ///                                   pre-submission Review screen
    /// - `.reviewDrafts`               → "Confirm & Submit", routes to
    ///                                   the Confirm Submission screen
    private func bottomCTA(
        proposals: [VotingProposal],
        choices: [UInt32: VoteChoice]
    ) -> some View {
        let title: String
        let action: () -> Void
        if mode == .reviewDrafts {
            title = String(localizable: .coinVoteProposalListCtaConfirmSubmit)
            action = {
                store.send(.submitTapped(roundId: roundId))
            }
        } else if let nextUnanswered = proposals.first(where: { choices[$0.id] == nil }) {
            title = choices.isEmpty
                ? String(localizable: .coinVoteProposalListCtaStartVoting)
                : String(localizable: .coinVoteProposalListCtaContinueVoting)
            let nextId = nextUnanswered.id
            action = {
                store.send(
                    .proposalTapped(
                        roundId: roundId,
                        proposalId: nextId,
                        mode: .voting
                    )
                )
            }
        } else {
            title = String(localizable: .coinVoteProposalListCtaReviewAnswers)
            action = {
                store.send(.openReviewDraftsScreen(roundId: roundId))
            }
        }

        return VStack(spacing: 0) {
            ZashiButton(title, action: action)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [
                    Design.Surfaces.bgPrimary.color(colorScheme).opacity(0),
                    Design.Surfaces.bgPrimary.color(colorScheme).opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// Long-form text that starts collapsed at `collapsedLineLimit` lines and
/// reveals the rest with a "View more" / "View less" toggle. The toggle
/// only appears when the text actually overflows the collapsed limit —
/// computed from intrinsic (off-screen) heights so the verdict doesn't
/// flip when the visible text expands. Animates between states on tap.
private struct ExpandableText: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let collapsedLineLimit: Int

    @State private var isExpanded: Bool = false
    @State private var fullIntrinsicHeight: CGFloat = 0
    @State private var collapsedIntrinsicHeight: CGFloat = 0

    /// True when the un-truncated text is taller than the same text rendered
    /// at the collapsed line limit — i.e. there's something to expand. Both
    /// heights are measured invisibly so the verdict is independent of the
    /// current `isExpanded` state.
    private var isTruncated: Bool {
        fullIntrinsicHeight > collapsedIntrinsicHeight + 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(truncationProbe)
                .animation(.easeInOut(duration: 0.25), value: isExpanded)

            // Two-way affordance: "View more ▼" when collapsed,
            // "View less ▲" when expanded. Toggle is rendered only when
            // the text actually overflows the collapsed line limit.
            if isTruncated {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded
                             ? String(localizable: .coinVoteCommonViewLess)
                             : String(localizable: .coinVoteCommonViewMore))
                            .zFont(.semiBold, size: 14, style: Design.Text.primary)
                            .tracking(-0.224)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Design.Text.primary.color(colorScheme))
                    }
                }
                .zashiPlainButtonStyle()
            }
        }
    }

    /// Two hidden text probes layered behind the visible label: one rendered
    /// at full intrinsic height (no line limit) and one clamped to the
    /// collapsed line limit. Reporting via preference keys keeps the values
    /// stable across expand / collapse toggles.
    private var truncationProbe: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ExpandableTextFullHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )

            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .lineLimit(collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ExpandableTextCollapsedHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .hidden()
        .onPreferenceChange(ExpandableTextFullHeightKey.self) { fullIntrinsicHeight = $0 }
        .onPreferenceChange(ExpandableTextCollapsedHeightKey.self) { collapsedIntrinsicHeight = $0 }
    }
}

private struct ExpandableTextFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ExpandableTextCollapsedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
