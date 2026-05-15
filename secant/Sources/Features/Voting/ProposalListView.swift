import SwiftUI
import Combine
import ComposableArchitecture

struct ProposalListView: View {
    enum Mode { case voting, review }

    @Environment(\.colorScheme)
    var colorScheme
    @State private var now = Date()
    @State private var showDescriptionSheet = false

    let store: StoreOf<Voting>
    var mode: Mode = .voting

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                if store.activeSession == nil {
                    noActiveRoundCard()
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    proposalScrollView()
                }
            }
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiBack { store.send(.backToList) }
            .overlay(alignment: .bottom) {
                bottomCTAOverlay()
            }
            .onReceive(timer) { self.now = $0 }
            .onAppear { store.send(.governanceTabAppeared) }
            .onDisappear { store.send(.governanceTabDisappeared) }
            .sheet(isPresented: $showDescriptionSheet) {
                pollDescriptionSheet()
            }
            .sheet(isPresented: Binding(
                get: { store.showShareInfoSheet },
                set: { newValue in
                    if !newValue { store.send(.hideShareInfo) }
                }
            )) {
                ShareInfoSheet(
                    allConfirmed: {
                        guard let pid = store.shareInfoProposalId,
                              let p = store.shareDelegationProgressByProposal[pid] else { return store.allSharesConfirmed }
                        return p.confirmed >= p.total && p.total > 0
                    }(),
                    estimatedCompletion: store.shareInfoEstimatedCompletion,
                    roundDuration: store.activeSession.map {
                        $0.voteEndTime.timeIntervalSince($0.ceremonyStart)
                    } ?? 7200
                )
            }
        }
    }

    // MARK: - Scroll View

    @ViewBuilder
    private func proposalScrollView() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch mode {
                    case .voting:
                        overviewHeader()
                    case .review:
                        reviewHeader()
                    }

                    VStack(spacing: mode == .review ? 8 : 16) {
                        ForEach(store.votingRound.proposals) { proposal in
                            proposalCard(proposal)
                                .id(proposal.id)
                        }
                    }
                }
                .padding(.horizontal, 24)
                // Aligns with the 12pt app-bar gap per design.
                // The padding lives at the ScrollView content level because
                // SwiftUI tends to absorb padding on the first child of a
                // VStack-inside-ScrollView via safe-area insets.
                .padding(.top, 12)
                // Bottom inset large enough to scroll the last proposal card
                // out from under the floating CTA. Approx button height (~50)
                // + outer padding (~16) + breathing room.
                .padding(.bottom, 96)
            }
            .onAppear {
                if let id = store.activeProposalId {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: store.activeProposalId) { newId in
                if let newId {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Review Header

    @ViewBuilder
    private func reviewHeader() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizable: .coinVoteProposalListReviewTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .tracking(-0.384)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .coinVoteProposalListReviewSubtitle)
                .zFont(size: 14, style: Design.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Overview Header

    @ViewBuilder
    private func overviewHeader() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title row: round title (left) + #snapshotHeight (right).
            // Negative top padding nudges the title up to absorb Inter's
            // natural line-leading at 20pt and tighten the gap from the
            // COINHOLDER POLLING navbar title.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(store.votingRound.title)
                    .zFont(.semiBold, size: 20, style: Design.Text.primary)
                    .tracking(-0.32) // -1.6% × 20pt
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let session = store.activeSession {
                    Text("#\(formattedSnapshotHeight(session.snapshotHeight))")
                        .zFont(.medium, size: 20, style: Design.Text.primary)
                        .tracking(-0.32)
                        .fixedSize()
                }
            }

            // Meta line: Ends X · Voting Power Y · N days left
            metaLineView()
                .padding(.horizontal, -24) // bleed to screen edges

            // Description — always collapsed to one line with "View more"
            // opening a bottom sheet with the full poll description.
            if !store.votingRound.description.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(store.votingRound.description)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    viewMoreButton()
                }
            }
        }
    }

    @ViewBuilder
    private func viewMoreButton() -> some View {
        Button {
            showDescriptionSheet = true
        } label: {
            HStack(spacing: 4) {
                Text(localizable: .coinVoteProposalListViewMore)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
                    .tracking(-0.224)
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Design.Text.primary.color(colorScheme))
            }
            .frame(height: 20)
        }
    }

    // MARK: - Poll Description Sheet

    @ViewBuilder
    private func pollDescriptionSheet() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: close button + centered title
            HStack {
                Button { showDescriptionSheet = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Design.Text.tertiary.color(colorScheme))
                        .frame(width: 48, height: 48)
                        .background(Design.Surfaces.bgTertiary.color(colorScheme))
                        .clipShape(Circle())
                }
                Spacer()
                Text(localizable: .coinVoteCommonPollDescription)
                    .zFont(.semiBold, size: 14, style: Design.Text.primary)
                    .textCase(.uppercase)
                Spacer()
                Color.clear.frame(width: 48, height: 48)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(store.votingRound.title)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)

                    Text(store.votingRound.description)
                        .zFont(size: 15, style: Design.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    if store.votingRound.discussionURL != nil {
                        // Forum link
                        forumDiscussionsLink()
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func forumDiscussionsLink() -> some View {
        let content = HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                    .frame(width: 40, height: 40)
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Design.Text.primary.color(colorScheme))
            }

            Text(localizable: .coinVoteProposalListViewForumDiscussions)
                .zFont(.medium, size: 16, style: Design.Text.primary)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Design.Text.tertiary.color(colorScheme))
        }
        .frame(height: 40)

        if let url = store.votingRound.discussionURL {
            Link(destination: url) { content }
        }
    }

    // MARK: - Meta Line

    @ViewBuilder
    private func metaLineView() -> some View {
        let parts = metaParts
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Spacer(minLength: 2)
                    Text("·")
                        .zFont(.medium, size: 12, style: Design.Text.tertiary)
                    Spacer(minLength: 2)
                }
                Text(part)
                    .zFont(.medium, size: 12, style: Design.Text.tertiary)
                    .tracking(-0.072)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 24)
    }

    private var metaParts: [String] {
        let dateString: String
        let votingPowerString: String
        let timeLeftString: String

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy"

        if let record = store.voteRecord {
            dateString = String(localizable: .coinVoteCommonVotedDate(dateFormatter.string(from: record.votedAt)))
        } else if let session = store.activeSession {
            dateString = String(localizable: .coinVoteCommonEndsDate(dateFormatter.string(from: session.voteEndTime)))
        } else {
            dateString = ""
        }

        votingPowerString = String(localizable: .coinVoteCommonVotingPower(store.votingWeightZECString))
        timeLeftString = timeLeftLabel

        return [dateString, votingPowerString, timeLeftString]
            .filter { !$0.isEmpty }
    }

    private var timeLeftLabel: String {
        guard let session = store.activeSession else { return "" }
        let remaining = session.voteEndTime.timeIntervalSince(now)
        guard remaining > 0 else { return String(localizable: .coinVoteProposalListTimeLeftEnded) }

        let days = Int(remaining) / 86_400
        let hours = (Int(remaining) % 86_400) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        // Days uses long form to match the design ("4 days left").
        // Hours/minutes use compact forms so the meta line doesn't wrap when
        // the round is in its final stretch.
        if days > 0 {
            if days == 1 {
                return String(localizable: .coinVoteProposalListTimeLeftDay(String(days)))
            }
            return String(localizable: .coinVoteProposalListTimeLeftDays(String(days)))
        } else if hours > 0 {
            return String(localizable: .coinVoteProposalListTimeLeftHours(String(hours)))
        } else {
            return String(localizable: .coinVoteProposalListTimeLeftMinutes(String(minutes)))
        }
    }

    /// Formats the snapshot block height with comma grouping regardless of the
    /// device locale, so it always reads "#2,800,000" rather than "#2 800 000"
    /// on locales with non-breaking-space groupers.
    private func formattedSnapshotHeight(_ height: UInt64) -> String {
        height.formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic))
    }

    // MARK: - No Active Round

    @ViewBuilder
    private func noActiveRoundCard() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 28))
                .foregroundStyle(Design.Text.tertiary.color(colorScheme))

            Text(localizable: .coinVoteProposalListNoActiveRoundTitle)
                .zFont(.semiBold, size: 18, style: Design.Text.primary)

            Text(localizable: .coinVoteProposalListNoActiveRoundMessage)
                .zFont(.regular, size: 13, style: Design.Text.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Design.Surfaces.bgPrimary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
        )
    }
}

