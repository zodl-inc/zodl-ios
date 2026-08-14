#if VOTING_ENABLED
//
//  VotingErrorView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture

/// Blocking error screen — used for both `.error` (generic init failure)
/// and `.configError` (voting service config unavailable/decode failed)
/// root states. Config errors can optionally offer an in-flow recovery
/// action before falling back to dismiss.
struct VotingErrorView: View {
    struct RecoveryAction {
        let title: String
        let action: VotingCoordFlow.Action
    }

    @Environment(\.colorScheme) var colorScheme

    let store: StoreOf<VotingCoordFlow>
    let title: String
    let message: String
    let recoveryAction: RecoveryAction?

    init(
        store: StoreOf<VotingCoordFlow>,
        title: String,
        message: String,
        recoveryAction: RecoveryAction? = nil
    ) {
        self.store = store
        self.title = title
        self.message = message
        self.recoveryAction = recoveryAction
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(Design.Utility.ErrorRed._500.color(colorScheme))

                    Text(title)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .multilineTextAlignment(.center)

                    Text(message)
                        .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 12) {
                    if let recoveryAction {
                        ZashiButton(recoveryAction.title, minHeight: 48) {
                            store.send(recoveryAction.action)
                        }
                    }

                    ZashiButton(
                        String(localizable: .coinVoteCommonGotIt),
                        type: recoveryAction == nil ? .primary : .secondary,
                        minHeight: 48
                    ) {
                        store.send(.dismissFlow)
                    }
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
