import SwiftUI
import ComposableArchitecture

struct VotingView: View {
    let store: StoreOf<Voting>

    public init(store: StoreOf<Voting>) {
        self.store = store
    }

    public var body: some View {
        WithPerceptionTracking {
            let screen = store.screenStack.last ?? .pollsList
            screenView(for: screen)
                .id(screenId(screen))
                .animation(.easeInOut(duration: 0.22), value: screenId(screen))
                .animation(.easeInOut(duration: 0.3), value: store.selectedProposal?.id)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            store.send(.initialize)
            store.send(.warmProvingCaches)
        }
        .sheet(
            store: store.scope(state: \.$keystoneScan, action: \.keystoneScan)
        ) { scanStore in
            ScanView(store: scanStore, popoverRatio: 1.075)
        }
        .votingSheet(
            isPresented: pollClosedBinding,
            title: String(localizable: .coinVoteVotingViewPollClosedTitle),
            message: String(localizable: .coinVoteVotingViewPollClosedMessage),
            primary: .init(title: String(localizable: .coinVoteCommonViewResults), style: .primary) {
                store.send(.viewPollClosedResults)
            },
            secondary: .init(title: String(localizable: .coinVoteCommonClose), style: .secondary) {
                store.send(.dismissPollClosedSheet)
            },
            visualStyle: .unverifiedWarning
        )
        .votingSheet(
            isPresented: unverifiedPollWarningBinding,
            iconSystemName: "exclamationmark.triangle",
            title: String(localized: "Unverified Poll"),
            message: String(
                localized: "This poll hasn't been verified. We can't confirm its legitimacy or how results will be used."
            ),
            primary: .init(title: String(localized: "Go back"), style: .primary) {
                store.send(.unverifiedPollWarningGoBackTapped)
            },
            secondary: .init(title: String(localized: "Proceed anyway"), style: .secondary) {
                store.send(.unverifiedPollWarningProceedTapped)
            },
            visualStyle: .unverifiedWarning,
            onDismiss: {
                if store.pendingUnverifiedRoundTapId != nil {
                    store.send(.openPendingUnverifiedRound)
                }
            }
        )
    }

    private var pollClosedBinding: Binding<Bool> {
        Binding(
            get: { store.showPollClosedSheet },
            // Guard against SwiftUI re-firing this setter after a *programmatic*
            // dismiss (e.g. `viewPollClosedResults` flips `showPollClosedSheet`
            // to false and switches the screen). On iOS 16+ the sheet's binding
            // gets a `set(false)` callback once the dismiss animation settles —
            // without this guard, that spurious callback would send
            // `.dismissPollClosedSheet` → `.backToRoundsList` and pop the user
            // back to the polls list right after we just routed them to
            // results/tallying. Only the *interactive* drag-dismiss path runs
            // with the state still true at the moment of the setter call.
            set: { newValue in
                if !newValue && store.showPollClosedSheet {
                    store.send(.dismissPollClosedSheet)
                }
            }
        )
    }

    private var unverifiedPollWarningBinding: Binding<Bool> {
        Binding(
            get: { store.showUnverifiedPollWarning },
            set: { newValue in
                if !newValue && store.showUnverifiedPollWarning {
                    store.send(.unverifiedPollWarningGoBackTapped)
                }
            }
        )
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func screenId(_ screen: Voting.State.Screen) -> String {
        switch screen {
        case .howToVote: return "howToVote"
        case .loading: return "loading"
        case .noRounds: return "noRounds"
        case .pollsList: return "pollsList"
        case .delegationSigning: return "delegationSigning"
        case .proposalList: return "proposalList"
        case .proposalDetail(let id): return "detail-\(id)"
        case .ineligible: return "ineligible"
        case .tallying: return "tallying"
        case .results: return "results"
        case .reviewVotes: return "reviewVotes"
        case .confirmSubmission: return "confirmSubmission"
        case .error: return "error"
        case .configError: return "configError"
        case .configSettings: return "configSettings"
        case .walletSyncing: return "walletSyncing"
        }
    }

    @ViewBuilder
    private func screenView( // swiftlint:disable:this cyclomatic_complexity
        for screen: Voting.State.Screen
    ) -> some View {
        switch screen {
        case .howToVote:
            HowToVoteView(store: store)
        case .loading:
            ProgressView()
        case .noRounds:
            NoRoundsView(store: store)
        case .pollsList:
            PollsListView(store: store)
        case .delegationSigning:
            DelegationSigningView(store: store)
        case .proposalList:
            ProposalListView(store: store, mode: .voting)
                .transition(.opacity)
        case .reviewVotes:
            ProposalListView(store: store, mode: .review)
        case .confirmSubmission:
            ConfirmSubmissionView(store: store)
        case .proposalDetail:
            if let proposal = store.selectedProposal {
                ProposalDetailView(store: store, proposal: proposal)
                    .id(proposal.id)
                    .transition(.push(from: .trailing))
            }
        case .ineligible:
            IneligibleView(store: store)
        case .tallying:
            TallyingView(store: store)
        case .results:
            ResultsView(store: store)
        case .error(let message):
            VotingErrorView(store: store, errorMessage: message)
        case .configError(let message):
            VotingConfigErrorView(store: store, errorMessage: message)
        case .configSettings:
            if let configSettingsStore = store.scope(state: \.configSettings, action: \.configSettings) {
                VotingConfigSettingsView(store: configSettingsStore)
            }
        case .walletSyncing:
            WalletSyncingView(store: store)
        }
    }
}

struct VotingBlockingBackdrop: View {
    let store: StoreOf<Voting>

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PollsListSkeletonCard()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .applyScreenBackground()
        .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
        .zashiBack { store.send(.dismissFlow) }
    }
}

// MARK: - No Rounds

struct NoRoundsView: View {
    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            VotingBlockingBackdrop(store: store)
                .votingBlockingSheet(
                    isActive: { store.currentScreen == .noRounds },
                    visualStyle: .unverifiedWarning,
                    onExit: { store.send(.dismissFlow) }
                ) { dismiss in
                    VotingSheetContent(
                        iconSystemName: "exclamationmark.circle",
                        iconStyle: Design.Utility.ErrorRed._500,
                        title: String(localizable: .coinVotePollsListEmptyTitle),
                        message: String(localizable: .coinVotePollsListEmptyMessage),
                        primary: .init(title: String(localizable: .coinVoteCommonGotIt), style: .primary) {
                            dismiss()
                        },
                        secondary: .init(title: String(localizable: .coinVoteCommonRefresh), style: .secondary) {
                            store.send(.retryLoadRounds)
                        },
                        visualStyle: .unverifiedWarning
                    )
                }
        }
    }
}

// MARK: - Placeholders

extension Voting.State {
    static let initial = Voting.State()
}

extension StoreOf<Voting> {
    static let placeholder = StoreOf<Voting>(
        initialState: .initial
    ) {
        Voting()
    }
}

#Preview {
    NavigationStack {
        VotingView(store: .placeholder)
    }
}
