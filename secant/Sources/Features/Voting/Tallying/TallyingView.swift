#if VOTING_ENABLED
//
//  TallyingView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture

/// Tallying-phase view. Voting has closed and the helper servers are
/// computing the final tally. Shows the round title + a "tallying"
/// message; once status flips to finalized, the parent transitions to
/// Results.
struct TallyingView: View {
    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<VotingCoordFlow>
    let roundId: String

    var body: some View {
        WithPerceptionTracking {
            let item = store.allRounds.first { $0.id == roundId }

            VStack(alignment: .leading, spacing: 16) {
                Text(item?.title ?? "")
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .tracking(-0.384)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    ZashiSpinner()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(localizable: .coinVoteTallyingTitleInProgress)
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        Text(localizable: .coinVoteTallyingBodyInProgress)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
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

                ZashiButton(
                    String(localizable: .coinVoteCommonRefresh),
                    type: .tertiary
                ) {
                    store.send(.refreshActiveRoundsList)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiBack()
            .task {
                // While the user sits on this screen, re-poll the rounds
                // list every 30s so a status flip from tallying → finalized
                // can swap them onto ResultsView automatically. The task
                // is cancelled when the view disappears.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    store.send(.refreshActiveRoundsList)
                }
            }
        }
    }
}
#endif
