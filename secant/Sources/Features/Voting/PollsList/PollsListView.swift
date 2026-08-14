#if VOTING_ENABLED
//
//  PollsListView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

/// Renders the list of voting rounds returned by the voting service.
///
/// Bound to the new `VotingCoordFlow` parent reducer. Card layout mirrors
/// the legacy view (`LegacyPollsListView`) one-to-one; the difference is
/// the data binding flows from `VotingCoordFlow.State` rather than the old
/// monolithic `Voting.State`.
struct PollsListView: View {
    @Environment(\.colorScheme)
    var colorScheme
    @State private var loadErrorSheetPresented = true
    @State private var dismissFlowAfterLoadErrorSheetDismiss = false

    /// Round id queued for entry while the "Unverified Poll" warning sheet
    /// is showing. Set when the user taps Enter Poll on a card from a
    /// non-default (custom) data source, then either consumed by
    /// "Proceed anyway" or dropped by "Go back".
    @State private var unverifiedWarningRoundId: String?

    let store: StoreOf<VotingCoordFlow>

    var body: some View {
        WithPerceptionTracking {
            let visiblePolls = self.visiblePolls
            ScrollView {
                VStack(spacing: 16) {
                    if store.pollsLoadError || visiblePolls.isEmpty {
                        PollsListSkeletonCard()
                    } else {
                        ForEach(sortedPolls(visiblePolls), id: \.id) { item in
                            pollCard(for: item)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                // macOS: cap the scroll CONTENT (not the ScrollView) so the full-width scroller reaches
                // the window edge while content stays in the 530 column. No flow cap above this screen.
                .macContentRowCap()
            }
            .padding(.vertical, 1)
            .applyScreenBackground(capped: false)
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiSectionRootBack { store.send(.dismissFlow) }
            .toolbar {
                ToolbarItem(placement: .zashiTrailing) {
                    Button {
                        store.send(.openConfigSettings)
                    } label: {
                        settingsButtonIcon()
                    }
#if !os(macOS)
                    .zashiPlainButtonStyle()
#endif
                    .accessibilityLabel(String(localizable: .coinVotePollsListChainConfigAccessibility))
                }
            }
            .votingSheet(
                isPresented: loadErrorBinding,
                title: String(localizable: .coinVotePollsListLoadErrorTitle),
                message: String(localizable: .coinVotePollsListLoadErrorMessage),
                primary: .init(title: String(localizable: .coinVoteCommonTryAgain), style: .primary) {
                    store.send(.retryLoadRounds)
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
            .votingSheet(
                isPresented: ineligibleSheetBinding,
                title: String(localizable: .coinVotePollsListInsufficientBalanceTitle),
                message: ineligibleSheetMessage,
                primary: .init(title: String(localizable: .coinVoteCommonGotIt), style: .primary) {
                    store.send(.dismissIneligibleSheet)
                },
                secondary: nil
            )
            .votingSheet(
                isPresented: walletSyncingSheetBinding,
                title: String(localizable: .coinVoteWalletSyncingTitle),
                message: String(localizable: .coinVoteWalletSyncingSubtitle),
                primary: .init(title: String(localizable: .coinVoteCommonGotIt), style: .primary) {
                    store.send(.dismissWalletSyncingSheet)
                },
                secondary: nil
            )
            .votingSheet(
                isPresented: unverifiedWarningBinding,
                title: String(localizable: .coinVotePollsListUnverifiedSheetTitle),
                message: String(localizable: .coinVotePollsListUnverifiedSheetMessage),
                primary: .init(title: String(localizable: .coinVoteCommonGoBack), style: .primary) {
                    unverifiedWarningRoundId = nil
                },
                secondary: .init(title: String(localizable: .coinVotePollsListUnverifiedSheetProceed), style: .secondary) {
                    if let roundId = unverifiedWarningRoundId {
                        unverifiedWarningRoundId = nil
                        store.send(.roundTapped(roundId))
                    }
                }
            )
        }
    }

    private var unverifiedWarningBinding: Binding<Bool> {
        Binding(
            get: { unverifiedWarningRoundId != nil },
            set: { newValue in
                if !newValue {
                    unverifiedWarningRoundId = nil
                }
            }
        )
    }

    private var ineligibleSheetBinding: Binding<Bool> {
        Binding(
            get: { store.ineligibleSheet != nil },
            set: { newValue in
                if !newValue {
                    store.send(.dismissIneligibleSheet)
                }
            }
        )
    }

    private var walletSyncingSheetBinding: Binding<Bool> {
        Binding(
            get: { store.walletSyncingSheetRoundId != nil },
            set: { newValue in
                if !newValue {
                    store.send(.dismissWalletSyncingSheet)
                }
            }
        )
    }

    /// Renders the body copy with the held balance, snapshot height, and
    /// minimum required balance for the active sheet. Falls back to an
    /// empty string when the sheet isn't presented so the modifier doesn't
    /// crash during the dismiss animation.
    private var ineligibleSheetMessage: String {
        guard let data = store.ineligibleSheet else { return "" }
        let formatHeight: (UInt64) -> String = { height in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            return formatter.string(from: NSNumber(value: height)) ?? String(height)
        }
        let formatZec: (UInt64) -> String = { zatoshi in
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 3
            formatter.maximumFractionDigits = 3
            formatter.usesGroupingSeparator = true
            let value = Zatoshi(Int64(zatoshi)).decimalValue.roundedZec
            return formatter.string(from: value) ?? "0.000"
        }
        return String(
            localizable: .coinVotePollsListInsufficientBalanceMessage(
                formatZec(data.heldZatoshi),
                formatHeight(data.snapshotHeight),
                formatZec(data.minimumZatoshi)
            )
        )
    }

    @ViewBuilder
    private func settingsButtonIcon() -> some View {
#if os(macOS)
        // macOS 26 sizes the glass capsule to the icon's WIDTH — a bare SF symbol is narrow → a TALL
        // capsule. Horizontal padding widens it to the same circular capsule as the back button.
        Image(systemName: "gearshape")
            .zashiToolbarIconPadding()
#else
        let icon = Asset.Assets.Icons.settings2.image
            .zImage(size: 20, style: Design.Btns.Ghost.fg)

        if #available(iOS 26.0, *) {
            icon
        } else {
            icon
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._md)
                        .fill(Design.Btns.Ghost.bg.color(colorScheme))
                }
        }
#endif
    }

    private var visiblePolls: [RoundListItem] {
        guard store.isOnDefaultConfig else {
            return store.allRounds
        }
        return store.allRounds.filter { store.zodlEndorsedRoundIds.contains($0.id) }
    }

    // MARK: - Load Error Sheet

    private var loadErrorBinding: Binding<Bool> {
        Binding(
            get: { loadErrorSheetPresented && store.pollsLoadError },
            // Drag-dismiss mirrors Go back: exit the voting flow rather than
            // leave the user on a stale/empty list with no action to take.
            set: { newValue in
                if newValue {
                    loadErrorSheetPresented = true
                } else if store.pollsLoadError {
                    dismissFlowAfterLoadErrorSheetDismiss = true
                    loadErrorSheetPresented = false
                }
            }
        )
    }

    // MARK: - Card

    private enum CardState {
        case active     // round is active and the user has not voted yet
        case voted      // round is active and the user has already confirmed
        case closed     // round is finalized or tallying — read-only results
    }

    private func cardState(for item: RoundListItem) -> CardState {
        switch item.session.status {
        case .active:
            return store.voteRecords[item.id] != nil ? .voted : .active
        case .tallying, .finalized, .unspecified:
            return .closed
        }
    }

    /// Clusters polls into Active → Voted → Closed. Active/Voted are sorted
    /// by `voteEndTime` ascending (closing-soonest first); Closed is sorted
    /// descending so the most recently closed round leads its cluster.
    private func sortedPolls(_ polls: [RoundListItem]) -> [RoundListItem] {
        func rank(_ state: CardState) -> Int {
            switch state {
            case .active: return 0
            case .voted:  return 1
            case .closed: return 2
            }
        }
        return polls.sorted { lhs, rhs in
            let lhsState = cardState(for: lhs)
            let rhsState = cardState(for: rhs)
            let lhsRank = rank(lhsState)
            let rhsRank = rank(rhsState)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhsState == .closed {
                return lhs.session.voteEndTime > rhs.session.voteEndTime
            }
            return lhs.session.voteEndTime < rhs.session.voteEndTime
        }
    }

    @ViewBuilder
    private func pollCard(for item: RoundListItem) -> some View {
        WithPerceptionTracking {
            pollCardBody(for: item)
        }
    }

    @ViewBuilder
    private func pollCardBody(for item: RoundListItem) -> some View {
        let state = cardState(for: item)

        VStack(alignment: .leading, spacing: 16) {
            // Top row: state pill + closes/closed date
            HStack(spacing: 0) {
                pollStatusPill(state)
                Spacer()
                Text(dateLabel(for: state, item: item))
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .tracking(-0.224)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    .tracking(-0.256)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !item.session.description.isEmpty {
                Text(item.session.description)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
                    .tracking(-0.224)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center, spacing: 12) {
                issuerTrustIndicator(for: item)

                Spacer(minLength: 12)

                ZashiButton(
                    cardActionTitle(for: state),
                    type: cardActionButtonType(for: state),
                    infinityWidth: false,
                    fontSize: 14,
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    minHeight: 40
                ) {
                    tapPollCard(for: item, state: state)
                }
                // Suppress the button while the in-flight eligibility check
                // resolves so a rapid double-tap doesn't kick off a second
                // pipeline. The check is local and fast, so no spinner is
                // needed — visually the button just briefly can't be tapped.
                .disabled(state == .active && store.checkingEligibilityRoundId == item.id)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(Design.Spacing._xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Surfaces.bgPrimary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
        )
        // Layered card shadow from Figma using shadow-sm = rgba(35, 31, 32, 0.04).
        // SwiftUI's shadow radius is roughly half of Figma's blur and spread
        // isn't supported, so the layer values are approximations.
        .shadow(color: Self.shadowSm, radius: 12, x: 0, y: 24)
        .shadow(color: Self.shadowSm, radius: 1.5, x: 0, y: 3)
        .shadow(color: Self.shadowSm, radius: 0.5, x: 0, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                pollCardAccessibilityLabel(
                    for: item,
                    state: state
                )
            )
        )
        .accessibilityHint(Text(pollCardAccessibilityHint(for: state)))
        .accessibilityAddTraits(.isButton)
    }

    private static let shadowSm = Color(red: 35.0 / 255.0, green: 31.0 / 255.0, blue: 32.0 / 255.0).opacity(0.04)

    @ViewBuilder
    private func issuerTrustIndicator(for item: RoundListItem) -> some View {
        if store.isOnDefaultConfig, store.zodlEndorsedRoundIds.contains(item.id) {
            zodlTrustIndicator()
        } else if !store.isOnDefaultConfig {
            unverifiedIssuerIndicator()
        }
    }

    private func zodlTrustIndicator() -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Design.Text.primary.color(colorScheme))
                    .frame(width: 24, height: 24)

                Asset.Assets.zashiLogo.image
                    .zImage(size: 16, color: Design.Surfaces.bgPrimary.color(colorScheme))
            }

            Text(localizable: .coinVotePollsListApprovedByZodl)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(localizable: .coinVotePollsListApprovedByZodl))
    }

