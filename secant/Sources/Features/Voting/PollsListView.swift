import SwiftUI
import ComposableArchitecture

struct PollsListView: View {
    @Environment(\.colorScheme)
    var colorScheme
    @State private var loadErrorSheetPresented = true
    @State private var dismissFlowAfterLoadErrorSheetDismiss = false

    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            let visiblePolls = self.visiblePolls
            ScrollView {
                VStack(spacing: 16) {
                    if store.pollsLoadError || visiblePolls.isEmpty {
                        PollsListSkeletonCard()
                    } else {
                        // Newest polls first. allRounds is stored ascending so the
                        // assigned round numbers stay sane (round 1 = oldest), but
                        // the list shows the latest at the top.
                        ForEach(Array(visiblePolls.reversed()), id: \.id) { item in
                            pollCard(for: item)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiBack { store.send(.dismissFlow) }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        store.send(.openConfigSettings)
                    } label: {
                        settingsButtonIcon()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Voting chain config")
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
        }
    }

    @ViewBuilder
    private func settingsButtonIcon() -> some View {
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
    }

    private var visiblePolls: [Voting.State.RoundListItem] {
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

    private func cardState(for item: Voting.State.RoundListItem) -> CardState {
        switch item.session.status {
        case .active:
            return store.voteRecords[item.id] != nil ? .voted : .active
        case .tallying, .finalized, .unspecified:
            return .closed
        }
    }

    @ViewBuilder
    private func pollCard(for item: Voting.State.RoundListItem) -> some View {
        let state = cardState(for: item)

        VStack(alignment: .leading, spacing: 16) {
            // Top row: state pill + closes/closed date
            HStack(spacing: 0) {
                pollStatusPill(state)
                Spacer()
                Text(dateLabel(for: state, item: item))
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .tracking(-0.224) // -1.6% × 14pt
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    .tracking(-0.256) // -1.6% × 16pt
                    .fixedSize(horizontal: false, vertical: true)
            }

            // "Poll Description" label + description
            if !item.session.description.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localizable: .coinVoteCommonPollDescription)
                        .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        .tracking(-0.224)

                    Text(item.session.description)
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                        .tracking(-0.224)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    private func issuerTrustIndicator(for item: Voting.State.RoundListItem) -> some View {
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

            Text("Approved by Zodl")
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Approved by Zodl"))
    }

    private func unverifiedIssuerIndicator() -> some View {
        let foregroundColor = Design.Text.tertiary.color(colorScheme)

        return HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 20, height: 20)

            Text("Unverified Poll")
                .zFont(.medium, size: 14, color: foregroundColor)
                .tracking(-0.224)
                .lineLimit(1)
        }
        .foregroundStyle(foregroundColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Unverified Poll"))
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

    private func dateLabel(for state: CardState, item: Voting.State.RoundListItem) -> String {
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
            return String(localized: "Review")
        case .closed:
            return String(localized: "View Results")
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

    private func tapPollCard(for item: Voting.State.RoundListItem, state: CardState) {
        switch state {
        case .active:
            store.send(.roundTapped(item.id))
        case .voted:
            store.send(.viewMyVotesTapped(roundId: item.id))
        case .closed:
            store.send(.roundTapped(item.id))
        }
    }

    private func pollCardAccessibilityLabel(
        for item: Voting.State.RoundListItem,
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

struct PollsListSkeletonCard: View {
    @Environment(\.colorScheme)
    var colorScheme

    var body: some View {
        let barFill = Design.Surfaces.bgTertiary.color(colorScheme)
        return VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 4).fill(barFill).frame(width: 80, height: 12)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(barFill).frame(height: 12)
                RoundedRectangle(cornerRadius: 4).fill(barFill).frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(barFill)
                    .frame(width: 240, height: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            RoundedRectangle(cornerRadius: 4).fill(barFill).frame(width: 60, height: 12)
        }
        .padding(Design.Spacing._xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Surfaces.bgPrimary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
    }
}

private struct PollStatusPillStyle {
    let iconSystemName: String
    let label: String
    let foregroundColor: Color
    let backgroundColor: Color
    let borderColor: Color
}
