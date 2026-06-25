//
//  IPadSplitView.swift
//  Zashi
//
//  iPad-regular layout (NavigationSplitView), adapted from MacSplitView (docs/macos/) for touch + iOS-
//  native chrome — see docs/ipad/IPAD_SUPPORT_PLAN.md. Differences from Mac: native collapsible sidebar
//  (no fixed-width pin / traffic lights / Liquid Glass), native `.sheet` instead of MacCard, an adaptive
//  screen (no fixed window). Shown ONLY on iPad in regular width (gated by RootView); iPhone and
//  iPad-compact keep the existing iOS layout untouched. Rule iP-0: this file is `#if os(iOS)` and never
//  alters the iPhone path — the regular-width gate lives in RootView.
//

#if os(iOS)
import SwiftUI
import UIKit
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct IPadSplitView: View {
    // Seeded (not pinned) — iPad's sidebar is natively collapsible. Sourced from the single iPad sizing
    // namespace (Design.IPad) so the layout can be tuned from one place, like Design.Mac.
    private let sidebarWidth: CGFloat = Design.IPad.sidebarWidth

    @Environment(\.colorScheme) private var colorScheme
    @Shared(.appStorage(.sensitiveContent)) private var isSensitiveContentHidden = false
    @State private var selectedSection: PadSection = .activity
    // The section the DETAIL renders (vs `selectedSection`, the sidebar highlight). On a switch it goes
    // selected -> nil (one-frame blank) -> new, so the popped root never flashes and SwiftUI's path
    // reconcile (the comparisonTypeMismatch crash) has nothing to reconcile. Same #2a fix as Mac.
    @State private var detailSection: PadSection? = .activity
    @State private var hasInitialized = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    let store: StoreOf<Root>
    let tokenName: String
    let networkType: NetworkType

    var body: some View {
        WithPerceptionTracking {
            // Full-window takeovers (mirror MacSplitView + RootView's iOS path rendering): path-driven
            // flows that own the whole screen instead of the split. Each sets `path = nil` on close.
            switch store.path {
            case .addKeystoneHWWalletCoordFlow?:
                AddKeystoneHWWalletCoordFlowView(
                    store: store.scope(state: \.addKeystoneHWWalletCoordFlowState, action: \.addKeystoneHWWalletCoordFlow),
                    tokenName: tokenName
                )
            case .scanCoordFlow?:
                ScanCoordFlowView(
                    store: store.scope(state: \.scanCoordFlowState, action: \.scanCoordFlow),
                    tokenName: tokenName
                )
            case .walletBackup?:
                WalletBackupCoordFlowView(
                    store: store.scope(state: \.walletBackupCoordFlowState, action: \.walletBackupCoordFlow)
                )
            case .currencyConversionSetup?:
                NavigationStack {
                    CurrencyConversionSetupView(
                        store: store.scope(state: \.currencyConversionSetupState, action: \.currencyConversionSetup)
                    )
                }
            case .torSetup?:
                NavigationStack {
                    TorSetupView(store: store.scope(state: \.torSetupState, action: \.torSetup))
                }
            case .serverSwitch?:
                NavigationStack {
                    ServerSetupView(
                        store: store.scope(state: \.serverSetupState, action: \.serverSetup)
                    ) {
                        store.send(.backToHomeFromServerSwitchTapped)
                    }
                }
            default:
                splitView
            }
        }
    }

    // MARK: - Full-window flow detection (shared logic with Mac: scan #9 + broadcast lock #10)

    private var isScanActive: Bool {
        store.sendCoordFlowState.path.contains { $0.is(\.scan) }
            || store.swapAndPayCoordFlowState.path.contains { $0.is(\.scan) }
            || store.settingsState.path.contains { $0.is(\.scan) }
    }

    private var isBroadcastLocked: Bool {
        store.sendCoordFlowState.path.contains {
            $0.is(\.sending) || $0.is(\.sendResultPending) || $0.is(\.sendResultSuccess) || $0.is(\.sendResultFailure)
        } || store.swapAndPayCoordFlowState.path.contains {
            $0.is(\.sending) || $0.is(\.sendResultPending) || $0.is(\.sendResultSuccess) || $0.is(\.sendResultFailure)
        }
    }

    private var isFullWindowFlow: Bool { isScanActive || isBroadcastLocked }

    // MARK: - Split

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(sidebarWidth)
        } detail: {
            Group {
                if detailSection != nil {
                    rightPanel
                } else {
                    Asset.Colors.background.color.ignoresSafeArea()
                }
            }
            .id(detailSection)
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            guard !hasInitialized else { return }
            hasInitialized = true
            store.send(selectedSection.action)
            // Start the SmartBanner sync observation (on iPhone this comes via HomeView.onAppear, which
            // isn't in the split tree). The effect is cancellable(cancelInFlight:), so it's idempotent.
            store.send(.home(.smartBanner(.onAppear)))
        }
        .onChange(of: store.path) { newPath in
            if newPath == nil { store.send(selectedSection.action) }
        }
        // #9 (scan) + #10 (broadcast lock): collapse to detail-only so the flow owns the screen and the
        // user can't switch sections mid-broadcast. Restores on close.
        .onChange(of: isFullWindowFlow) { full in
            columnVisibility = full ? .detailOnly : .all
        }
        // Root-hosted sheets — HomeView isn't in the split tree (same as Mac), so the account-switch and
        // smart-banner sheets are hosted here. On iPad `.zashiSheet` is a native sheet (MacCard is Mac-only).
        .zashiSheet(isPresented: accountSwitchBinding) {
            WalletAccountsSheetView(store: store.scope(state: \.homeState, action: \.home))
        }
        .zashiSheet(isPresented: smartBannerHelpBinding) {
            SmartBannerHelpSheetView(
                store: store.scope(state: \.homeState.smartBannerState, action: \.home.smartBanner),
                tokenName: tokenName
            )
        }
        .zashiSheet(isPresented: syncTimeoutBinding) {
            SmartBannerSyncTimeoutSheetView(
                store: store.scope(state: \.homeState.smartBannerState, action: \.home.smartBanner)
            )
        }
    }

    private var accountSwitchBinding: Binding<Bool> {
        Binding(
            get: { store.homeState.accountSwitchRequest },
            set: { newValue in
                if !newValue && store.homeState.accountSwitchRequest {
                    store.send(.home(.accountSwitchTapped))
                }
            }
        )
    }

    private var smartBannerHelpBinding: Binding<Bool> {
        Binding(
            get: { store.homeState.smartBannerState.isSmartBannerSheetPresented },
            set: { newValue in
                if !newValue && store.homeState.smartBannerState.isSmartBannerSheetPresented {
                    store.send(.home(.smartBanner(.closeSheetTapped)))
                }
            }
        )
    }

    private var syncTimeoutBinding: Binding<Bool> {
        Binding(
            get: { store.homeState.smartBannerState.isSyncTimedOutSheetPresented },
            set: { newValue in
                if !newValue && store.homeState.smartBannerState.isSyncTimedOutSheetPresented {
                    store.send(.home(.smartBanner(.binding(.set(\.isSyncTimedOutSheetPresented, false)))))
                }
            }
        )
    }

    // MARK: - Sidebar

    // #2a (shared with Mac): clear EVERY section's NavigationStack to root before switching, and blank the
    // detail for one frame, so the cross-section path reconcile can't crash and the pop-to-root is hidden.
    private var sectionSelection: Binding<PadSection?> {
        Binding(
            get: { selectedSection },
            set: { newSection in
                guard let newSection, newSection != selectedSection else { return }
                store.send(.macResetSectionPaths)
                selectedSection = newSection
                detailSection = nil
                DispatchQueue.main.async { detailSection = newSection }
            }
        )
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                accountSwitcher
                    .padding(.bottom, 24)

                HStack(spacing: 0) {
                    Text(localizable: .generalBalance)
                        .zFont(.medium, size: 16, style: Design.Text.tertiary)
                    Spacer()
                    hideEyeButton
                }

                WalletBalancesView(
                    store: store.scope(state: \.homeState.walletBalancesState, action: \.home.walletBalances),
                    tokenName: tokenName,
                    couldBeHidden: true,
                    shortened: true,
                    leadingAligned: true
                )

                Divider()
                    .padding(.vertical, 12)
                    .opacity(0.5)

                SmartBannerView(
                    store: store.scope(state: \.homeState.smartBannerState, action: \.home.smartBanner),
                    tokenName: tokenName
                )
            }
            .padding(16)

            List(selection: sectionSelection) {
                ForEach(PadSection.allCases, id: \.self) { section in
                    HStack {
                        section.sectionIcon
                            .zImage(size: 16, style: Design.Text.primary)
                        Text(section.title)
                            .zFont(.medium, size: 14, style: Design.Text.primary)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("")
        .onChange(of: selectedSection) { section in
            store.send(section.action)
        }
    }

    @ViewBuilder private var accountSwitcher: some View {
        WithPerceptionTracking {
            if let account = store.homeState.selectedWalletAccount {
                Button {
                    store.send(.home(.accountSwitchTapped))
                } label: {
                    HStack(spacing: 0) {
                        account.vendor.icon()
                            .resizable()
                            .frame(width: 19, height: 19)
                            .background {
                                Circle()
                                    .fill(Design.Surfaces.bgAlt.color(colorScheme))
                                    .frame(width: 30, height: 30)
                            }
                        Text(account.vendor.name())
                            .zFont(.semiBold, size: 18, style: Design.Text.primary)
                            .padding(.leading, 14)
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Design.Text.primary.color(colorScheme))
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .background {
                        Capsule().fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var hideEyeButton: some View {
        WithPerceptionTracking {
            Button {
                $isSensitiveContentHidden.withLock { $0.toggle() }
            } label: {
                (isSensitiveContentHidden ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image)
                    .zImage(size: 22, color: Asset.Colors.primary.color)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Detail

    @ViewBuilder private var rightPanel: some View {
        WithPerceptionTracking {
            switch selectedSection {
            case .activity:
                TransactionsCoordFlowView(
                    store: store.scope(state: \.transactionsCoordFlowState, action: \.transactionsCoordFlow),
                    tokenName: tokenName
                )
            case .receive:
                ReceiveView(
                    store: store.scope(state: \.receiveState, action: \.receive),
                    networkType: networkType,
                    tokenName: tokenName
                )
            case .send:
                SendCoordFlowView(
                    store: store.scope(state: \.sendCoordFlowState, action: \.sendCoordFlow),
                    tokenName: tokenName
                )
            case .pay, .swap:
                SwapAndPayCoordFlowView(
                    store: store.scope(state: \.swapAndPayCoordFlowState, action: \.swapAndPayCoordFlow),
                    tokenName: tokenName
                )
            case .vote:
                VotingCoordFlowView(
                    store: store.scope(state: \.votingCoordFlowState, action: \.votingCoordFlow)
                )
            case .more:
                SettingsView(
                    store: store.scope(state: \.settingsState, action: \.settings)
                )
            }
        }
    }
}

// Mirror of MacSection (consolidate into one shared enum in Phase iP-7). Pure data — the `.action`s are
// the same Root actions the iPhone Home buttons send, so the store graph is reused unchanged.
private enum PadSection: CaseIterable {
    case activity, receive, send, pay, swap, vote, more

    var title: String {
        switch self {
        case .activity: return String(localizable: .generalActivity)
        case .receive: return String(localizable: .tabsReceive)
        case .send: return String(localizable: .tabsSend)
        case .pay: return String(localizable: .swapAndPayPay)
        case .swap: return String(localizable: .swapAndPaySwap)
        case .vote: return String(localizable: .coinVoteSidebarTitle)
        case .more: return String(localizable: .settingsTitle)
        }
    }

    var sectionIcon: Image {
        switch self {
        case .activity: return Asset.Assets.Icons.activity.image
        case .receive: return Asset.Assets.Icons.received.image
        case .send: return Asset.Assets.Icons.sent.image
        case .pay: return Asset.Assets.Icons.pay.image
        case .swap: return Asset.Assets.Icons.swap.image
        case .vote: return Asset.Assets.Icons.checkVerified.image
        case .more: return Asset.Assets.Icons.dotsMenu.image
        }
    }

    var action: Root.Action {
        switch self {
        case .activity: return .home(.seeAllTransactionsTapped)
        case .receive: return .home(.receiveTapped)
        case .send: return .home(.sendTapped)
        case .pay: return .home(.payWithNearTapped)
        case .swap: return .home(.swapWithNearTapped)
        case .vote: return .macVoteSectionSelected
        case .more: return .home(.settingsTapped)
        }
    }
}
#endif
