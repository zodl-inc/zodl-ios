#if VOTING_ENABLED
//
//  VotingCoordFlowView.swift
//  Zashi
//

import SwiftUI
import Combine
import ComposableArchitecture

struct VotingCoordFlowView: View {
    @PlatformBindable var store: StoreOf<VotingCoordFlow>

    init(store: StoreOf<VotingCoordFlow>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                rootContent
                    .onAppear {
                        store.send(.onAppear)
                        store.send(.warmProvingCaches)
                    }
            } destination: { destinationStore in
                // NavigationStack's destination closure is escaping; it needs
                // its own WithPerceptionTracking so reads from
                // `destinationStore` and the captured parent `store` register
                // with TCA's observation machinery.
                WithPerceptionTracking {
                    switch destinationStore.case {
                    case let .proposalList(scoped):
                        ProposalListView(
                            store: store,
                            roundId: scoped.roundId,
                            mode: .voting
                        )
                    case let .proposalDetail(scoped):
                        ProposalDetailView(
                            store: store,
                            roundId: scoped.roundId,
                            proposalId: scoped.proposalId,
                            mode: scoped.mode
                        )
                    case let .reviewVotes(scoped):
                        ProposalListView(
                            store: store,
                            roundId: scoped.roundId,
                            mode: .review
                        )
                    case let .reviewDrafts(scoped):
                        ProposalListView(
                            store: store,
                            roundId: scoped.roundId,
                            mode: .reviewDrafts
                        )
                    case let .confirmSubmission(scoped):
                        ConfirmSubmissionView(store: store, roundId: scoped.roundId)
                    case let .delegationSigning(scoped):
                        DelegationSigningView(store: store, roundId: scoped.roundId)
                    case let .tallying(scoped):
                        TallyingView(store: store, roundId: scoped.roundId)
                    case let .results(scoped):
                        ResultsView(store: store, roundId: scoped.roundId)
                    case let .ineligible(scoped):
                        IneligibleView(store: store, roundId: scoped.roundId)
                    case let .configSettings(configStore):
                        VotingConfigSettingsView(store: configStore)
                    }
                }
            }
            .alert($store.scope(state: \.submissionAlert, action: \.submissionAlert))
            .alert($store.scope(state: \.skipBundlesAlert, action: \.skipBundlesAlert))
            .votingSheet(
                isPresented: keystoneSignatureRejectionBinding,
                title: String(localizable: .coinVoteDelegationSigningSignatureRejectedTitle),
                message: store.keystoneSignatureRejectionSheet?.message ?? "",
                primary: .init(
                    title: String(localizable: .coinVoteDelegationSigningSignatureRejectedOk),
                    style: .primary
                ) {
                    store.send(.dismissKeystoneSignatureRejectionSheet)
                },
                secondary: nil
            )
            .votingSheet(
                isPresented: pollClosedSheetBinding,
                title: String(localizable: .coinVotePollClosedSheetTitle),
                message: String(localizable: .coinVotePollClosedSheetMessage),
                primary: .init(
                    title: pollClosedPrimaryTitle,
                    style: .primary
                ) {
                    store.send(.viewPollClosedResults)
                },
                secondary: .init(
                    title: String(localizable: .coinVoteCommonClose),
                    style: .secondary
                ) {
                    store.send(.dismissPollClosedAlert)
                }
            )
            .onChange(of: store.selectedWalletAccount?.id) { _ in
                store.send(.walletAccountChanged(store.selectedWalletAccount))
            }
        }
    }

    private var pollClosedSheetBinding: Binding<Bool> {
        Binding(
            get: { store.pollClosedSheet != nil },
            set: { newValue in
                if !newValue {
                    store.send(.dismissPollClosedAlert)
                }
            }
        )
    }

    private var keystoneSignatureRejectionBinding: Binding<Bool> {
        Binding(
            get: { store.keystoneSignatureRejectionSheet != nil },
            set: { newValue in
                if !newValue {
                    store.send(.dismissKeystoneSignatureRejectionSheet)
                }
            }
        )
    }

    /// Tallying rounds don't have results yet — surface "View status" so the
    /// user lands on the tallying screen instead of an empty results view.
    private var pollClosedPrimaryTitle: String {
        switch store.pollClosedSheet?.status {
        case .finalized, .none, .some(.active), .some(.unspecified):
            return String(localizable: .coinVoteCommonViewResults)
        case .some(.tallying):
            return String(localizable: .coinVotePollClosedSheetViewStatus)
        }
    }

    // MARK: - Root screen rendering

    @ViewBuilder
    private var rootContent: some View {
        switch store.rootScreen {
        case .loading:
            VotingCoordFlowBackdrop(store: store)
        case .howToVote:
            HowToVoteView(store: store)
        case .noRounds:
            NoRoundsView(store: store)
        case .pollsList:
            PollsListView(store: store)
        case .walletSyncing:
            WalletSyncingView(store: store)
        case let .error(message):
            VotingErrorView(
                store: store,
                title: String(localizable: .coinVoteErrorTitle),
                message: message
            )
        case let .configError(message):
            VotingErrorView(
                store: store,
                title: String(localizable: .coinVoteErrorConfigUnavailableTitle),
                message: message,
                recoveryAction: .init(
                    title: String(localizable: .coinVoteErrorChangeDataSource),
                    action: .openConfigSettings
                )
            )
        }
    }
}
#endif
