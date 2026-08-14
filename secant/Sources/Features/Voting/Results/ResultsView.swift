#if VOTING_ENABLED
//
//  ResultsView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture
import Foundation

/// Final results view for a finalized round.
///
/// Restores the agency layout (per-option progress bars, ZIP pill, Winner
/// badge, Voted footer + total) over the new `VotingCoordFlow` store. Tally
/// results are cached in `RoundSession.tallyResults`; the view triggers
/// `.fetchTallyResults` on first appear and is idempotent on re-entry
/// because finalized rounds are immutable.
struct ResultsView: View {
    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<VotingCoordFlow>
    let roundId: String

    var body: some View {
        WithPerceptionTracking {
            let item = store.allRounds.first { $0.id == roundId }
            let proposals = item?.session.proposals ?? []
            let cached = store.roundCache[roundId]
            let tallyResults = cached?.tallyResults ?? [:]
            let loaded = cached?.tallyFetched ?? false
            let tallyError = cached?.tallyError
            let voteRecord = store.voteRecords[roundId]
            let submittedVotes = cached?.votes ?? [:]
            let isZodlEndorsed = store.isOnDefaultConfig
                && store.zodlEndorsedRoundIds.contains(roundId)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    roundHeader(
                        title: item?.title ?? "",
                        description: item?.session.description ?? "",
                        record: voteRecord,
                        isZodlEndorsed: isZodlEndorsed
                    )

                    if let tallyError {
                        loadErrorBody(message: tallyError)
                    } else if !loaded {
                        HStack(spacing: 8) {
                            ZashiSpinner().scaleEffect(0.75)
                            Text(localizable: .coinVoteResultsLoading)
                                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        }
                    } else {
                        Text(localizable: .coinVoteResultsTitle)
                            .zFont(.semiBold, size: 18, style: Design.Text.primary)

                        if proposals.isEmpty {
                            Text(localizable: .coinVoteResultsNoProposalsInRound)
                                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        } else {
                            VStack(spacing: 16) {
                                ForEach(proposals) { proposal in
                                    proposalResultCard(
                                        proposal: proposal,
                                        tally: tallyResults[proposal.id],
                                        userChoice: submittedVotes[proposal.id]
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                // macOS: cap the scroll CONTENT so the full-width scroller reaches the window edge.
                .macContentRowCap()
            }
            .padding(.vertical, 1)
            .applyScreenBackground(capped: false)
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiBack()
            .onAppear { store.send(.fetchTallyResults(roundId: roundId)) }
        }
    }

    // MARK: - Round Header

    @ViewBuilder
    private func roundHeader(
        title: String,
        description: String,
        record: Voting.VoteRecord?,
        isZodlEndorsed: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .tracking(-0.384)
                    .fixedSize(horizontal: false, vertical: true)

                if isZodlEndorsed {
                    zodlTrustIndicator
                }
            }

            if let record {
                Text(metaLine(for: record))
                    .zFont(.medium, size: 12, style: Design.Text.tertiary)
                    .tracking(-0.144)
            }

            if !description.isEmpty {
                ExpandableText(text: description, collapsedLineLimit: 2)
            }
        }
    }

    private func metaLine(for record: Voting.VoteRecord) -> String {
        let dateString = record.votedAt.formatted(.dateTime.month(.abbreviated).day().year())
        return String(
            localizable: .coinVoteResultsMetaLine(
                dateString,
                Self.formatWeightZEC(record.votingWeight)
            )
        )
    }

    private var zodlTrustIndicator: some View {
        let logoSize: CGFloat = 16
        let backdropSize = logoSize + 8
        let zodlTextColor = colorScheme == .light
            ? Color.black
            : Design.Text.primary.color(colorScheme)

        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.black)
                    .frame(width: backdropSize, height: backdropSize)
                Asset.Assets.zashiLogo.image
                    .zImage(size: logoSize, color: .white)
            }
            Text(localizable: .coinVotePollsListApprovedByZodl)
                .zFont(.medium, size: 12, color: zodlTextColor)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Load Error Body

    @ViewBuilder
    private func loadErrorBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizable: .coinVoteResultsLoadErrorTitle)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                .tracking(-0.256)

            Text(message)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                .tracking(-0.224)
                .fixedSize(horizontal: false, vertical: true)

