import SwiftUI
import ComposableArchitecture

struct WalletSyncingView: View {
    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            VotingBlockingBackdrop(store: store)
                .votingBlockingSheet(
                    isActive: { store.currentScreen == .walletSyncing },
                    visualStyle: .unverifiedWarning,
                    onExit: { store.send(.dismissFlow) }
                ) { dismiss in
                    VotingSheetContent(
                        iconSystemName: "exclamationmark.circle",
                        iconStyle: Design.Utility.ErrorRed._500,
                        title: String(localizable: .coinVoteWalletSyncingTitle),
                        message: String(localizable: .coinVoteWalletSyncingSubtitle),
                        primary: .init(title: String(localizable: .coinVoteCommonGotIt), style: .primary) {
                            dismiss()
                        },
                        secondary: nil,
                        visualStyle: .unverifiedWarning
                    )
                }
        }
    }
}
