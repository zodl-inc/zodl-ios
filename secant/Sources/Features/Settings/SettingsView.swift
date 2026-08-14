import SwiftUI
import Combine
import ComposableArchitecture

struct SettingsView: View {
    @PlatformBindable var store: StoreOf<Settings>
    
    init(store: StoreOf<Settings>) {
        self.store = store
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                VStack(spacing: 0) {
                    List {
                        Group {
                            ActionRow(
                                icon: Asset.Assets.Icons.user.image,
                                title: String(localizable: .settingsAddressBook)
                            ) {
                                store.send(.addressBookAccessCheck)
                            }
                            .accessibilityIdentifier(AccessibilityID.Settings.addressBook)


                            if store.isEnoughFreeSpaceMode {
                                ActionRow(
                                    icon: Asset.Assets.Icons.currencyDollar.image,
                                    title: String(localizable: .currencyConversionTitle),
                                ) {
                                    store.send(.currencyConversionTapped)
                                }
                            }

                            #if VOTING_ENABLED
#if !os(macOS)
                            // macOS hosts voting in the sidebar (Beta: Vote); the Settings entry is iOS-only.
                            ActionRow(
                                icon: Asset.Assets.Icons.checkVerified.image,
                                title: String(localizable: .settingsCoinholderPolling)
                            ) {
                                store.send(.coinholderPollingTapped)
                            }
#endif
                            #endif

                            ActionRow(
                                icon: Asset.Assets.Icons.settings.image,
                                title: String(localizable: .settingsAdvanced)
                            ) {
                                store.send(.advancedSettingsTapped)
                            }
                            
                            ActionRow(
                                icon: Asset.Assets.Icons.magicWand.image,
                                title: String(localizable: .settingsWhatsNew)
                            ) {
                                store.send(.whatsNewTapped)
                            }
                            
                            ActionRow(
                                icon: Asset.Assets.infoOutline.image,
                                title: String(localizable: .settingsAbout)
                            ) {
                                store.send(.aboutTapped)
                            }
                            
                            ActionRow(
                                icon: Asset.Assets.Icons.messageSmile.image,
                                title: String(localizable: .settingsFeedback),
                                divider: false
                            ) {
                                store.send(.sendUsFeedbackTapped)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Asset.Colors.background.color)
                        .listRowSeparator(.hidden)
                    }
                    .padding(.top, 24)
                    .padding(.horizontal, 4)
                    .onAppear { store.send(.onAppear) }
                    
                    Spacer()

                    Group {
                        Asset.Assets.zashiLogo.image
                            .zImage(width: 41, height: 41, color: Asset.Colors.primary.color)
                            .padding(.bottom, 7)
                        
                        Asset.Assets.zashiTitle.image
                            .zImage(width: 73, height: 20, color: Asset.Colors.primary.color)
                            .padding(.bottom, 16)
                    }
                    .onLongPressGesture {
                        store.send(.enableRecoverFundsMode)
                    }
                    .onTapGesture(count: 3) {
                        store.send(.enableEnhanceTransactionMode)
                    }
                    
                    Text(localizable: .settingsVersion(store.appVersion, store.appBuild))
                        .zFont(size: 16, style: Design.Text.tertiary)
                        .padding(.bottom, 24)
                }
                .listStyle(.plain)
                .zashiHideListBackground()
                .applyScreenBackground()
                .zashiSectionRootBack { store.send(.backToHomeTapped) }
                .screenTitle(String(localizable: .settingsTitle))
            } destination: { store in
                switch store.case {
                case let .about(store):
                    AboutView(store: store)
                case let .accountHWWalletSelection(store):
                    AccountsSelectionView(store: store)
                case let .addKeystoneHWWallet(store):
                    AddKeystoneHWWalletView(store: store)
                case let .addressBook(store):
                    AddressBookView(store: store)
                case let .addressBookContact(store):
                    AddressBookContactView(store: store)
                case let .advancedSettings(store):
                    AdvancedSettingsView(store: store)
                case let .chooseServerSetup(store):
                    ServerSetupView(store: store)
                case let .disconnectHWWallet(store):
                    DisconnectHWWalletView(store: store)
                case let .currencyConversionSetup(store):
                    CurrencyConversionSetupView(store: store)
                case let .exportPrivateData(store):
                    PrivateDataConsentView(store: store)
                case let .exportTransactionHistory(store):
                    ExportTransactionHistoryView(store: store)
                case let .migrationRestart(store):
                    MigrationRestartView(store: store)
                case let .recoveryPhrase(store):
                    RecoveryPhraseDisplayView(store: store)
                case let .resyncEstimateBirthdaysDate(store):
                    WalletBirthdayEstimateDateView(store: store)
                case let .resyncEstimatedBirthday(store):
                    WalletBirthdayEstimatedHeightView(store: store)
                case let .resyncRestoreInfo(store):
                    RestoreInfoView(store: store)
                case let .resyncWallet(store):
                    ResyncWalletView(store: store)
                case let .resyncWalletBirthday(store):
                    WalletBirthdayView(store: store)
                case let .resetZashi(store):
                    DeleteWalletView(store: store)
                case let .scan(store):
                    ScanView(store: store)
                case let .sendUsFeedback(store):
                    SendFeedbackView(store: store)
                case let .torSetup(store):
                    TorSetupView(store: store)
                case let .whatsNew(store):
                    WhatsNewView(store: store)
                }
            }
            // macOS: the Settings NavigationStack hosts AddressBook, whose List must be full-width so its
            // (visible) scroll indicator sits at the window edge, not the 530-column edge. Move the cap OFF
            // the stack (`capped: false`); the Settings root list self-caps (its own background above) and
            // every pushed destination self-caps too, so only AddressBook's full-width List is affected.
            // iOS unaffected — `capped: false` collapses to the same background-only path there (Rule #11).
            .applyScreenBackground(capped: false)
            .zashiSheet(isPresented: $store.isInRecoverFundsMode) {
                recoverFundsSheetContent()
            }
            .zashiSheet(isPresented: $store.isInEnhanceTransactionMode) {
                enhanceTransactionSheetContent()
            }
            .zashiSheet(isPresented: $store.isResyncHelpSheetPresented) {
                resyncHelpSheetContent()
            }
            #if VOTING_ENABLED
            .zashiFullScreenCover(
                item: $store.scope(state: \.votingCoordFlow, action: \.votingCoordFlow)
            ) { votingStore in
                // fullScreenCover content is an escaping closure — needs its
                // own WithPerceptionTracking so reads inside the presented
                // store register with TCA's observation system.
                WithPerceptionTracking {
                    VotingCoordFlowView(store: votingStore)
                }
            }
            #endif
        }
    }
    
    @ViewBuilder private func recoverFundsSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .recoverFundsTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            Text(localizable: .recoverFundsMsg)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
            
            ZashiTextField(
                addressFont: true,
                text: $store.addressToRecoverFunds,
                placeholder: String(localizable: .recoverFundsPlaceholder),
                title: String(localizable: .recoverFundsFieldTitle)
            )
            .padding(.bottom, 32)

            if !store.isTorOn {
                HStack(alignment: .top, spacing: 0) {
                    Asset.Assets.infoOutline.image
                        .zImage(size: 20, style: Design.Utility.WarningYellow._500)
                        .padding(.trailing, 12)
                    
                    Text(localizable: .recoverFundsTor)
                        .zFont(size: 12, style: Design.Utility.WarningYellow._700)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 12)
            }
            
            ZashiButton(String(localizable: .recoverFundsBtn)) {
                store.send(.checkFundsForAddress(store.addressToRecoverFunds))
            }
            .disabled(store.addressToRecoverFunds.isEmpty || !store.isTorOn)
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func resyncHelpSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .restoreWalletHelpTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            HintBox(String(localizable: .walletBirthdayHelpDesc), style: .markdown)
                .padding(.bottom, 32)
            
            ZashiButton(String(localizable: .restoreInfoGotIt)) {
                store.send(.closeResyncHelpSheetTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func enhanceTransactionSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .enhanceTransactionTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)

            Text(localizable: .enhanceTransactionMsg)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
            
            ZashiTextField(
                addressFont: true,
                text: $store.txidToEnhance,
                placeholder: String(localizable: .enhanceTransactionPlaceholder),
                title: String(localizable: .enhanceTransactionFieldTitle)
            )
            .padding(.bottom, 32)

            ZashiButton(String(localizable: .enhanceTransactionBtn)) {
                store.send(.fetchDataForTxid(store.txidToEnhance))
            }
            .disabled(store.txidToEnhance.isEmpty)
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

extension Image {
    func seekOutline(_ colorScheme: ColorScheme) -> some View {
        self
            .resizable()
            .frame(width: 20, height: 20)
            .background { Circle().fill(Design.Surfaces.bgPrimary.color(colorScheme)).frame(width: 26, height: 26) }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        SettingsView(store: .placeholder)
    }
}

// MARK: Placeholders

extension Settings.State {
    static var initial: Settings.State { Settings.State() }
}

extension StoreOf<Settings> {
    @MainActor static let placeholder = StoreOf<Settings>(
        initialState: .initial
    ) {
        Settings()
    }
}
