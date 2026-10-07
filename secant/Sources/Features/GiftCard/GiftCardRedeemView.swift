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

    enum Constants {
        static let lottieNameLight = "sending"
        static let lottieNameDark = "sending-dark"
        /// The closed gift (Paste link, Ready) is drawn on a smaller canvas than the status
        /// illustrations (Pending, Success, Nothing to redeem), as in the design.
        static let closedGiftSize: CGFloat = 108
        static let statusIllustrationSize: CGFloat = 148
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
            // The design has no title bar here; the back arrow stays so that a slow check can be left.
            progressScreen(
                title: String(localizable: .giftCardCheckingTitle),
                desc: String(localizable: .giftCardCheckingDesc)
            )
            .zashiBack { store.send(.closeTapped) }
            .applyScreenBackground()

        case .ready:
            readyScreen()

        case .pending:
            statusScreen(
                illustration: Asset.Assets.Illustrations.giftPreparing.image,
                title: String(localizable: .giftCardPendingTitle),
                desc: String(localizable: .giftCardPendingDesc(receivedFormatted())),
                retryTitle: String(localizable: .giftCardCheckAgain)
            )
            .applyIndigoScreenBackground()

        case .empty:
            statusScreen(
                illustration: Asset.Assets.Illustrations.giftEmpty.image,
                title: String(localizable: .giftCardEmptyTitle),
                desc: String(localizable: .giftCardEmptyDesc),
                retryTitle: String(localizable: .giftCardCheckAgain)
            )
            .applyFailureScreenBackground()

        case .dust:
            // Checking again cannot help a card whose funds would all go to the fee: Close only.
            statusScreen(
                illustration: Asset.Assets.Illustrations.giftEmpty.image,
                title: String(localizable: .giftCardEmptyTitle),
                desc: String(localizable: .giftCardDustDesc),
                retryTitle: nil
            )
            .applyFailureScreenBackground()

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
                desc: String(localizable: .giftCardRedeemingDesc)
            )
            .applyScreenBackground()

        case .success:
            statusScreen(
                illustration: Asset.Assets.Illustrations.giftOpen.image,
                title: String(localizable: .giftCardSuccessTitle),
                desc: String(localizable: .giftCardSuccessDesc(receivedFormatted())),
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
    @ViewBuilder func readyScreen() -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Asset.Assets.Illustrations.giftClosed.image
                        .zImage(width: Constants.closedGiftSize, height: Constants.closedGiftSize, style: Design.Text.primary)
                        .accessibilityHidden(true)
                        .padding(.top, 24)

                    Text(localizable: .giftCardReadyTitle)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)

                    if let received = store.receivedAmount {
                        Group {
                            Text(received.atLeastThreeDecimalsZashiFormatted())
                            + Text(" \(tokenName)")
                                .foregroundColor(Design.Text.quaternary.color(colorScheme))
                        }
                        .zFont(.semiBold, size: 48, style: Design.Text.primary)
                        .minimumScaleFactor(0.1)
                        .lineLimit(1)
                        .accessibilityIdentifier(AccessibilityID.GiftCard.redeemAmount)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 32)

                if let message = store.message {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localizable: .giftCardMessageFromSender)
                            .zFont(.medium, size: 14, style: Design.Text.tertiary)

                        HStack {
                            // Written by whoever made the card: shown verbatim, never as markup, after
                            // the same label the redemption's memo carries.
                            Text(verbatim: "\(String(localizable: .giftCardRedeemMemo)) · \(message)")
                                .zFont(.medium, size: 14, style: Design.Inputs.Filled.text)
                                .accessibilityIdentifier(AccessibilityID.GiftCard.redeemMessage)

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
            }
            .padding(.vertical, 1)

            Spacer()

            HStack(alignment: .top, spacing: 0) {
                Asset.Assets.infoOutline.image
                    .zImage(size: 16, style: Design.Text.tertiary)
                    .accessibilityHidden(true)
                    .padding(.trailing, 8)

                Text(readyNote())
                    .zFont(size: 12, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.GiftCard.redeemDisclaimer)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)

            ZashiButton(String(localizable: .giftCardRedeem)) {
                store.send(.redeemTapped)
            }
            .disabled(!store.isRedeemable)
            .accessibilityIdentifier(AccessibilityID.GiftCard.redeemButton)
            .padding(.bottom, 24)
        }
        .screenHorizontalPadding()
        .screenTitle(String(localizable: .giftCardTitle))
        .zashiBack { store.send(.closeTapped) }
        .applyScreenBackground()
    }

    @ViewBuilder func progressScreen(title: String, desc: String) -> some View {
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

            Spacer()
        }
        .padding(.vertical, 1)
        .screenHorizontalPadding()
    }

    @ViewBuilder func errorScreen(title: String, desc: String, retryTitle: String? = nil) -> some View {
        statusScreen(
            illustration: Asset.Assets.Illustrations.failure1.image,
            templated: false,
            title: title,
            desc: desc,
            retryTitle: retryTitle
        )
        .applyFailureScreenBackground()
    }

    /// An outcome: illustration, title and description, then Check again / Try again (when the step
    /// can be retried) above Close.
    @ViewBuilder func statusScreen(
        illustration: Image,
        templated: Bool = true,
        title: String,
        desc: String,
        retryTitle: String?
    ) -> some View {
        VStack(spacing: 0) {
            Spacer()

            if templated {
                illustration
                    .zImage(width: Constants.statusIllustrationSize, height: Constants.statusIllustrationSize, style: Design.Text.primary)
                    .accessibilityHidden(true)
            } else {
                illustration
                    .resizable()
                    .frame(width: Constants.statusIllustrationSize, height: Constants.statusIllustrationSize)
                    .accessibilityHidden(true)
            }

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

            if let retryTitle {
                // The design's grey button: dark text on a light grey fill in light mode, white on a
                // mid grey in dark mode. Quaternary is the closest style in both modes (tertiary's
                // dark-mode text barely shows on its fill); its light fill is a little darker.
                if store.isRechecking {
                    // Check again runs without leaving the screen; the button shows it is busy.
                    ZashiButton(retryTitle, type: .quaternary, accessoryView: ProgressView()) {
                        store.send(.retryTapped)
                    }
                    .disabled(true)
                    .padding(.bottom, 12)
                } else {
                    ZashiButton(retryTitle, type: .quaternary) {
                        store.send(.retryTapped)
                    }
                    .padding(.bottom, 12)
                }
            }

            ZashiButton(String(localizable: .generalClose)) {
                store.send(.closeTapped)
            }
            .padding(.bottom, 24)
        }
        .padding(.vertical, 1)
        .screenHorizontalPadding()
    }

    /// Where the funds go, named after the selected account's wallet, and that the amount shown is
    /// already net of the network fee.
    func readyNote() -> String {
        guard let wallet = store.selectedWalletAccount?.vendor.name() else {
            return String(localizable: .giftCardReadyNoteNoWallet)
        }
        return String(localizable: .giftCardReadyNote(wallet))
    }

    /// The amount the wallet receives, as the screens show it, e.g. "0.100 ZEC": at least three
    /// decimals like the rest of the app, and never rounded, so a card is not shown as more than it gives.
    func receivedFormatted() -> String {
        guard let received = store.receivedAmount else {
            return ""
        }
        return "\(received.atLeastThreeDecimalsZashiFormatted()) \(tokenName)"
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
        GiftCardRedeemView(store: GiftCardRedeem.preview(.checking), tokenName: "ZEC")
    }
}

#Preview("Ready") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.ready(redeemable: Zatoshi(10_000_000))), tokenName: "ZEC")
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

#Preview("Dust") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.dust), tokenName: "ZEC")
    }
}

#Preview("Wrong network") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.wrongNetwork), tokenName: "ZEC")
    }
}

#Preview("Success") {
    NavigationView {
        GiftCardRedeemView(store: GiftCardRedeem.preview(.success(received: Zatoshi(10_000_000))), tokenName: "ZEC")
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
    @MainActor static func preview(_ step: State.Step) -> StoreOf<GiftCardRedeem> {
        var state = State.initial
        state.summary = GiftCardSummary(
            origin: .zodl,
            networkType: .mainnet,
            birthdayHeight: 3_000_000,
            statedAmount: Zatoshi(10_000_000),
            message: "Welcome to Zcash Summit"
        )
        state.step = step
        state.destinationAddress = "u1previewdestinationaddressorchardonly".redacted
        return StoreOf<GiftCardRedeem>(initialState: state) {
            GiftCardRedeem()
        } withDependencies: {
            $0.giftCard = .mock()
        }
    }
}
