#if VOTING_ENABLED
//
//  WalletSyncingView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture

/// Shown while the wallet's contiguous-from-birthday scan height is below
/// the active round's snapshot. The coordinator polls every 2 s and
/// auto-resumes the pipeline once caught up.
struct WalletSyncingView: View {
    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<VotingCoordFlow>

    var body: some View {
        WithPerceptionTracking {
            let scanned = store.walletScannedHeight
            let snapshot = store.allRounds
                .first { $0.id == store.pendingPipelineRoundId }?
                .session.snapshotHeight ?? 0
            let progress = snapshot > 0
                ? Double(min(scanned, snapshot)) / Double(snapshot)
                : 0

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 16) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 24)

                    Text(localizable: .coinVoteWalletSyncingCatchingUp)
                        .zFont(.semiBold, size: 18, style: Design.Text.primary)
                    Text("\(scanned) / \(snapshot)")
                        .zFont(.medium, size: 14, style: Design.Text.tertiary)
                }

                Spacer()

                ZashiButton(String(localizable: .coinVoteCommonClose), type: .tertiary) {
                    store.send(.dismissFlow)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiSectionRootBack { store.send(.dismissFlow) }
        }
    }
}
#endif