            ZashiButton(String(localizable: .coinVoteCommonTryAgain)) {
                store.send(.retryFetchTallyResults(roundId: roundId))
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Per-proposal Card

    @ViewBuilder
    private func proposalResultCard(
        proposal: VotingProposal,
        tally: TallyResult?,
        userChoice: VoteChoice?
    ) -> some View {
        let rawEntries = tally?.entries ?? []
        // Backfill missing options so they always display (even with 0 votes).
        let knownDecisions = Set(rawEntries.map(\.decision))
        let backfilled: [TallyResult.Entry] = proposal.options.compactMap { option in
            knownDecisions.contains(option.index)
                ? nil
                : TallyResult.Entry(decision: option.index, amount: 0)
        }
        let entries = (rawEntries + backfilled).sorted { $0.decision < $1.decision }
        let totalAmount = entries.reduce(UInt64(0)) { $0 + $1.amount }
        // Two or more entries sharing the top amount render as a tie:
        // the Winner badge says "Tie" (neutral) and every bar stays
        // neutral, because calling one of them the winner would be
        // visually misleading.
        let maxAmount = entries.map(\.amount).max() ?? 0
        let topCount = entries.filter { $0.amount == maxAmount }.count
        let isTie = totalAmount > 0 && topCount > 1
        let winningEntry: TallyResult.Entry? = (totalAmount > 0 && !isTie)
            ? entries.first { $0.amount == maxAmount }
            : nil

        VStack(alignment: .leading, spacing: 12) {
            if let zip = proposal.zipNumber?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !zip.isEmpty {
                HStack(spacing: 0) {
                    zipBadge(zip)
                    Spacer()
                }
            }

            Text(proposal.title)
                .zFont(.semiBold, size: 18, style: Design.Text.primary)
                .tracking(-0.288)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(entries, id: \.decision) { entry in
                    let isWinner = entry.decision == winningEntry?.decision
                    let label = optionLabel(for: entry.decision, proposal: proposal)
                    resultBar(
                        label: label,
                        amount: entry.amount,
                        total: totalAmount,
                        winnerColor: tallyEntryColor(
                            decision: entry.decision,
                            proposal: proposal,
                            fallbackLabel: label
                        ),
                        isWinner: isWinner
                    )
                }
            }
            .padding(.top, 4)

            if entries.isEmpty {
                Text(localizable: .coinVoteResultsNoVotesRecorded)
                    .zFont(.medium, size: 13, style: Design.Text.tertiary)
            }

            footer(
                totalAmount: totalAmount,
                userChoice: userChoice,
                proposal: proposal
            )
        }
        .padding(16)
        .background(Design.Surfaces.bgSecondary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
    }

    // MARK: - Footer (Voted: <option> · Total: X ZEC)

    /// Per-card footer. Renders the user's voted option label (when we
    /// have it — populated for finalized rounds via the coordinator's
    /// `loadSubmittedVotesFromDb` call on `.roundTapped`) on the left, and
    /// the round-wide Total on the right. Either side may be absent: if
    /// the tally has no recorded votes the Total drops; if the user
    /// didn't submit a choice for this proposal (skipped) the Voted line
    /// drops. If both are absent, the whole footer collapses.
    @ViewBuilder
    private func footer(
        totalAmount: UInt64,
        userChoice: VoteChoice?,
        proposal: VotingProposal
    ) -> some View {
        let votedLabel: String? = userChoice
            .map { optionLabel(for: $0.index, proposal: proposal) }

        if votedLabel != nil || totalAmount > 0 {
            HStack(alignment: .center, spacing: 8) {
                if let votedLabel {
                    Text(localizable: .coinVoteResultsVotedLine(votedLabel))
                        .zFont(.medium, size: 12, style: Design.Text.tertiary)
                        .tracking(-0.144)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if totalAmount > 0 {
                    let totalString = String(
                        localizable: .coinVoteCommonZecValue(Self.tallyToZECNumber(totalAmount))
                    )
                    Text(localizable: .coinVoteResultsTotal(totalString))
                        .zFont(.medium, size: 12, style: Design.Text.tertiary)
                        .tracking(-0.144)
                        .lineLimit(1)
                        .frame(maxWidth: votedLabel == nil ? .infinity : nil, alignment: .trailing)
                }
            }
            .padding(.top, 8)
            .overlay(
                Rectangle()
                    .fill(Design.Surfaces.strokeSecondary.color(colorScheme))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity, alignment: .top),
                alignment: .top
            )
        }
    }

    // MARK: - Result Bar

    @ViewBuilder
    private func resultBar(
        label: String,
        amount: UInt64,
        total: UInt64,
        winnerColor: Color,
        isWinner: Bool
    ) -> some View {
        let ratio = total > 0 ? Double(amount) / Double(total) : 0
        let labelColor: Color = isWinner
            ? winnerColor
            : Design.Text.tertiary.color(colorScheme)
        let fillColor: Color = isWinner
            ? winnerColor
            : Design.Text.tertiary.color(colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .zFont(.medium, size: 14, color: labelColor)
                Spacer()
                Text(localizable: .coinVoteCommonZecValue(Self.tallyToZECNumber(amount)))
                    .zFont(.medium, size: 14, color: labelColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(fillColor)
                        .frame(width: max(0, geo.size.width * ratio))
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - ZIP pill

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

    // MARK: - Option label / color helpers

    private func optionLabel(for decision: UInt32, proposal: VotingProposal) -> String {
        if let option = proposal.options.first(where: { $0.index == decision }) {
            return option.label
        }
        switch decision {
        case 0: return String(localizable: .coinVoteCommonSupport)
        case 1: return String(localizable: .coinVoteCommonOppose)
        default: return String(localizable: .coinVoteResultsOption(String(decision)))
        }
    }

    /// Pick the tally-bar color for an option. Looks the option up on the
    /// proposal so the label-based mapping in `voteOptionColor` can fire;
    /// falls back to a synthetic `VoteOption` for entries whose decision
    /// index isn't in `proposal.options` (e.g. legacy Support / Oppose
    /// rounds).
    private func tallyEntryColor(
        decision: UInt32,
        proposal: VotingProposal,
        fallbackLabel: String
    ) -> Color {
        let option = proposal.options.first { $0.index == decision }
            ?? VoteOption(index: decision, label: fallbackLabel)
        return Self.voteOptionColor(for: option, colorScheme: colorScheme)
    }

    /// Color mapping per product spec:
    ///   • Yes / Support → SuccessGreen
    ///   • No  / Oppose  → ErrorRed
    ///   • Abstain       → Gray
    ///   • everything else → HyperBlue
    /// Mirrors `ProposalListView.pillTone(for:)` so the same answer renders
    /// with the same color across the voting screens.
    /// Matches against the literal English option label until the voting
    /// metadata exposes a typed option-kind (same caveat as
    /// `ProposalListView.pillTone`).
    static func voteOptionColor(for option: VoteOption, colorScheme: ColorScheme) -> Color {
        switch option.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "yes", "support":
            return Design.Utility.SuccessGreen._500.color(colorScheme)
        case "no", "oppose":
            return Design.Utility.ErrorRed._500.color(colorScheme)
        case "abstain":
            return Design.Utility.Gray._500.color(colorScheme)
        default:
            return Design.Utility.HyperBlue._500.color(colorScheme)
        }
    }

    // MARK: - ZEC formatting

    /// Tally amounts come back in voting-power "ballot" units, not raw
    /// zatoshi — multiply by `ballotDivisor` to get the equivalent zatoshi,
    /// then divide for ZEC.
    static func tallyToZECNumber(_ value: UInt64) -> String {
        let zatoshi = value * ballotDivisor
        let zec = Double(zatoshi) / 100_000_000.0
        return String(format: "%.2f", zec)
    }

    /// `VoteRecord.votingWeight` is already in zatoshi.
    static func formatWeightZEC(_ weight: UInt64) -> String {
        let zec = Double(weight) / 100_000_000.0
        return String(format: "%.3f", zec)
    }
}

// MARK: - ExpandableText

/// Local copy of the `ExpandableText` already used by `ProposalListView`.
/// Kept private to this file to avoid a cross-file rename / visibility
/// change; the source pattern is identical so a future consolidation can
/// move both into `UIComponents/`.
private struct ExpandableText: View {
    @Environment(\.colorScheme) private var colorScheme

    let text: String
    let collapsedLineLimit: Int

    @State private var isExpanded: Bool = false
    @State private var fullIntrinsicHeight: CGFloat = 0
    @State private var collapsedIntrinsicHeight: CGFloat = 0

    private var isTruncated: Bool {
        fullIntrinsicHeight > collapsedIntrinsicHeight + 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                .tracking(-0.224)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(truncationProbe)
                .animation(.easeInOut(duration: 0.25), value: isExpanded)

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

    private var truncationProbe: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                .tracking(-0.224)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ResultsExpandableTextFullHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )

            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                .tracking(-0.224)
                .lineLimit(collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ResultsExpandableTextCollapsedHeightKey.self,
                            value: geo.size.height
                        )
                    }
                )
        }
        .hidden()
        .onPreferenceChange(ResultsExpandableTextFullHeightKey.self) { fullIntrinsicHeight = $0 }
        .onPreferenceChange(ResultsExpandableTextCollapsedHeightKey.self) { collapsedIntrinsicHeight = $0 }
    }
}

private struct ResultsExpandableTextFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ResultsExpandableTextCollapsedHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
#endif
