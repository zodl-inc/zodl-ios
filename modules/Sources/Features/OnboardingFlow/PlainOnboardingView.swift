////
////  PlainOnboardingView.swift
////  secant
////
////  Created by Francisco Gindre on 3/13/23.
////
//
//import SwiftUI
//import ComposableArchitecture
//import Generated
//import ZcashLightClientKit
//import UIComponents
//import CoordFlows
//
//public struct PlainOnboardingView: View {
//    @Perception.Bindable var store: StoreOf<OnboardingFlow>
//
//    public init(store: StoreOf<OnboardingFlow>) {
//        self.store = store
//    }
//
//    public var body: some View {
//        WithPerceptionTracking {
////            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
//                VStack {
//                    Spacer()
//
//                    Asset.Assets.welcomeScreenLogo.image
//                        .zImage(width: 169, height: 160, color: Asset.Colors.primary.color)
//
//                    Text(L10n.PlainOnboarding.title)
//                        .zFont(size: 20, style: Design.Text.secondary)
//                        .padding(.top, 15)
//                        .multilineTextAlignment(.center)
//                        .padding(.horizontal, 24)
//
//                    Spacer()
//                    
//                    ZashiButton(
//                        L10n.PlainOnboarding.Button.restoreWallet,
//                        type: .tertiary
//                    ) {
//                        store.send(.importExistingWallet)
//                    }
//                    .padding(.bottom, 8)
//                    
//                    ZashiButton(L10n.PlainOnboarding.Button.createNewWallet) {
//                        store.send(.createNewWalletTapped)
//                    }
//                    .padding(.bottom, 24)
//                }
//                .screenHorizontalPadding()
//                .applyOnboardingScreenBackground()
//                .alert($store.scope(state: \.alert, action: \.alert))
////            } destination: { store in
////                switch store.case {
////                case let .restoreWalletCoordFlowState(store):
////                    RestoreWalletCoordFlowView(store: store)
////                }
////            }
//            // FIXME: reimplement to get rid of navigationLinkEmpty
////            .navigationLinkEmpty(
////                isActive: store.bindingFor(.importExistingWallet),
////                destination: {
////                    RestoreWalletCoordFlowView(
////                        store: store.scope(
////                            state: \.restoreWalletCoordFlowState,
////                            action: \.restoreWalletCoordFlow
////                        )
////                    )
////                }
////            )
////        }
//        //.navigationBarTitleDisplayMode(.inline)
//    }
//}
//
//#Preview {
//    PlainOnboardingView(
//        store:
//            Store(
//                initialState: OnboardingFlow.State(
//                    walletConfig: .initial
//                )
//            ) {
//                OnboardingFlow()
//            }
//    )
//}
//
//// MARK: - ViewStore
//
////extension StoreOf<OnboardingFlow> {
////    func bindingFor(_ destination: OnboardingFlow.State.Destination) -> Binding<Bool> {
////        Binding<Bool>(
////            get: { self.destination == destination },
////            set: { self.send(.updateDestination($0 ? destination : nil)) }
////        )
////    }
////}
//
//// MARK: Placeholders
//
//extension OnboardingFlow.State {
//    public static var initial: Self {
//        .init(
//            walletConfig: .initial
//        )
//    }
//}
