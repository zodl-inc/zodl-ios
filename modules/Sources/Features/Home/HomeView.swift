import SwiftUI
import ComposableArchitecture
import StoreKit
import Generated
import TransactionList
import Settings
import UIComponents
import Utils
import Models
import WalletBalances
import Scan
import SmartBanner

public struct HomeView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Perception.Bindable var store: StoreOf<Home>
    let tokenName: String

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    @Shared(.inMemory(.walletStatus)) public var walletStatus: WalletStatus = .none

    public init(store: StoreOf<Home>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                WalletBalancesView(
                    store: store.scope(
                        state: \.walletBalancesState,
                        action: \.walletBalances
                    ),
                    tokenName: tokenName,
                    couldBeHidden: true,
                    shortened: true
                )
                .padding(.top, 1)

                HStack {
                    button(
                        L10n.Tabs.receive,
                        icon: Asset.Assets.Icons.received.image
                    ) {
                        store.send(.receiveScreenRequested)
                    }

                    Spacer(minLength: 8)

                    button(
                        L10n.Tabs.send,
                        icon: Asset.Assets.Icons.sent.image
                    ) {
                        store.send(.sendTapped)
                    }

                    Spacer(minLength: 8)

                    button(
                        L10n.SwapAndPay.pay,
                        icon: Asset.Assets.Icons.pay.image
                    ) {
                        store.send(.payWithNearTapped)
                    }

                    Spacer(minLength: 8)

                    button(
                        L10n.SwapAndPay.swap,
                        icon: Asset.Assets.Icons.swap.image
                    ) {
                        store.send(.swapWithNearTapped)
                    }
                }
                .zFont(.medium, size: 12, style: Design.Text.primary)
                .padding(.top, 24)
                .screenHorizontalPadding()

                SmartBannerView(
                    store: store.scope(
                        state: \.smartBannerState,
                        action: \.smartBanner
                    ),
                    tokenName: tokenName
                )

                ScrollView {
                    if store.transactionListState.transactions.isEmpty && !store.transactionListState.isInvalidated {
                        noTransactionsView()
                    } else {
                        VStack(spacing: 0) {
                            transactionsView()
                            
                            TransactionListView(
                                store:
                                    store.scope(
                                        state: \.transactionListState,
                                        action: \.transactionList
                                    ),
                                tokenName: tokenName,
                                scrollable: false
                            )
                        }
                    }
                }
            }
            .sheet(isPresented: $store.isInAppBrowserKeystoneOn) {
                if let url = URL(string: store.inAppBrowserURLKeystone) {
                    InAppBrowserView(url: url)
                }
            }
            .zashiSheet(isPresented: $store.accountSwitchRequest, horizontalPadding: Design.Spacing.edgeToEdgeSpacing) {
                accountSwitchContent()
            }
            .zashiSheet(isPresented: $store.moreRequest, horizontalPadding: 0) {
                moreContent()
            }
            .zashiSheet(isPresented: $store.payRequest, horizontalPadding: 0) {
                // FIXME: delete this
                payRequestContent()
            }
            .navigationBarItems(
                leading:
                    walletAccountSwitcher()
            )
            .navigationBarItems(
                trailing:
                    HStack(spacing: 0) {
                        hideBalancesButton()
                        
                        settingsButton()
                    }
            )
            .overlayPreferenceValue(ExchangeRateStaleTooltipPreferenceKey.self) { preferences in
                WithPerceptionTracking {
                    if store.isRateTooltipEnabled {
                        GeometryReader { geometry in
                            preferences.map {
                                Tooltip(
                                    title: L10n.Tooltip.ExchangeRate.title,
                                    desc: L10n.Tooltip.ExchangeRate.desc
                                ) {
                                    store.send(.rateTooltipTapped)
                                }
                                .frame(width: geometry.size.width - 40)
                                .offset(x: 20, y: geometry[$0].minY + geometry[$0].height)
                            }
                        }
                    }
                }
            }
            .applyScreenBackground()
            .onAppear {
                store.send(.onAppear)
            }
            .onChange(of: store.canRequestReview) { canRequestReview in
                if canRequestReview {
                    if let currentScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        SKStoreReviewController.requestReview(in: currentScene)
                    }
                    store.send(.reviewRequestFinished)
                }
            }
            .onDisappear { store.send(.onDisappear) }
            .alert(
                store:
                    store.scope(
                        state: \.$alert,
                        action: \.alert
                    )
            )
        }
    }

    @ViewBuilder func transactionsView() -> some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                Text(L10n.General.activity)
                    .zFont(.semiBold, size: 18, style: Design.Text.primary)
                
                Spacer()
                
                if store.transactionListState.transactions.count > TransactionList.Constants.homePageTransactionsCount {
                    Button {
                        store.send(.seeAllTransactionsTapped)
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.TransactionHistory.seeAll)
                                .zFont(.semiBold, size: 14, style: Design.Btns.Tertiary.fg)
                            
                            Asset.Assets.chevronRight.image
                                .zImage(size: 16, style: Design.Btns.Tertiary.fg)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                .fill(Design.Btns.Tertiary.bg.color(colorScheme))
                        }
                    }
                }
            }
            .screenHorizontalPadding()
        }
    }

    @ViewBuilder func noTransactionsView() -> some View {
        WithPerceptionTracking {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<5) { _ in
                        NoTransactionPlaceholder()
                    }
                    
                    Spacer()
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: .clear, location: 0.0),
                            Gradient.Stop(color: Asset.Colors.background.color, location: 0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                
                VStack(spacing: 0) {
                    Asset.Assets.Illustrations.emptyState.image
                        .resizable()
                        .frame(width: 164, height: 164)
                        .padding(.bottom, 20)

                    Text(L10n.TransactionHistory.nothingHere)
                        .zFont(.semiBold, size: 18, style: Design.Text.primary)
                        .padding(.bottom, 8)
                }
                .padding(.top, 40)
            }
        }
    }
    
    @ViewBuilder private func button(
        _ title: String,
        icon: Image,
        action: @escaping () -> Void
    ) -> some View {
        if colorScheme == .light {
            Button {
                action()
            } label: {
                VStack(spacing: 4) {
                    icon
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 24, height: 24)
                    
                    Text(title)
                }
                .frame(minWidth: 64, maxWidth: 84, minHeight: 64, maxHeight: 84, alignment: .center)
                .aspectRatio(1, contentMode: .fit)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._3xl)
                        .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .stroke(Design.Utility.Gray._100.color(colorScheme))
                        }
                }
                .shadow(color: .black.opacity(0.02), radius: 0.66667, x: 0, y: 1.33333)
                .shadow(color: .black.opacity(0.08), radius: 1.33333, x: 0, y: 1.33333)
                .padding(.bottom, 4)
            }
        } else {
            Button {
                action()
            } label: {
                VStack(spacing: 4) {
                    icon
                        .resizable()
                        .renderingMode(.template)
                        .frame(width: 24, height: 24)
                    
                    Text(title)
                }
                .frame(minWidth: 64, maxWidth: 84, minHeight: 64, maxHeight: 84, alignment: .center)
                .aspectRatio(1, contentMode: .fit)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._3xl)
                        .fill(
                            LinearGradient(
                                stops: [
                                    Gradient.Stop(color: Asset.Colors.ZDesign.sharkShades12dp.color, location: 0.00),
                                    Gradient.Stop(color: Asset.Colors.ZDesign.sharkShades01dp.color, location: 1.00)
                                ],
                                startPoint: UnitPoint(x: 0.5, y: 0.0),
                                endPoint: UnitPoint(x: 0.5, y: 1.0)
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .stroke(
                                    LinearGradient(
                                        stops: [
                                            Gradient.Stop(color: Design.Utility.Gray._200.color(colorScheme), location: 0.00),
                                            Gradient.Stop(color: Design.Utility.Gray._200.color(colorScheme).opacity(0.15), location: 1.00)
                                        ],
                                        startPoint: UnitPoint(x: 0.5, y: 0.0),
                                        endPoint: UnitPoint(x: 0.5, y: 1.0)
                                    )
                                )
                        }
                }
                .shadow(color: .black.opacity(0.02), radius: 0.66667, x: 0, y: 1.33333)
                .shadow(color: .black.opacity(0.08), radius: 1.33333, x: 0, y: 1.33333)
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Previews

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            HomeView(
                store:
                    StoreOf<Home>(
                        initialState:
                                .init(
                                    transactionListState: .initial,
                                    walletBalancesState: .initial,
                                    walletConfig: .initial
                                )
                    ) {
                        Home()
                    },
                tokenName: "ZEC"
            )
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                trailing: Text("M")
            )
            .screenTitle("Title")
        }
    }
}

// MARK: Placeholders

extension Home.State {
    public static var initial: Self {
        .init(
            transactionListState: .initial,
            walletBalancesState: .initial,
            walletConfig: .initial
        )
    }
}

extension Home {
    public static var placeholder: StoreOf<Home> {
        StoreOf<Home>(
            initialState: .initial
        ) {
            Home()
        }
    }

    public static var error: StoreOf<Home> {
        StoreOf<Home>(
            initialState: .init(
                transactionListState: .initial,
                walletBalancesState: .initial,
                walletConfig: .initial
            )
        ) {
            Home()
        }
    }
}
