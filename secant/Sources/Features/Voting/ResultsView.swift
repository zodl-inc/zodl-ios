import SwiftUI
import ComposableArchitecture

private func tallyToZECNumber(_ value: UInt64) -> String {
    let zatoshi = value * ballotDivisor
    let zec = Double(zatoshi) / 100_000_000.0
    return String(format: "%.2f", zec)
}

private func formatWeightZEC(_ weight: UInt64) -> String {
    let zec = Double(weight) / 100_000_000.0
    return String(format: "%.3f", zec)
}

private func zodlTrustIndicator(colorScheme: ColorScheme) -> some View {
    let logoSize: CGFloat = 16
    let backdropSize = logoSize + 8
    let zodlTextColor = colorScheme == .light ? Color.black : Design.Text.primary.color(colorScheme)

    return HStack(spacing: 6) {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: backdropSize, height: backdropSize)

            Asset.Assets.zashiLogo.image
                .zImage(size: logoSize, color: .white)
        }

        Text("Zodl")
            .zFont(.medium, size: 12, color: zodlTextColor)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("Approved by Zodl"))
}

/// Color for a tally entry. Looks the option up on the proposal so Abstain
/// stays HyperBlue; falls back to a synthetic VoteOption for entries whose
/// decision index isn't in `proposal.options` (e.g. legacy Support/Oppose).
private func tallyEntryColor(
    decision: UInt32,
    proposal: VotingProposal,
    fallbackLabel: String,
    colorScheme: ColorScheme
) -> Color {
    let option = proposal.options.first { $0.index == decision }
        ?? VoteOption(index: decision, label: fallbackLabel)
    return voteOptionColor(for: option, total: proposal.options.count, colorScheme: colorScheme)
}

struct ResultsView: View {
    @Environment(\.colorScheme)
    var colorScheme
    @State private var loadErrorSheetPresented = true
    @State private var dismissFlowAfterLoadErrorSheetDismiss = false

    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                if store.resultsLoadError {
                    // Skeleton placeholder behind the "Couldn't load results"
                    // sheet, per the Figma. Replaces the real header + cards
                    // so the surface doesn't read as empty.
                    VStack(alignment: .leading, spacing: 16) {
                        ResultsSkeletonCard()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        roundHeader()

                        Text(localizable: .coinVoteResultsTitle)
                            .zFont(.semiBold, size: 18, style: Design.Text.primary)

                        if store.isLoadingTallyResults {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(localizable: .coinVoteResultsLoading)
                                    .zFont(size: 14, style: Design.Text.secondary)
                            }
                        } else {
                            VStack(spacing: 16) {
                                ForEach(Array(store.votingRound.proposals.enumerated()), id: \.element.id) { _, proposal in
                                    proposalResultCard(proposal: proposal)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiBack { store.send(.backToRoundsList) }
            .votingSheet(
                isPresented: loadErrorBinding,
                title: String(localizable: .coinVoteResultsLoadErrorTitle),
                message: String(localizable: .coinVoteResultsLoadErrorMessage),
                primary: .init(title: String(localizable: .coinVoteCommonTryAgain), style: .primary) {
                    store.send(.retryLoadTallyResults)
                },
                secondary: .init(title: String(localizable: .coinVoteCommonGoBack), style: .secondary) {
                    dismissFlowAfterLoadErrorSheetDismiss = true
                    loadErrorSheetPresented = false
                },
                onDismiss: {
                    guard dismissFlowAfterLoadErrorSheetDismiss else { return }
                    dismissFlowAfterLoadErrorSheetDismiss = false
                    store.send(.dismissFlow)
                }
            )
        }
    }

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { loadErrorSheetPresented && store.resultsLoadError },
            // Drag-dismiss mirrors Go back for the same reason as PollsListView.
            set: { newValue in
                if newValue {
                    loadErrorSheetPresented = true
                } else if store.resultsLoadError {
                    dismissFlowAfterLoadErrorSheetDismiss = true
                    loadErrorSheetPresented = false
                }
            }
        )
    }

    // MARK: - Round Header

