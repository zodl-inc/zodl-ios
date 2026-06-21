//
//  MacSplitView.swift
//  Zashi
//
//  macOS-only two-column split (Mail-style): left control rail + right content panel.
//
//  Approach A — the sidebar drives the existing `Root.path` via the *same* `Home` actions the
//  iOS HomeView buttons send (RootCoordinator already does `state.X = .initial` + `state.path =`),
//  and the right panel renders the *existing* path-destination views. No new reducer/selection
//  state; reset-on-switch and in-panel back arrows come free from the existing coordinator.
//

#if os(macOS)
import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct MacSplitView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Shared(.appStorage(.sensitiveContent)) private var isSensitiveContentHidden = false
    @State private var selectedSection: MacSection = .activity
    @State private var hasInitialized = false
    let store: StoreOf<Root>
    let tokenName: String
    let networkType: NetworkType

    var body: some View {
        WithPerceptionTracking {
            // Keystone hardware-wallet setup takes over the whole window (multi-step flow + camera
            // QR scan), then returns to the split when it finishes/cancels (path moves away from it).
            if store.path == .addKeystoneHWWalletCoordFlow {
                AddKeystoneHWWalletCoordFlowView(
                    store: store.scope(state: \.addKeystoneHWWalletCoordFlowState, action: \.addKeystoneHWWalletCoordFlow),
                    tokenName: tokenName
                )
            } else {
                splitView
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Blank the title with an empty string — do NOT use `.toolbar(removing: .title)`,
                // which kills the toolbar's center anchor and collapses `.primaryAction` items to
                // the leading edge. An empty title keeps trailing placement intact.
                .navigationTitle("")
                // Seamless top bar (no hard separator line) like Mail/Messages.
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .onAppear {
            // Initialize the default peer-root (Activity) once. Section switches are handled
            // by the sidebar's `selectedSection` onChange; `store.path` is NOT used to drive
            // the macOS panel — each section is an independent peer-root, not a pushed screen.
            if !hasInitialized {
                hasInitialized = true
                store.send(selectedSection.action)
            }
        }
        // Account-switch sheet (account list + Keystone connect). Presented here on macOS,
        // since HomeView — which hosts it on iOS — is not in the macOS view tree.
        .zashiSheet(
            isPresented: Binding(
                get: { store.homeState.accountSwitchRequest },
                set: { newValue in
                    // Only toggle closed when it is actually open, to avoid a re-open race if a
                    // selection inside the sheet already set the flag false.
                    if !newValue && store.homeState.accountSwitchRequest {
                        store.send(.home(.accountSwitchTapped))
                    }
                }
            )
        ) {
            WalletAccountsSheetView(store: store.scope(state: \.homeState, action: \.home))
        }
    }

    // MARK: - Left rail (native sidebar material — follows system light/dark)

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Header (account + eye + balance + sync) lives OUTSIDE the List: Liquid Glass is
            // swallowed inside List(.sidebar) rows, so these controls sit in a VStack on the
            // sidebar material where `.glassEffect` actually renders.
            VStack(alignment: .leading, spacing: 0) {
                // Full-width account selector (glass capsule).
                accountSwitcher
                    .padding(.bottom, 24)

                // Balance label + hide-balances eye.
                HStack(spacing: 0) {
                    Text("Balance")
                        .zFont(.medium, size: 16, style: Design.Text.tertiary)
                    Spacer()
                    hideEyeButton
                }

                // Leading ZEC amount + currency.
                WalletBalancesView(
                    store: store.scope(state: \.homeState.walletBalancesState, action: \.home.walletBalances),
                    tokenName: tokenName,
                    couldBeHidden: true,
                    shortened: true,
                    leadingAligned: true
                )

                Divider()
                    .padding(.vertical, 12)
                    .padding(.horizontal, -14)
                    .opacity(0.5)

                // Smart banner — a purple card on macOS that reveals/dismisses in place.
                SmartBannerView(
                    store: store.scope(state: \.homeState.smartBannerState, action: \.home.smartBanner),
                    tokenName: tokenName
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            // Navigation — native selectable rows; the native selection highlight adapts to light/dark.
            List(selection: $selectedSection) {
                ForEach(MacSection.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            // Grey selection instead of the system-accent blue.
            .tint(.gray)
            // Fixed-size window with few options — scrolling is pointless and looks odd under the
            // fixed header.
            .scrollDisabled(true)
        }
        // Drop the system "hide sidebar" toolbar button — the rail is always visible.
        .toolbar(removing: .sidebarToggle)
        .onChange(of: selectedSection) { _, section in
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
                    .macGlassCapsule()
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
                // Plain eye in the Balance row (per the mockup) — no glass capsule here.
                (isSensitiveContentHidden ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image)
                    .zImage(size: 22, color: Asset.Colors.primary.color)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Right panel

    @ViewBuilder private var rightPanel: some View {
        WithPerceptionTracking {
            // Peer-roots: the LOCAL selection picks the section view directly. No `store.path`,
            // no pushing one section onto another — each is its own independent root. Switching
            // sections resets the chosen section (its `Home` action sets state = `.initial`).
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
                // Same flow, EXACT_INPUT vs EXACT_OUTPUT — the `Home` action flips the mode.
                SwapAndPayCoordFlowView(
                    store: store.scope(state: \.swapAndPayCoordFlowState, action: \.swapAndPayCoordFlow),
                    tokenName: tokenName
                )
            case .more:
                SettingsView(
                    store: store.scope(state: \.settingsState, action: \.settings)
                )
            }
        }
    }
}

private enum MacSection: CaseIterable {
    case activity, receive, send, pay, swap, more

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .receive: return String(localizable: .tabsReceive)
        case .send: return String(localizable: .tabsSend)
        case .pay: return String(localizable: .swapAndPayPay)
        case .swap: return String(localizable: .swapAndPaySwap)
        case .more: return "More"
        }
    }

    var systemImage: String {
        switch self {
        case .activity: return "house"
        case .receive: return "arrow.down.circle"
        case .send: return "arrow.up.circle"
        case .pay: return "creditcard"
        case .swap: return "arrow.2.squarepath"
        case .more: return "ellipsis"
        }
    }

    var action: Root.Action {
        switch self {
        case .activity: return .home(.seeAllTransactionsTapped)
        case .receive: return .home(.receiveTapped)
        case .send: return .home(.sendTapped)
        case .pay: return .home(.payWithNearTapped)
        case .swap: return .home(.swapWithNearTapped)
        case .more: return .home(.settingsTapped)
        }
    }
}

private extension View {
    /// Wrap a sidebar control in a Liquid Glass capsule (macOS 26+); no-op on older systems.
    @ViewBuilder func macGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self
        }
    }

    /// Wrap a single-icon sidebar control in a Liquid Glass circle (macOS 26+); no-op otherwise.
    @ViewBuilder func macGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self
        }
    }
}
#endif
