import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct RootView: View {
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.colorScheme) var colorScheme
    @State var covered = false
    
    @PlatformBindable var store: StoreOf<Root>
    let tokenName: String
    let networkType: NetworkType

    init(store: StoreOf<Root>, tokenName: String, networkType: NetworkType) {
        self.store = store
        self.tokenName = tokenName
        self.networkType = networkType
    }
    
    var body: some View {
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
                    .zashiStackNavigationStyle()
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
                    .zashiStackNavigationStyle()
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
                    .zashiStackNavigationStyle()
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }

                case .home:
#if os(macOS)
                    // STARTUP FIX: the splash is a CONTENT overlay, but MacSplitView's window toolbar
                    // (Activity's search + filter) is chrome ABOVE the overlay, so those items leak
                    // through during the splash. Don't build the split until the splash is gone
                    // (`splashAppeared == true`); show the splash colour beneath meanwhile so the
                    // tear-away reveals a seamless background, and the toolbar only ever exists after.
                    Group {
                        if store.splashAppeared {
                            MacSplitView(store: store, tokenName: tokenName, networkType: networkType)
                        } else {
                            Asset.Colors.splash.color.ignoresSafeArea()
                        }
                    }
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }
#else
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
                        .onChange(of: store.path) { value in
                            if value == nil {
                                store.send(.home(.onAppear))
                            } else {
                                store.send(.home(.onDisappear))
                            }
                        }
                        
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
                                WalletBackupCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.walletBackupCoordFlowState,
                                            action: \.walletBackupCoordFlow)
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .migrationCoordFlow {
                                // `MigrationCoordFlowView` owns its own `NavigationStack` (Entry is
                                // its root), so it is presented bare — same shape as the other
                                // CoordFlows above, not wrapped like the single-screen destinations.
                                MigrationCoordFlowView(
                                    store:
                                        store.scope(
                                            state: \.migrationCoordFlowState,
                                            action: \.migrationCoordFlow)
                                )
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .currencyConversionSetup {
                                NavigationStack {
                                    CurrencyConversionSetupView(
                                        store:
                                            store.scope(
                                                state: \.currencyConversionSetupState,
                                                action: \.currencyConversionSetup)
                                    )
                                }
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .torSetup {
                                NavigationStack {
                                    TorSetupView(
                                        store:
                                            store.scope(
                                                state: \.torSetupState,
                                                action: \.torSetup)
                                    )
                                }
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .serverSwitch {
                                NavigationStack {
                                    ServerSetupView(
                                        store:
                                            store.scope(
                                                state: \.serverSetupState,
                                                action: \.serverSetup
                                            )
                                    ) {
                                        store.send(.backToHomeFromServerSwitchTapped)
                                    }
                                }
                                .transition(.move(edge: .trailing))
                                .zIndex(1)
                            } else if path == .swapAndPayCoordFlow {
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
#endif

                case .onboarding:
                    // The onboarding landing is a full-bleed HERO (logo + title + CTAs on the gradient),
                    // the same launch-sequence family as .welcome — NOT a capped single-view form. The old
                    // macOSSingleViewLayout() framed it (gradient included) to a 460pt column on the app
                    // background — the boxed "card" on a dark surround. The onboarding gradient must
                    // full-bleed the window, so the wrapper is gone (Rule #8a). Let it fill.
                    RestoreWalletCoordFlowView(
                        store: store.scope(
                            state: \.onboardingState,
                            action: \.onboarding
                        )
                    )
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }

                case .ironwoodAnnouncement:
                    IronwoodAnnouncementView(
                        store: store.scope(
                            state: \.ironwoodAnnouncementState,
                            action: \.ironwoodAnnouncement
                        )
                    )
                    .overlayedWithSplash(store.splashAppeared) {
                        store.send(.splashRemovalRequested)
                    }

                case .welcome:
                    // The welcome screen is a full-bleed splash (colour + centered logo), NOT a capped
                    // single-view form. The macOSSingleViewLayout() box wrapper (since removed, Rule #8a)
                    // framed it to a 460pt column on the app background — the "green frame, not full
                    // window" seen at launch. Let it fill.
                    WelcomeView(
                        store: store.scope(
                            state: \.welcomeState,
                            action: \.welcome
                        )
                    )
                }
            }
            .onOpenURL(perform: { store.goToDeeplink($0) })
            // Zodl Bridge review/confirm card (docs/macos/ZODL_BRIDGE_SPEC.md BR-4):
            // presented via the house MacCard at the Root root — global over the whole
            // window, above MacSplitView (MODALS.md Rule #5). Backdrop dismissal maps
            // to the child's close action so the one-in-flight gate re-opens.
            .zashiSheet(
                isPresented: Binding(
                    get: { store.bridgeRequestState != nil },
                    set: { if !$0 { store.send(.bridge(.child(.closeTapped))) } }
                )
            ) {
                Group {
                    if let bridgeStore = store.scope(state: \.bridgeRequestState, action: \.bridge.child) {
                        BridgeRequestView(store: bridgeStore, tokenName: tokenName)
                    }
                }
            }
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
            .zashiFullScreenCover(
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
        // macOS: the single root card host — renders any `.zashiSheet` / `.zashiSelectorSheet` (which write
        // their content to a `MacCardCoordinator` injected via `@Environment` — down-propagation, since a
        // PreferenceKey would be swallowed by the enclosing NavigationStack/NavigationSplitView) as ONE
        // centered, dimmed card over the whole window, above the content cap (`Design.Mac.viewCapWidth`).
        // No-op on iOS (native `.sheet`).
        .macCardHost()
    }
}

private extension RootView {
    @ViewBuilder func shareLogsView(_ store: StoreOf<Root>) -> some View {
        if store.exportLogsState.isSharingLogs {
            UIShareDialogView(
                activityItems: store.exportLogsState.zippedLogsURLs,
                completion: {
                    store.send(.exportLogs(.shareFinished))
                },
                onDismiss: {
                    store.send(.exportLogs(.shareSheetClosed))
                }
            )
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
                    title: String(localizable: .sendFeedbackShareTitle),
                    message: message,
                    desc: String(localizable: .sendFeedbackShareDesc)
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
    static var initial: Self {
        .init(
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
    // StoreOf<Root>.init is @MainActor (TCA 1.14+); factory must be too.
    @MainActor
    static var placeholder: StoreOf<Root> {
        StoreOf<Root>(
            initialState: .initial
        ) {
            Root()
                //.logging()
        }
    }
}
