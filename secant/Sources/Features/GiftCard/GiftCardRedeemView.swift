//
//  GiftCardRedeemView.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

import Lottie

/// Every step of redeeming one gift card. The progress and result steps reuse the look of the
/// send flow's Sending / Pending / Success / Failure screens (same animation, illustrations and
/// backgrounds); those screens themselves are bound to `SendConfirmation` and can't be reused as is.
struct GiftCardRedeemView: View {
    @Environment(\.colorScheme) var colorScheme

    private enum Constants {
        static let lottieNameLight = "sending"
        static let lottieNameDark = "sending-dark"
    }

    @Perception.Bindable var store: StoreOf<GiftCardRedeem>
    let tokenName: String

    init(store: StoreOf<GiftCardRedeem>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            content()
                .onAppear { store.send(.onAppear) }
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden()
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    @ViewBuilder private func content() -> some View {
        switch store.step {
        case .checking:
            progressScreen(
                title: String(localizable: .giftCardCheckingTitle),
                desc: String(localizable: .giftCardCheckingDesc),
                progress: store.syncProgress
            )
            .screenTitle(String(localizable: .giftCardTitle))
            .zashiBack { store.send(.closeTapped) }
            .applyScreenBackground()

        case .ready(let spendable):
            readyScreen(spendable)

        case let .pending(amount, _):
            pendingScreen(amount)

        case .empty:
            resultScreen(
                illustration: Asset.Assets.Illustrations.emptyState.image,
                title: String(localizable: .giftCardEmptyTitle),
                desc: String(localizable: .giftCardEmptyDesc),
                retryTitle: String(localizable: .giftCardCheckAgain)
            )
            .applyScreenBackground()

        case .invalidLink:
            errorScreen(title: String(localizable: .giftCardInvalidTitle), desc: String(localizable: .giftCardInvalidDesc))

        case .unsupportedVersion:
            errorScreen(title: String(localizable: .giftCardUnsupportedTitle), desc: String(localizable: .giftCardUnsupportedDesc))

        case .wrongNetwork:
            errorScreen(title: String(localizable: .giftCardWrongNetworkTitle), desc: String(localizable: .giftCardWrongNetworkDesc))

        case .unavailable:
            errorScreen(title: String(localizable: .giftCardUnavailableTitle), desc: String(localizable: .giftCardUnavailableDesc))

        case .checkFailed:
            errorScreen(
                title: String(localizable: .giftCardCheckFailedTitle),
                desc: String(localizable: .giftCardCheckFailedDesc),
                retryTitle: String(localizable: .giftCardTryAgain)
            )

        case .redeeming:
            progressScreen(
                title: String(localizable: .giftCardRedeemingTitle),
                desc: String(localizable: .giftCardRedeemingDesc),
                progress: nil
            )
            .applyScreenBackground()

        case .success:
            resultScreen(
                illustration: Asset.Assets.Illustrations.success1.image,
                title: String(localizable: .giftCardSuccessTitle),
                desc: String(localizable: .giftCardSuccessDesc),
                retryTitle: nil
            )
            .applySuccessScreenBackground()

        case .failure:
            errorScreen(
                title: String(localizable: .giftCardFailureTitle),
                desc: String(localizable: .giftCardFailureDesc),
                retryTitle: String(localizable: .giftCardTryAgain)
            )
        }
    }
}

// MARK: - Steps

extension GiftCardRedeemView {
    @ViewBuilder func readyScreen(_ spendable: Zatoshi) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Text(localizable: .giftCardReadyTitle)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 12)

                    BalanceWithIconView(balance: spendable)

