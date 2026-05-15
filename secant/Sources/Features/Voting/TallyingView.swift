import SwiftUI
import ComposableArchitecture

struct TallyingView: View {
    @Environment(\.colorScheme)
    var colorScheme

    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 24) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                    }

                    // Title
                    Text(localizable: .coinVoteTallyingTitle)
                        .zFont(.semiBold, size: 22, style: Design.Text.primary)

                    // Description
                    Text(localizable: .coinVoteTallyingSubtitle)
                        .zFont(.regular, size: 15, style: Design.Text.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    // Spinner
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(localizable: .coinVoteTallyingStatus)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    }

                    // Round info card
                    roundInfoCard()
                        .padding(.horizontal, 24)
                }

                Spacer()
            }
            .navigationTitle(String(localizable: .coinVoteCommonGovernanceTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.send(.dismissFlow)
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func roundInfoCard() -> some View {
        VStack(spacing: 10) {
            detailRow(label: String(localizable: .coinVoteTallyingDetailRound), value: store.votingRound.title)
            detailRow(
                label: String(localizable: .coinVoteTallyingDetailEnded),
                value: store.votingRound.votingEnd.formatted(date: .abbreviated, time: .omitted)
            )
            detailRow(
                label: String(localizable: .coinVoteTallyingDetailProposals),
                value: String(store.votingRound.proposals.count)
            )
        }
        .padding(16)
        .background(Design.Surfaces.bgPrimary.color(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .zFont(.medium, size: 14, style: Design.Text.tertiary)
            Spacer()
            Text(value)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)
        }
    }
}