    @ViewBuilder
    private func roundHeader() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.votingRound.title)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if store.isOnDefaultConfig, store.zodlEndorsedRoundIds.contains(store.roundId) {
                    zodlTrustIndicator(colorScheme: colorScheme)
                }
            }

            if !store.votingRound.description.isEmpty {
                Text(store.votingRound.description)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let record = store.voteRecord {
                Text(metaLine(for: record))
                    .zFont(size: 12, style: Design.Text.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    private func metaLine(for record: Voting.VoteRecord) -> String {
        let dateString = record.votedAt.formatted(.dateTime.month(.abbreviated).day())
        return String(
            localizable: .coinVoteResultsMetaLine(
                dateString,
                formatWeightZEC(record.votingWeight)
            )
        )
    }

    // MARK: - VotingProposal Result Card

    @ViewBuilder
    private func proposalResultCard(proposal: VotingProposal) -> some View {
        let tally = store.tallyResults[proposal.id]
        let rawEntries = tally?.entries ?? []
        // Backfill missing options so they always display (even with 0 votes).
        let knownDecisions = Set(rawEntries.map(\.decision))
        let backfilled: [TallyResult.Entry] = proposal.options.compactMap { option in
            knownDecisions.contains(option.index) ? nil : TallyResult.Entry(decision: option.index, amount: 0)
        }
        let entries = (rawEntries + backfilled).sorted(by: { $0.decision < $1.decision })
        let totalAmount = entries.reduce(UInt64(0)) { $0 + $1.amount }
        // Two or more entries sharing the top amount render as a tie: the
        // Winner badge says "Tie" (neutral) and every bar stays neutral,
        // because calling one of them the winner would be visually misleading.
        let maxAmount = entries.map(\.amount).max() ?? 0
        let topCount = entries.filter { $0.amount == maxAmount }.count
        let isTie = totalAmount > 0 && topCount > 1
        let winningEntry = (totalAmount > 0 && !isTie)
            ? entries.first { $0.amount == maxAmount }
            : nil

        VStack(alignment: .leading, spacing: 12) {
            // Top row: ZIP pill + Winner pill
            HStack(spacing: 0) {
                if let zipNumber = proposal.displayZipNumber {
                    ZIPBadge(zipNumber: zipNumber)
                }
                Spacer()
                winnerBadge(winningEntry: winningEntry, isTie: isTie, proposal: proposal)
            }

            // Title
            Text(proposal.title)
                .zFont(.semiBold, size: 18, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Description (truncated)
            if !proposal.description.isEmpty {
                Text(proposal.description)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Result bars
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
                            fallbackLabel: label,
                            colorScheme: colorScheme
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

            if totalAmount > 0 {
                Text(
                    localizable: .coinVoteResultsTotal(
                        String(localizable: .coinVoteCommonZecValue(tallyToZECNumber(totalAmount)))
                    )
                )
                    .zFont(size: 12, style: Design.Text.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .background(Design.Surfaces.bgSecondary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
    }

    // MARK: - Winner Badge

    @ViewBuilder
    private func winnerBadge(winningEntry: TallyResult.Entry?, isTie: Bool, proposal: VotingProposal) -> some View {
        HStack(spacing: 6) {
            // Seal only renders when there's a decisive winner — a tie gets
            // neutral framing, per the Figma.
            if !isTie, winningEntry != nil {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Design.Text.primary.color(colorScheme))
            }

            HStack(spacing: 4) {
                Text(localizable: .coinVoteResultsWinnerLabel)
                    .zFont(.medium, size: 13, style: Design.Text.primary)

                if isTie {
                    Text(localizable: .coinVoteResultsTie)
                        .zFont(.semiBold, size: 13, style: Design.Text.primary)
                } else if let winner = winningEntry {
                    let label = optionLabel(for: winner.decision, proposal: proposal)
                    let color = tallyEntryColor(
                        decision: winner.decision,
                        proposal: proposal,
                        fallbackLabel: label,
                        colorScheme: colorScheme
                    )
                    Text(label)
                        .zFont(.semiBold, size: 13, color: color)
                } else {
                    Text("—")
                        .zFont(.medium, size: 13, style: Design.Text.tertiary)
                }
            }
        }
    }

    // MARK: - Result Bar

    @ViewBuilder
    private func resultBar(label: String, amount: UInt64, total: UInt64, winnerColor: Color, isWinner: Bool) -> some View {
        let ratio = total > 0 ? Double(amount) / Double(total) : 0
        let labelColor: Color = isWinner ? winnerColor : Design.Text.tertiary.color(colorScheme)
        let fillColor: Color = isWinner ? winnerColor : Design.Text.tertiary.color(colorScheme)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .zFont(.medium, size: 14, color: labelColor)
                Spacer()
                Text(localizable: .coinVoteCommonZecValue(tallyToZECNumber(amount)))
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
            .frame(height: 8)
        }
    }

    // MARK: - Helpers

    private func optionLabel(for decision: UInt32, proposal: VotingProposal) -> String {
        if let option = proposal.options.first(where: { $0.index == decision }) {
            return option.label
        }
        // Fallback for proposals without explicit options
        switch decision {
        case 0: return String(localizable: .coinVoteCommonSupport)
        case 1: return String(localizable: .coinVoteCommonOppose)
        default: return String(localizable: .coinVoteResultsOption(String(decision)))
        }
    }
}

private struct ResultsSkeletonCard: View {
    @Environment(\.colorScheme)
    var colorScheme

    var body: some View {
        let barFill = Design.Surfaces.bgTertiary.color(colorScheme)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                RoundedRectangle(cornerRadius: 4).fill(barFill).frame(width: 60, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 4).fill(barFill).frame(width: 80, height: 12)
            }
            RoundedRectangle(cornerRadius: 4).fill(barFill).frame(height: 14)
            RoundedRectangle(cornerRadius: 4).fill(barFill).frame(height: 10)
            RoundedRectangle(cornerRadius: 4)
                .fill(barFill)
                .frame(width: 200, height: 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(barFill).frame(height: 10)
                RoundedRectangle(cornerRadius: 4).fill(barFill).frame(height: 10)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Surfaces.bgSecondary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
    }
}
