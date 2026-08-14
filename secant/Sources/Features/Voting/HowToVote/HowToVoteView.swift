#if VOTING_ENABLED
//
//  HowToVoteView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture

/// First-time intro shown to users who have not yet seen the Coinholder
/// Polling onboarding. Renders the same 2-step layout for Zodl and Keystone
/// accounts; only the brand icon + title copy differ.
struct HowToVoteView: View {
    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<VotingCoordFlow>

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        iconRow
                            .padding(.top, 24)
                            .padding(.bottom, 24)

                        Text(titleCopy)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .tracking(-0.384)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 8)

                        Text(subtitleCopy)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                            .tracking(-0.224)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        stepRow(
                            number: 1,
                            title: String(localizable: .coinVoteHowToVoteStepVotingTitle),
                            body: String(localizable: .coinVoteHowToVoteStepVotingBody)
                        )
                        .padding(.bottom, 16)

                        stepRow(
                            number: 2,
                            title: String(localizable: .coinVoteHowToVoteStepAuthorizeTitle),
                            body: String(localizable: .coinVoteHowToVoteStepAuthorizeBody)
                        )
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 1)

                snapshotNote
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                ZashiButton(String(localizable: .coinVoteCommonContinue)) {
                    store.send(.howToVoteContinueTapped)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            // macOS: this intro is taller than the fixed pane, so without scroll-within-pane the
            // centered content renders ABOVE the window and grows the window/sidebar. `scrollable: true`
            // clamps it to the pane and scrolls instead (macScrollableContent — names this "voting intro").
            // No-op on iOS (Rule #11), where the inner ScrollView + pinned CTA already handle it.
            .applyScreenBackground(scrollable: true)
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiSectionRootBack { store.send(.dismissFlow) }
        }
    }

    // MARK: - Top icon row

    @ViewBuilder
    private var iconRow: some View {
        HStack(spacing: -8) {
            ZStack {
                Circle()
                    .fill(Design.Text.primary.color(colorScheme))
                    .frame(width: 48, height: 48)

                brandIcon
            }

            ZStack {
                Circle()
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .frame(width: 48, height: 48)

                Image(systemName: "hand.thumbsup.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Design.Text.primary.color(colorScheme))
            }
        }
    }

    @ViewBuilder
    private var brandIcon: some View {
        if store.isKeystoneUser {
            Asset.Assets.Partners.keystoneLogo.image
                .resizable()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
        } else {
            Asset.Assets.zashiLogo.image
                .zImage(size: 22, color: Design.Surfaces.bgPrimary.color(colorScheme))
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private func stepRow(number: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Design.Text.primary.color(colorScheme))
                    .frame(width: 24, height: 24)

                Text("\(number)")
                    .zFont(.semiBold, size: 12, color: Design.Surfaces.bgPrimary.color(colorScheme))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    .tracking(-0.256)
                    .fixedSize(horizontal: false, vertical: true)

                Text(body)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .tracking(-0.224)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Bottom info note

    @ViewBuilder
    private var snapshotNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Design.Text.tertiary.color(colorScheme))
                .padding(.top, 1)

            Text(localizable: .coinVoteHowToVoteInfoCard)
                .zFont(.medium, size: 13, style: Design.Text.tertiary)
                .tracking(-0.208)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Variant copy

    private var titleCopy: String {
        store.isKeystoneUser
            ? String(localizable: .coinVoteHowToVoteTitleKeystone)
            : String(localizable: .coinVoteHowToVoteTitleZodl)
    }

    private var subtitleCopy: String {
        String(localizable: .coinVoteHowToVoteSubtitle)
    }
}
#endif
