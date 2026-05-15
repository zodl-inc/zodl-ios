import SwiftUI
import ComposableArchitecture

struct VotingErrorView: View {
    let store: StoreOf<Voting>
    let errorMessage: String

    var body: some View {
        WithPerceptionTracking {
            VotingBlockingBackdrop(store: store)
                .votingBlockingSheet(
                    isActive: { isCurrentErrorScreen },
                    onExit: { store.send(.dismissFlow) }
                ) { dismiss in
                    VotingSheetContent(
                        iconSystemName: "exclamationmark.circle",
                        iconStyle: Design.Utility.ErrorRed._500,
                        title: String(localizable: .coinVoteErrorTitle),
                        message: errorMessage,
                        primary: .init(title: String(localizable: .coinVoteCommonRetry), style: .primary) {
                            store.send(.initialize)
                        },
                        secondary: .init(title: String(localizable: .coinVoteCommonDismiss), style: .secondary) {
                            dismiss()
                        }
                    )
                }
        }
    }

    private var isCurrentErrorScreen: Bool {
        if case .error = store.currentScreen { return true }
        return false
    }
}

struct VotingConfigErrorView: View {
    let store: StoreOf<Voting>
    let errorMessage: String

    var body: some View {
        WithPerceptionTracking {
            VotingBlockingBackdrop(store: store)
                .votingBlockingSheet(
                    isActive: { isCurrentErrorScreen },
                    onExit: { store.send(.dismissFlow) }
                ) { dismiss in
                    VotingSheetContent(
                        iconSystemName: "arrow.up.circle",
                        iconStyle: Design.Utility.ErrorRed._500,
                        title: String(localizable: .coinVoteConfigErrorTitle),
                        message: errorMessage,
                        primary: .init(title: String(localizable: .coinVoteCommonDismiss), style: .primary) {
                            dismiss()
                        },
                        secondary: nil
                    )
                }
        }
    }

    private var isCurrentErrorScreen: Bool {
        if case .configError = store.currentScreen { return true }
        return false
    }
}
