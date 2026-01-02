import SwiftUI
import StoreKit
import ComposableArchitecture
import Generated
import Models
import NotEnoughFreeSpace
import Welcome
import ExportLogs
import OnboardingFlow
import ZcashLightClientKit
import UIComponents
import DeeplinkWarning
import OSStatusError

// Path
import CurrencyConversionSetup
import Home
import Receive
import RecoveryPhraseDisplay
import CoordFlows
import ServerSetup
import Settings
import TorSetup

public struct RootView: View {
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.colorScheme) var colorScheme
    @State var covered = false
    
    @Perception.Bindable var store: StoreOf<Root>
    let tokenName: String
    let networkType: NetworkType

    public init(store: StoreOf<Root>, tokenName: String, networkType: NetworkType) {
        self.store = store
        self.tokenName = tokenName
        self.networkType = networkType
    }
    
    public var body: some View {
        switchOverDestination()
            .overlay {
                if covered {
                    VStack {
                        ZashiIcon()
                            .scaleEffect(2.0)
                            .padding(.bottom, 180)
                    }
                    .applyScreenBackground()
                }
            }
            .onChange(of: scenePhase) { value in
                covered = value == .background
            }
    }
}

private struct FeatureFlagWrapper: Identifiable, Equatable, Comparable {
    let name: FeatureFlag
    let isEnabled: Bool
    var id: String { name.rawValue }

    static func < (lhs: FeatureFlagWrapper, rhs: FeatureFlagWrapper) -> Bool {
        lhs.name.rawValue < rhs.name.rawValue
    }

    static func == (lhs: FeatureFlagWrapper, rhs: FeatureFlagWrapper) -> Bool {
        lhs.name.rawValue == rhs.name.rawValue
    }
}

