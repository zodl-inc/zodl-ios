import SwiftUI
import ComposableArchitecture

struct ProposalDetailView: View {
    @Environment(\.colorScheme)
    var colorScheme
    @State private var showUnansweredSheet = false

    let store: StoreOf<Voting>
    let proposal: VotingProposal

    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private static let scrollTopID = "proposal-detail-scroll-top"

    var body: some View {
        WithPerceptionTracking {
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    ScrollView {
                        Color.clear
                            .frame(height: 0)
                            .id(Self.scrollTopID)

                        contentSection()
                    }
                    .id(proposal.id)
                    .onAppear {
                        scrollToTop(scrollProxy)
                    }
                    .onChange(of: proposal.id) { _ in
                        scrollToTop(scrollProxy)
                    }

                    bottomSection()
                }
            }
            .applyScreenBackground()
            .navigationBarBackButtonHidden(true)
            .navigationBarTitleDisplayMode(.inline)
            .votingSheet(
                isPresented: $showUnansweredSheet,
                title: String(localizable: .coinVoteProposalDetailUnansweredTitle),
                message: unansweredMessage,
                primary: .init(title: String(localizable: .coinVoteCommonGoBack), style: .primary) {
                    showUnansweredSheet = false
                    store.send(.dismissUnanswered)
                },
                secondary: .init(title: String(localizable: .coinVoteCommonConfirm), style: .secondary) {
                    showUnansweredSheet = false
                    store.send(.confirmUnanswered)
                }
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.send(.backToList)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Design.Text.primary.color(colorScheme))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(positionLabel)
                        .zFont(.semiBold, size: 14, style: Design.Text.primary)
                        .textCase(.uppercase)
                }
            }
        }
    }

    private func scrollToTop(_ scrollProxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollProxy.scrollTo(Self.scrollTopID, anchor: .top)
            }
        }
    }

    private var positionLabel: String {
        if let index = store.detailProposalIndex {
            return String(
                localizable: .coinVoteProposalDetailPosition(
                    String(index + 1),
                    String(store.totalProposals)
                )
            )
        }
        return ""
    }

    // MARK: - Content

    @ViewBuilder
    private func contentSection() -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text(proposal.title)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .tracking(-0.384)
                    .fixedSize(horizontal: false, vertical: true)

                if !proposal.description.isEmpty {
                    Text(proposal.description)
                        .zFont(size: 16, style: Design.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if proposal.forumURL != nil {
                forumLink()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    // MARK: - Forum Link

    @ViewBuilder
    private func forumLink() -> some View {
        let content = HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                    .frame(width: 40, height: 40)
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Design.Text.primary.color(colorScheme))
            }

            Text(localizable: .coinVoteProposalDetailViewForumDiscussion)
                .zFont(.medium, size: 16, style: Design.Text.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Design.Text.tertiary.color(colorScheme))
        }
        .frame(height: 40)

        if let url = proposal.forumURL {
            Link(destination: url) { content }
        }
    }

    // MARK: - Bottom Section

    @ViewBuilder
    private func bottomSection() -> some View {
        let confirmedVote = store.votes[proposal.id]
        let isSubmitted = store.voteRecord != nil
        let isLocked = confirmedVote != nil || store.allVoted || store.isBatchSubmitting || isSubmitted

        VStack(spacing: 20) {
            voteOptions(isLocked: isLocked)
            if !store.allVoted && !isSubmitted {
                navigationButtons()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    // MARK: - Vote Options

    /// Options including an Abstain fallback when the data doesn't provide one.
    private var displayOptions: [VoteOption] {
        let hasAbstain = proposal.options.contains {
            $0.label.localizedCaseInsensitiveContains("abstain")
        }
        if hasAbstain || proposal.options.isEmpty {
            return proposal.options
        }
        let nextIndex = (proposal.options.map(\.index).max() ?? 0) + 1
        return proposal.options + [VoteOption(index: nextIndex, label: String(localizable: .coinVoteCommonAbstain))]
    }

    @ViewBuilder
    private func voteOptions(isLocked: Bool) -> some View {
        let options = displayOptions
        let displayChoice = store.effectiveChoices[proposal.id]

        VStack(spacing: 8) {
            ForEach(options, id: \.index) { option in
                let choice = VoteChoice.option(option.index)
                let isSelected = displayChoice == choice

                voteOptionRow(
                    label: option.label,
                    isSelected: isSelected,
                    color: voteOptionColor(for: option, total: options.count, colorScheme: colorScheme),
                    isLocked: isLocked
                ) {
                    impactFeedback.impactOccurred()
                    store.send(.castVote(proposalId: proposal.id, choice: choice))
                }
            }
        }
    }

    @ViewBuilder
    private func voteOptionRow(
        label: String,
        isSelected: Bool,
        color: Color,
        isLocked: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .zFont(.semiBold, size: 16,
                           color: Design.Text.primary.color(colorScheme))

                Spacer()

                // Checkbox
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Design.Radius._sm)
                            .fill(Design.Checkboxes.onBg.color(colorScheme))
                            .frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Design.Checkboxes.onFg.color(colorScheme))
                    } else {
                        RoundedRectangle(cornerRadius: Design.Radius._sm)
                            .fill(Design.Checkboxes.offBg.color(colorScheme))
                            .overlay {
                                RoundedRectangle(cornerRadius: Design.Radius._sm)
                                    .stroke(Design.Checkboxes.offStroke.color(colorScheme), lineWidth: 1)
                            }
                            .frame(width: 20, height: 20)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(isSelected ? color : Design.Surfaces.bgSecondary.color(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius._xl))
        }
        .disabled(isLocked)
    }

    // MARK: - Navigation Buttons

    @ViewBuilder
    private func navigationButtons() -> some View {
        HStack(spacing: 12) {
            if store.isEditingFromReview {
                ZashiButton(String(localizable: .coinVoteCommonCancel), type: .secondary) {
                    store.send(.cancelEdit)
                }
                ZashiButton(String(localizable: .coinVoteCommonSave)) {
                    store.send(.saveEdit)
                }
            } else {
                if let index = store.detailProposalIndex, index > 0 {
                    ZashiButton(String(localizable: .coinVoteCommonBack), type: .tertiary) {
                        store.send(.backToList)
                    }
                }
                ZashiButton(String(localizable: .coinVoteCommonNext)) {
                    let isLast = store.detailProposalIndex == store.totalProposals - 1
                    if isLast && !store.allDrafted {
                        showUnansweredSheet = true
                    } else {
                        store.send(.nextProposalDetail)
                    }
                }
            }
        }
    }

    private var unansweredMessage: String {
        let count = store.votingRound.proposals.filter { store.draftVotes[$0.id] == nil }.count
        if count == 1 {
            return String(localizable: .coinVoteProposalDetailUnansweredMessageSingle(String(count)))
        }
        return String(localizable: .coinVoteProposalDetailUnansweredMessageMultiple(String(count)))
    }
}
