import SwiftUI
import ComposableArchitecture

struct HowToVoteView: View {
    @Environment(\.colorScheme)
    var colorScheme

    let store: StoreOf<Voting>

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerIcons()
                            .padding(.top, 12)
                            .padding(.bottom, 24)

                        Text(localizable: store.isKeystoneUser
                            ? .coinVoteHowToVoteTitleKeystone
                            : .coinVoteHowToVoteTitleZodl)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(localizable: .coinVoteHowToVoteSubtitle)
                            .zFont(size: 15, style: Design.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 32)

                        stepRow(
                            number: 1,
                            title: String(localizable: .coinVoteHowToVoteStepVotingTitle),
                            body: String(localizable: .coinVoteHowToVoteStepVotingBody)
                        )
                        .padding(.bottom, 24)

                        stepRow(
                            number: 2,
                            title: String(localizable: .coinVoteHowToVoteStepAuthorizeTitle),
                            body: String(localizable: .coinVoteHowToVoteStepAuthorizeBody)
                        )
                    }
                    .padding(.horizontal, 24)
                }

                infoCard()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)

                ZashiButton(String(localizable: .coinVoteCommonContinue)) {
                    store.send(.howToVoteContinueTapped)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteCommonScreenTitle))
            .zashiBack { store.send(.dismissFlow) }
        }
    }

    // MARK: - Header Icons

    @ViewBuilder
    private func headerIcons() -> some View {
        VotingHeaderIcons(isKeystone: store.isKeystoneUser)
    }

    // MARK: - Numbered Step

    @ViewBuilder
    private func stepRow(number: Int, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Design.Text.primary.color(colorScheme))
                    .frame(width: 24, height: 24)
                Text("\(number)")
                    .zFont(.semiBold, size: 12, style: Design.Surfaces.bgPrimary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(body)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Info Card

    @ViewBuilder
    private func infoCard() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoOutline.image
                .zImage(size: 16, style: Design.Text.tertiary)

            Text(localizable: .coinVoteHowToVoteInfoCard)
                .zFont(size: 12, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}