                    if let fiatAmount = store.fiatAmount {
                        Text(fiatAmount)
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            .padding(.top, 10)
                    }
                }
                .padding(.top, 40)
                .padding(.bottom, 32)

                if let message = store.message {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localizable: .giftCardMessageFromSender)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)

                        HStack {
                            // Written by whoever made the card: shown verbatim, never as markup.
                            Text(verbatim: message)
                                .zFont(.medium, size: 14, style: Design.Inputs.Filled.text)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._lg)
                                .fill(Design.Inputs.Filled.bg.color(colorScheme))
                        }
                    }
                    .padding(.bottom, 24)
                }

                destinationRow()
                    .padding(.bottom, 24)

                ZashiInfoCallout(
                    style: .plain,
                    title: String(localizable: .giftCardFeeTitle),
                    body: String(localizable: .giftCardFeeDesc)
                )
            }
            .padding(.vertical, 1)

            Spacer()

            ZashiButton(String(localizable: .giftCardRedeem)) {
                store.send(.redeemTapped)
            }
            .disabled(!store.isRedeemable)
            .padding(.bottom, 24)
        }
        .screenHorizontalPadding()
        .screenTitle(String(localizable: .giftCardTitle))
        .zashiBack { store.send(.closeTapped) }
        .applyScreenBackground()
    }

    @ViewBuilder func destinationRow() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(localizable: .giftCardDestination)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)

                if let account = store.selectedWalletAccount {
                    HStack(spacing: 0) {
                        account.vendor.icon()
                            .resizable()
                            .frame(width: 24, height: 24)
                            .background {
                                Circle()
                                    .fill(Design.Surfaces.bgAlt.color(colorScheme))
                                    .frame(width: 32, height: 32)
                            }

                        Text(account.vendor.name())
                            .zFont(.semiBold, size: 16, style: Design.Text.primary)
                            .padding(.leading, 16)
                    }
                    .padding(.leading, 4)
                }

                if let address = store.destinationAddress?.data {
                    Text(address.zip316)
                        .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.primary)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder func pendingScreen(_ amount: Zatoshi) -> some View {
        VStack(spacing: 0) {
            Spacer()

            sendingAnimation()

            Text(localizable: .giftCardPendingTitle)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(localizable: .giftCardPendingDesc(formatted(amount)))
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .padding(.top, 8)

            Spacer()

            ZashiButton(String(localizable: .generalClose), type: .ghost) {
                store.send(.closeTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .giftCardCheckAgain)) {
                store.send(.retryTapped)
            }
            .padding(.bottom, 24)
        }
        .padding(.vertical, 1)
        .screenHorizontalPadding()
        .applyIndigoScreenBackground()
    }

    @ViewBuilder func progressScreen(title: String, desc: String, progress: Double?) -> some View {
        VStack(spacing: 0) {
            Spacer()

            sendingAnimation()

            Text(title)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(desc)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .padding(.top, 8)

            if let progress {
                ProgressView(value: progress, total: 1)
                    .tint(Asset.Colors.ZDesign.Base.brand.color)
                    .padding(.top, 24)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
        .padding(.vertical, 1)
        .screenHorizontalPadding()
    }

    @ViewBuilder func errorScreen(title: String, desc: String, retryTitle: String? = nil) -> some View {
        resultScreen(
            illustration: Asset.Assets.Illustrations.failure1.image,
            title: title,
            desc: desc,
            retryTitle: retryTitle
        )
        .applyFailureScreenBackground()
    }

    @ViewBuilder func resultScreen(illustration: Image, title: String, desc: String, retryTitle: String?) -> some View {
        VStack(spacing: 0) {
            Spacer()

            illustration
                .resizable()
                .frame(width: 148, height: 148)

            Text(title)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(desc)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .padding(.top, 8)

            Spacer()

            ZashiButton(String(localizable: .generalClose), type: retryTitle == nil ? .primary : .ghost) {
                store.send(.closeTapped)
            }
            .padding(.bottom, retryTitle == nil ? 24 : 12)

            if let retryTitle {
                ZashiButton(retryTitle) {
                    store.send(.retryTapped)
                }
                .padding(.bottom, 24)
            }
        }
        .padding(.vertical, 1)
        .screenHorizontalPadding()
    }

    func formatted(_ amount: Zatoshi) -> String {
        "\(amount.decimalZashiFormatted()) \(tokenName)"
    }

    @ViewBuilder func sendingAnimation() -> some View {
        LottieView(
            animation:
                    .named(
                        colorScheme == .light ? Constants.lottieNameLight : Constants.lottieNameDark
                    )
        )
        .resizable()
        .looping()
        .frame(width: 170, height: 170)
    }
}

// MARK: - Previews

#Preview("Checking") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.checking, progress: 0.4), tokenName: "ZEC")
    }
}

#Preview("Ready") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.ready(spendable: Zatoshi(10_000_000))), tokenName: "ZEC")
    }
}

#Preview("Pending") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.pending(amount: Zatoshi(10_000_000), confirmationsNeeded: 3)), tokenName: "ZEC")
    }
}

#Preview("Empty") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.empty), tokenName: "ZEC")
    }
}

#Preview("Wrong network") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.wrongNetwork), tokenName: "ZEC")
    }
}

#Preview("Success") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.success), tokenName: "ZEC")
    }
}

#Preview("Failure") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.failure(amount: Zatoshi(10_000_000))), tokenName: "ZEC")
    }
}

#Preview("Live mock flow") {
    NavigationView {
        GiftCardRedeemView(
            store: StoreOf<GiftCardRedeem>(
                initialState: GiftCardRedeem.State(link: GiftCardRedeem.State.previewLink)
            ) {
                GiftCardRedeem()
            } withDependencies: {
                var scenario = GiftCardClient.MockScenario.ready
                scenario.delay = .seconds(2)
                $0.giftCard = .mock(scenario)
            },
            tokenName: "ZEC"
        )
    }
}

// MARK: - Placeholders

extension GiftCardRedeem.State {
    /// A made-up link with a placeholder key; good for previews and tests only.
    static let previewLink = "https://gift.zodl.com/#v=1&key=zgift1preview&height=3000000&amount=0.1".redacted

    static var initial: Self {
        .init(link: previewLink)
    }
}

extension GiftCardRedeem {
    @MainActor static func preview(_ step: State.Step, progress: Double? = nil) -> StoreOf<GiftCardRedeem> {
        var state = State.initial
        state.summary = GiftCardSummary(
            origin: .zodl,
            networkType: .mainnet,
            birthdayHeight: 3_000_000,
            statedAmount: Zatoshi(10_000_000),
            message: "Welcome to Zcash Summit"
        )
        state.step = step
        state.syncProgress = progress
        state.destinationAddress = "u1previewdestinationaddressorchardonly".redacted
        return StoreOf<GiftCardRedeem>(initialState: state) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = .mock()
        }
    }
}