// MARK: - Card

extension ProposalListView {
    @ViewBuilder
    func proposalCard(_ proposal: VotingProposal) -> some View {
        let choice = store.effectiveChoices[proposal.id]

        VStack(alignment: .leading, spacing: 12) {
            if proposal.displayZipNumber != nil || choice != nil {
                HStack {
                    if let zipNumber = proposal.displayZipNumber {
                        ZIPBadge(zipNumber: zipNumber)
                    }

                    Spacer()

                    if let choice {
                        let info = voteBadgeInfo(for: choice, proposal: proposal, colorScheme: colorScheme)
                        VoteBadgePill(info: info)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.title)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    .tracking(-0.256)
                    .fixedSize(horizontal: false, vertical: true)

                if !proposal.description.isEmpty {
                    Text(proposal.description)
                        .zFont(size: 12, style: Design.Text.tertiary)
                        .tracking(-0.072)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .shadow(color: Self.shadowSm, radius: 24, x: 0, y: 24)
        .shadow(color: Self.shadowSm, radius: 1.5, x: 0, y: 3)
        .shadow(color: Self.shadowSm, radius: 0.5, x: 0, y: 1)
        .contentShape(Rectangle())
        .onTapGesture {
            store.send(.proposalTapped(proposal.id))
        }
    }

    private static let shadowSm = Color(red: 35.0 / 255.0, green: 31.0 / 255.0, blue: 32.0 / 255.0).opacity(0.04)
}

// MARK: - Bottom CTA

extension ProposalListView {
    @ViewBuilder
    func bottomCTAOverlay() -> some View {
        if store.voteRecord == nil {
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Design.Surfaces.bgPrimary.color(colorScheme).opacity(0),
                        Design.Surfaces.bgPrimary.color(colorScheme)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 64)
                .allowsHitTesting(false)

                ctaButton()
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    func bottomCTA() -> some View {
        if store.voteRecord != nil {
            // Votes already submitted — no CTA
            EmptyView()
        } else {
            ctaButton()
        }
    }

    @ViewBuilder
    private func ctaButton() -> some View {
        let spec = ctaButtonSpec()
        ZashiButton(spec.label) {
            spec.action()
        }
        .disabled(spec.disabled)
    }

    private struct CTAButtonSpec {
        let label: String
        let action: () -> Void
        let disabled: Bool
    }

    private func ctaButtonSpec() -> CTAButtonSpec {
        switch mode {
        case .review:
            return CTAButtonSpec(
                label: String(localizable: .coinVoteProposalListCtaConfirmSubmit),
                action: { store.send(.navigateToConfirmation) },
                disabled: false
            )

        case .voting:
            let proposals = store.votingRound.proposals
            let drafts = store.draftVotes
            let draftCount = drafts.count
            let total = proposals.count
            let firstUndrafted = proposals.first { drafts[$0.id] == nil }

            if total == 0 {
                return CTAButtonSpec(label: String(localizable: .coinVoteProposalListCtaStartVoting), action: {}, disabled: true)
            }

            if draftCount == 0 {
                let action: () -> Void = firstUndrafted.map { target in
                    { store.send(.proposalTapped(target.id)) }
                } ?? {}
                return CTAButtonSpec(
                    label: String(localizable: .coinVoteProposalListCtaStartVoting),
                    action: action,
                    disabled: false
                )
            }

            if draftCount < total {
                let action: () -> Void = firstUndrafted.map { target in
                    { store.send(.proposalTapped(target.id)) }
                } ?? {}
                return CTAButtonSpec(
                    label: String(localizable: .coinVoteProposalListCtaContinueVoting),
                    action: action,
                    disabled: false
                )
            }

            return CTAButtonSpec(
                label: String(localizable: .coinVoteProposalListCtaConfirmSubmit),
                action: { store.send(.navigateToConfirmation) },
                disabled: false
            )
        }
    }
}