    private func unverifiedIssuerIndicator() -> some View {
        let foregroundColor = Design.Text.tertiary.color(colorScheme)

        return HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 20, height: 20)

            Text(localizable: .coinVoteVotingViewUnverifiedPollTitle)
                .zFont(.medium, size: 14, color: foregroundColor)
                .tracking(-0.224)
                .lineLimit(1)
        }
        .foregroundStyle(foregroundColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(localizable: .coinVoteVotingViewUnverifiedPollTitle))
    }

    // MARK: - Status Pill

    @ViewBuilder
    private func pollStatusPill(_ state: CardState) -> some View {
        let style = pollStatusPillStyle(for: state)

        HStack(spacing: 4) {
            Image(systemName: style.iconSystemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(style.foregroundColor)

            Text(style.label)
                .zFont(.medium, size: 14, color: style.foregroundColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(style.backgroundColor)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(style.borderColor, lineWidth: 1)
        )
    }

    private func pollStatusPillStyle(for state: CardState) -> PollStatusPillStyle {
        switch state {
        case .active:
            return PollStatusPillStyle(
                iconSystemName: "clock",
                label: String(localizable: .coinVotePollsListStatusActive),
                foregroundColor: Design.Utility.SuccessGreen._700.color(colorScheme),
                backgroundColor: Design.Utility.SuccessGreen._50.color(colorScheme),
                borderColor: Design.Utility.SuccessGreen._200.color(colorScheme)
            )
        case .voted:
            return PollStatusPillStyle(
                iconSystemName: "checkmark",
                label: String(localizable: .coinVoteCommonVoted),
                foregroundColor: Design.Utility.SuccessGreen._700.color(colorScheme),
                backgroundColor: Design.Utility.SuccessGreen._50.color(colorScheme),
                borderColor: Design.Utility.SuccessGreen._200.color(colorScheme)
            )
        case .closed:
            return PollStatusPillStyle(
                iconSystemName: "clock",
                label: String(localizable: .coinVotePollsListStatusClosed),
                foregroundColor: Design.Utility.ErrorRed._700.color(colorScheme),
                backgroundColor: Design.Utility.ErrorRed._50.color(colorScheme),
                borderColor: Design.Utility.ErrorRed._200.color(colorScheme)
            )
        }
    }

    // MARK: - Date Label

    private func dateLabel(for state: CardState, item: RoundListItem) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let session = item.session
        let endFormatted = formatter.string(from: session.voteEndTime)

        switch state {
        case .active, .voted:
            return String(localizable: .coinVotePollsListDateCloses(endFormatted))
        case .closed:
            return String(localizable: .coinVotePollsListDateClosed(endFormatted))
        }
    }

    // MARK: - Card Action

    private func cardActionTitle(for state: CardState) -> String {
        switch state {
        case .active:
            return String(localizable: .coinVotePollsListEnterPoll)
        case .voted:
            return String(localizable: .coinVotePollsListReview)
        case .closed:
            return String(localizable: .coinVoteCommonViewResults)
        }
    }

    private func cardActionButtonType(for state: CardState) -> ZashiButton<EmptyView, EmptyView>.`Type` {
        switch state {
        case .active:
            return .primary
        case .voted, .closed:
            return .tertiary
        }
    }

    private func tapPollCard(for item: RoundListItem, state: CardState) {
        switch state {
        case .active:
            // On a custom (non-default) data source we can't confirm the
            // poll's legitimacy from the bundled Zodl endorsement set, so
            // warn the user before pushing them into the voting pipeline.
            if !store.isOnDefaultConfig {
                unverifiedWarningRoundId = item.id
                return
            }
            store.send(.roundTapped(item.id))
        case .voted:
            store.send(.viewMyVotesTapped(roundId: item.id))
        case .closed:
            store.send(.roundTapped(item.id))
        }
    }

    private func pollCardAccessibilityLabel(
        for item: RoundListItem,
        state: CardState
    ) -> String {
        let status = pollStatusPillStyle(for: state).label
        let date = dateLabel(for: state, item: item)
        return "\(item.title), \(status), \(date)"
    }

    private func pollCardAccessibilityHint(for state: CardState) -> String {
        cardActionTitle(for: state)
    }
}

private struct PollStatusPillStyle {
    let iconSystemName: String
    let label: String
    let foregroundColor: Color
    let backgroundColor: Color
    let borderColor: Color
}
#endif
