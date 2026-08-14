#if VOTING_ENABLED
//
//  ProposalDetailView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture
import Foundation

/// Proposal detail with vote-choice selection. Tapping an option writes
/// through to `roundCache[roundId].draftVotes[proposalId]` and persists
/// to the encrypted voting metadata file. Submitted choices are read from
/// `roundCache[roundId].votes[proposalId]` and rendered read-only.
struct ProposalDetailView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var forumURLToOpen: ForumURL?

    let store: StoreOf<VotingCoordFlow>
    let roundId: String
    let proposalId: UInt32
    let mode: ProposalDetail.Mode

    /// Identifiable wrapper so the in-app browser sheet can bind to the URL
    /// itself — avoids a parallel bool + url pair.
    private struct ForumURL: Identifiable {
        let id = UUID()
        let url: URL
    }

    init(
        store: StoreOf<VotingCoordFlow>,
        roundId: String,
        proposalId: UInt32,
        mode: ProposalDetail.Mode = .voting
    ) {
        self.store = store
        self.roundId = roundId
        self.proposalId = proposalId
        self.mode = mode
    }

    var body: some View {
        WithPerceptionTracking {
            let proposals = store.allRounds.first { $0.id == roundId }?.session.proposals ?? []
            let info = proposalInfo(in: proposals)
            let session = store.roundCache[roundId]
            let selected = selectedChoice(
                draftChoice: session?.draftVotes[proposalId],
                submittedChoice: session?.votes[proposalId]
            )
            let isLocked = mode == .review || session?.votes[proposalId] != nil
            let forumURL = browserSafeForumURL(info.proposal?.forumURL)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                        if let proposal = info.proposal {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(proposal.title)
                                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                                    .tracking(-0.384)
                                    .fixedSize(horizontal: false, vertical: true)

                                if !proposal.description.isEmpty {
                                    Text(proposal.description)
                                        .zFont(.medium, size: 14, style: Design.Text.primary)
                                        .tracking(-0.224)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)

                            if !proposal.options.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(Array(proposal.options.enumerated()), id: \.element.index) { offset, option in
                                        if offset > 0 {
                                            Divider()
                                                .frame(height: 1)
                                        }
                                        optionRow(
                                            option,
                                            selected: selected,
                                            isLocked: isLocked
                                        )
                                    }
                                }
                                .padding(.top, 16)
                            }
                        } else {
                            Text(localizable: .coinVoteProposalDetailNotFound)
                                .zFont(.medium, size: 14, style: Design.Text.tertiary)
                                .padding(.horizontal, 24)
                                .padding(.top, 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 1)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomBar(forumURL: forumURL)
                }
            .applyScreenBackground()
            .screenTitle(info.screenTitle)
            .zashiBackV2(customDismiss: {
                store.send(.dismissProposalDetailStack)
            })
            .sheet(item: $forumURLToOpen) { wrapper in
                InAppBrowserView(url: wrapper.url)
            }
            .votingSheet(
                isPresented: skippedQuestionsSheetBinding,
                title: String(localizable: .coinVoteProposalDetailUnansweredTitle),
                message: skippedQuestionsSheetMessage,
                primary: .init(
                    title: String(localizable: .coinVoteCommonGoBack),
                    style: .primary
                ) {
                    store.send(.skippedQuestionsGoBackTapped)
                },
                secondary: skippedQuestionsConfirmAction
            )
        }
    }

    private var skippedQuestionsConfirmAction: VotingSheetContent.ButtonConfig? {
        guard store.roundCache[roundId]?.draftVotes.isEmpty == false else {
            return nil
        }
        return .init(
            title: String(localizable: .coinVoteCommonConfirm),
            style: .secondary
        ) {
            store.send(.confirmSkippedQuestionsAndReview(roundId: roundId))
        }
    }

    /// True only while the coordinator-owned sheet matches this round.
    /// Scoping by `roundId` means stray ProposalDetail screens from
    /// other rounds (e.g. after a path swap) don't accidentally render
    /// the sheet over themselves.
    private var skippedQuestionsSheetBinding: Binding<Bool> {
        Binding(
            get: { store.skippedQuestionsSheet?.roundId == roundId },
            set: { newValue in
                if !newValue {
                    store.send(.dismissSkippedQuestionsSheet)
                }
            }
        )
    }

    /// Localized sheet body showing the count of proposals the user hasn't
    /// answered. Singular vs plural copy differs ("this question" vs
    /// "these questions"), so we route through two distinct keys. Empty
    /// fallback so the `.votingSheet` modifier doesn't crash during its
    /// dismiss animation when the state has just been cleared.
    private var skippedQuestionsSheetMessage: String {
        guard let sheet = store.skippedQuestionsSheet else { return "" }
        let count = sheet.skippedDisplayIndices.count
        if count == 1 {
            return String(localizable: .coinVoteProposalDetailSkippedMessageSingle(String(count)))
        }
        return String(localizable: .coinVoteProposalDetailSkippedMessageMultiple(String(count)))
    }

    /// Bundles the current proposal and its 1-indexed screen title.
    /// Packing them into one helper keeps the body builder under the
    /// SwiftUI inference budget so the view type stays resolvable.
    /// The Next CTA's destination is decided by the coordinator now —
    /// the view just dispatches an action with the current proposal id.
    private struct ProposalInfo {
        let proposal: VotingProposal?
        let screenTitle: String
    }

    private func proposalInfo(in proposals: [VotingProposal]) -> ProposalInfo {
        guard let position = proposals.firstIndex(where: { $0.id == proposalId }) else {
            return ProposalInfo(
                proposal: nil,
                screenTitle: String(localizable: .coinVoteCommonScreenTitle)
            )
        }
        let title = String(
            localizable: .coinVoteProposalDetailPosition(
                String(position + 1),
                String(proposals.count)
            )
        )
        return ProposalInfo(
            proposal: proposals[position],
            screenTitle: title
        )
    }

    private func browserSafeForumURL(_ url: URL?) -> URL? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url
    }

    /// Sticky bottom region. Hosts the optional "View Forum Discussion" row
    /// (when the proposal carries a browser-safe `forumURL`) above the Next CTA.
    /// The Next CTA is only shown in active voting; review screens open detail
    /// one proposal at a time and exit with X. The forum row stays visible in
    /// every mode so users can always read the
    /// upstream discussion before deciding (or while reviewing).
    @ViewBuilder
    private func bottomBar(forumURL: URL?) -> some View {
        let showNext = mode == .voting
        if forumURL != nil || showNext {
            VStack(spacing: Design.Spacing._3xl) {
                if let forumURL {
                    forumDiscussionRow(url: forumURL)
                }
                
                if showNext {
                    ZashiButton(String(localizable: .coinVoteCommonNext)) {
                        store.send(
                            .proposalDetailNextTapped(
                                roundId: roundId,
                                currentProposalId: proposalId
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 8)
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

    /// Tap target for the in-app browser launch. Icon-bubble + label +
    /// chevron, matching the Figma cell. Whole row is one button so the
    /// hit-test area is comfortable on a phone.
    private func forumDiscussionRow(url: URL) -> some View {
        Button {
            forumURLToOpen = ForumURL(url: url)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                        .frame(width: 40, height: 40)
                    Asset.Assets.Icons.messageChat.image
                        .zImage(size: 20, style: Design.Text.primary)
                }

                Text(localizable: .coinVoteProposalDetailViewForumDiscussion)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    .tracking(-0.256)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Asset.Assets.chevronRight.image
                    .zImage(size: 20, style: Design.Text.tertiary)
            }
            .contentShape(Rectangle())
        }
        .zashiPlainButtonStyle()
    }

    @ViewBuilder
    private func optionRow(_ option: VoteOption, selected: VoteChoice?, isLocked: Bool) -> some View {
        let isSelected = selected == .option(option.index)
        Button {
            // Suppress option taps for submitted proposals: writing a new
            // draft here would make the review state diverge from what was
            // already accepted by the voting backend.
            guard !isLocked else { return }
            if isSelected {
                // Tap-to-toggle: re-tapping the active choice wipes the
                // draft so the user can leave a question unanswered without
                // having to settle on a different option.
                store.send(
                    .clearDraftVote(roundId: roundId, proposalId: proposalId)
                )
            } else {
                store.send(
                    .draftVoteSet(
                        roundId: roundId,
                        proposalId: proposalId,
                        choice: .option(option.index)
                    )
                )
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                if isSelected {
                    Circle()
                        .fill(Design.Checkboxes.onBg.color(colorScheme))
                        .frame(width: 20, height: 20)
                        .overlay {
                            Circle()
                                .fill(Design.Checkboxes.onFg.color(colorScheme))
                                .frame(width: 10, height: 10)
                        }
                } else {
                    Circle()
                        .fill(Design.Checkboxes.offBg.color(colorScheme))
                        .frame(width: 20, height: 20)
                        .overlay {
                            Circle()
                                .stroke(Design.Checkboxes.offStroke.color(colorScheme))
                                .frame(width: 20, height: 20)
                        }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label)
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        .tracking(-0.256)
                        .fixedSize(horizontal: false, vertical: true)

                    if let description = option.description?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !description.isEmpty {
                        Text(description)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                            .tracking(-0.224)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .zashiPlainButtonStyle()
        .disabled(isLocked)
    }

    private func selectedChoice(
        draftChoice: VoteChoice?,
        submittedChoice: VoteChoice?
    ) -> VoteChoice? {
        submittedChoice ?? draftChoice
    }
}
#endif