private extension RootView {
    @ViewBuilder func switchOverDestination() -> some View {
        WithPerceptionTracking {
            Group {
                switch store.destinationState.destination {
                case .deeplinkWarning:
                    NavigationView {
                        DeeplinkWarningView(
                            store: store.scope(
                                state: \.deeplinkWarningState,
                                action: \.deeplinkWarning
                            )
                        )
                    }
                    .navigationViewStyle(.stack)
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }
                    
                case .notEnoughFreeSpace:
                    NavigationView {
                        NotEnoughFreeSpaceView(
                            store: store.scope(
                                state: \.notEnoughFreeSpaceState,
                                action: \.notEnoughFreeSpace
                            )
                        )
                    }
                    .navigationViewStyle(.stack)
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }

                case .osStatusError:
                    NavigationView {
                        OSStatusErrorView(
                            store: store.scope(
                                state: \.osStatusErrorState,
                                action: \.osStatusError
                            )
                        )
                    }
                    .navigationViewStyle(.stack)
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }

                case .home:
                    ZStack {
                        // Home view
                        NavigationStack {
                            HomeView(
                                store: store.scope(
                                    state: \.homeState,
                                    action: \.home
                                ),
                                tokenName: tokenName
                            )
                        }
                        .offset(x: store.path == nil ? 0 : -200)
                        
                        // Paths
                        if let path = store.path {
                            if path == .settings {
                                SettingsView(
                                    store:
                                        store.scope(
                                            state: \.settingsState,
                                            action: \.settings)
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .receive {
                                ReceiveView(
                                    store:
                                        store.scope(
                                            state: \.receiveState,
                                            action: \.receive),
                                    networkType: networkType,
                                    tokenName: tokenName
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .requestZecCoordFlow {
                                // FIXME: missing back button
                                // TODO: this is no longer connected in the UI, it was in `get some ZEC` button
                                RequestZecCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.requestZecCoordFlowState,
                                            action: \.requestZecCoordFlow),
                                    tokenName: tokenName
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .sendCoordFlow {
                                SendCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.sendCoordFlowState,
                                            action: \.sendCoordFlow),
                                    tokenName: tokenName
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .scanCoordFlow {
                                // FIXME: missing back button
                                // TODO: this is no longer connected in the UI, it was under `scan` button
                                ScanCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.scanCoordFlowState,
                                            action: \.scanCoordFlow),
                                    tokenName: tokenName
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .addKeystoneHWWalletCoordFlow {
                                // FIXME: missing back button
                                AddKeystoneHWWalletCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.addKeystoneHWWalletCoordFlowState,
                                            action: \.addKeystoneHWWalletCoordFlow),
                                    tokenName: tokenName
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .transactionsCoordFlow {
                                // FIXME: missing back button
                                // TODO: this flow looks to be connected, tested
                                TransactionsCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.transactionsCoordFlowState,
                                            action: \.transactionsCoordFlow),
                                    tokenName: tokenName
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .walletBackup {
                                // FIXME: missing back button
                                WalletBackupCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.walletBackupCoordFlowState,
                                            action: \.walletBackupCoordFlow)
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .currencyConversionSetup {
                                // FIXME: missing back button
                                CurrencyConversionSetupView(
                                    store:
                                        store.scope(
                                            state: \.currencyConversionSetupState,
                                            action: \.currencyConversionSetup)
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .torSetup {
                                // FIXME: missing back button
                                TorSetupView(
                                    store:
                                        store.scope(
                                            state: \.torSetupState,
                                            action: \.torSetup)
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .serverSwitch {
                                // FIXME: missing back button
                                ServerSetupView(
                                    store:
                                        store.scope(
                                            state: \.serverSetupState,
                                            action: \.serverSetup
                                        )
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .swapAndPayCoordFlow {
                                // FIXME: missing back button
                                SwapAndPayCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.swapAndPayCoordFlowState,
                                            action: \.swapAndPayCoordFlow),
                                    tokenName: tokenName
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            }
                        }
                    }
                    .popover(isPresented: $store.signWithKeystoneCoordFlowBinding) {
                        // FIXME: missing back button?
                        SignWithKeystoneCoordFlowView(
                            store:
                                store.scope(
                                    state: \.signWithKeystoneCoordFlowState,
                                    action: \.signWithKeystoneCoordFlow),
                            tokenName: tokenName
                        )
                    }
                    .animation(.easeInOut(duration: 0.3), value: store.path)
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }

                case .onboarding:
                    RestoreWalletCoordFlowView(
                        store: store.scope(
                            state: \.onboardingState,
                            action: \.onboarding
                        )
                    )
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }

                case .startup:
                    ZStack(alignment: .topTrailing) {
                        debugView(store)
                            .transition(.opacity)
                    }
                    
                case .welcome:
                    WelcomeView(
                        store: store.scope(
                            state: \.welcomeState,
                            action: \.welcome
                        )
                    )
                }
            }
            .onOpenURL(perform: { store.goToDeeplink($0) })
            .alert(
                store:
                    store.scope(
                        state: \.$alert,
                        action: \.alert
                    )
            )
            .alert(store: store.scope(
                state: \.exportLogsState.$alert,
                action: \.exportLogs.alert
            ))
            .fullScreenCover(
                isPresented:
                    Binding(
                        get: { store.serverSetupViewBinding },
                        set: { store.send(.serverSetupBindingUpdated($0)) }
                    )
            ) {
                NavigationView {
                    ServerSetupView(
                        store:
                            store.scope(
                                state: \.serverSetupState,
                                action: \.serverSetup
                            )
                    ) {
                        store.send(.serverSetupBindingUpdated(false))
                    }
                }
            }

            shareLogsView(store)
            shareView()
            
            if let supportData = store.supportData {
                UIMailDialogView(
                    supportData: supportData,
                    completion: {
                        store.send(.shareFinished)
                    }
                )
                // UIMailDialogView only wraps MFMailComposeViewController presentation
                // so frame is set to 0 to not break SwiftUI's layout
                .frame(width: 0, height: 0)
            }
        }
        .toast()
    }
}

private extension RootView {
    @ViewBuilder func shareLogsView(_ store: StoreOf<Root>) -> some View {
        if store.exportLogsState.isSharingLogs {
            UIShareDialogView(
                activityItems: store.exportLogsState.zippedLogsURLs
            ) {
                store.send(.exportLogs(.shareFinished))
            }
            // UIShareDialogView only wraps UIActivityViewController presentation
            // so frame is set to 0 to not break SwiftUI's layout
            .frame(width: 0, height: 0)
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder func shareView() -> some View {
        if let message = store.messageShareBinding {
            UIShareDialogView(activityItems: [
                ShareableMessage(
                    title: L10n.SendFeedback.Share.title,
                    message: message,
                    desc: L10n.SendFeedback.Share.desc
                ),
            ]) {
                store.send(.shareFinished)
            }
            // UIShareDialogView only wraps UIActivityViewController presentation
            // so frame is set to 0 to not break SwiftUI's layout
            .frame(width: 0, height: 0)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder func debugView(_ store: StoreOf<Root>) -> some View {
        VStack(alignment: .leading) {
            if store.destinationState.previousDestination == .home {
                ZashiButton(L10n.General.back) {
                    store.goToDestination(.home)
                }
                .frame(width: 150)
                .padding()
            }

            List {
                Section(header: Text(L10n.Root.Debug.title)) {
                    Button(L10n.Root.Debug.Option.exportLogs) {
                        store.send(.exportLogs(.start))
                    }
                    .disabled(store.exportLogsState.exportLogsDisabled)

#if DEBUG
                    Button(L10n.Root.Debug.Option.appReview) {
                        store.send(.debug(.rateTheApp))
                        if let currentScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            SKStoreReviewController.requestReview(in: currentScene)
                        }
                    }
#endif
                    
                    Button(L10n.Root.Debug.Option.copySeed) {
                        store.send(.debug(.copySeedToPasteboard))
                    }

                    Button(L10n.Root.Debug.Option.rescanBlockchain) {
                        store.send(.debug(.rescanBlockchain))
                    }

                    Button(L10n.Root.Debug.Option.nukeWallet) {
                        store.send(.initialization(.resetZashiRequest(true)))
                    }
                }
            }
            .confirmationDialog(
                store: store.scope(
                    state: \.$confirmationDialog,
                    action: \.confirmationDialog
                )
            )
        }
        .navigationBarTitle(L10n.Root.Debug.navigationTitle)
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        RootView(
            store: StoreOf<Root>(
                initialState: .initial
            ) {
                Root()
            },
            tokenName: "ZEC",
            networkType: .testnet
        )
    }
}

// MARK: - Binding

extension StoreOf<Root> {
    func bindingFor(_ path: Root.State.Path) -> Binding<Bool> {
        Binding<Bool>(
            get: { self.path == path },
            set: { self.path = $0 ? path : nil }
        )
    }
}

// MARK: Placeholders

extension Root.State {
    public static var initial: Self {
        .init(
            debugState: .initial,
            destinationState: .initial,
            exportLogsState: .initial,
            onboardingState: .initial,
            phraseDisplayState: .initial,
            //tabsState: .initial,
            walletConfig: .initial,
            welcomeState: .initial
        )
    }
}

extension Root {
    public static var placeholder: StoreOf<Root> {
        StoreOf<Root>(
            initialState: .initial
        ) {
            Root()
                //.logging()
        }
    }
}
