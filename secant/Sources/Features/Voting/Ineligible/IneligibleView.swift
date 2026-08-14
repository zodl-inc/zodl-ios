#if VOTING_ENABLED
//
//  IneligibleView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture

/// Shown when the wallet has no shielded notes at the round's snapshot
/// height (or balance below ballot divisor). The user can't vote in this
/// round; this is a terminal screen.
struct IneligibleView: View {
    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<VotingCoordFlow>
    let roundId: String

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(Design.Text.tertiary.color(colorScheme))

                    Text(localizable: .coinVoteIneligibleTitleNoVote)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .multilineTextAlignment(.center)

                    Text(localizable: .coinVoteIneligibleSnapshotBody)
                        .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 24)

                Spacer()

                ZashiButton(String(localizable: .coinVoteCommonGotIt)) {
                    store.send(.dismissFlow)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiBack()
        }
    }
}
#endif
