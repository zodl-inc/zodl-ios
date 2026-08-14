#if VOTING_ENABLED
//
//  NoRoundsView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture

/// Empty-state shown when the voting service returns zero rounds. Renders the
/// shimmering polls-list backdrop with a dimmed "No polls right now" sheet on
/// top. "Got it" hides the sheet but keeps the user inside the voting flow
/// so they can tap the toolbar cog and try a different data source.
struct NoRoundsView: View {
    let store: StoreOf<VotingCoordFlow>

    @State private var sheetPresented = true

    var body: some View {
        WithPerceptionTracking {
            VotingCoordFlowBackdrop(store: store)
                .zashiSheet(
                    isPresented: $sheetPresented,
                    horizontalPadding: VotingSheetContent.VisualStyle.unverifiedWarning.horizontalPadding
                ) {
                    VotingSheetContent(
                        iconSystemName: "exclamationmark.circle",
                        iconStyle: Design.Utility.ErrorRed._500,
                        title: String(localizable: .coinVotePollsListEmptyTitle),
                        message: String(localizable: .coinVotePollsListEmptyMessage),
                        primary: .init(
                            title: String(localizable: .coinVoteCommonGotIt),
                            style: .primary
                        ) {
                            // Just hide the sheet — keep the user on the
                            // backdrop so they can open Voting Settings via
                            // the toolbar cog.
                            sheetPresented = false
                        },
                        secondary: .init(
                            title: String(localizable: .coinVoteCommonRefresh),
                            style: .secondary
                        ) {
                            store.send(.retryLoadRounds)
                        },
                        visualStyle: .unverifiedWarning
                    )
                }
        }
    }
}

/// Shared shimmering backdrop used by the `.loading` and `.noRounds` root
/// screens. Renders the screen title + a single outlined skeleton card so the
/// chrome stays consistent across loading, empty, and error states. The
/// toolbar cog is always available so the user can change the data source
/// without first reaching the polls list.
struct VotingCoordFlowBackdrop: View {
    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<VotingCoordFlow>

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PollsListSkeletonCard()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .padding(.vertical, 1)
        .applyScreenBackground()
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
}

/// Shimmering placeholder card used while polls are loading and as the
/// dimmed backdrop behind the "no polls right now" sheet. Same shape and
/// stroke as a real poll card.
struct PollsListSkeletonCard: View {
    @Environment(\.colorScheme)
    var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            shimmerBar(width: 80, height: 12)
            VStack(alignment: .leading, spacing: 10) {
                shimmerBar(height: 12)
                shimmerBar(height: 12)
                shimmerBar(width: 240, height: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            shimmerBar(width: 60, height: 12)
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

    private func shimmerBar(width: CGFloat? = nil, height: CGFloat) -> some View {
        Color.gray.opacity(0.25)
            .frame(width: width, height: height)
            .shimmer(true)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
#endif
