//
//  MacSplitView.swift
//  Zashi
//
//  macOS-only two-column split (Mail-style): full-height sidebar + content detail, built on the
//  native `NavigationSplitView` per the 4-rule layout foundation (see docs/macos/LAYOUT_FOUNDATION.md,
//  proven in ~/Downloads/testApp):
//    #1 sidebar visuals — native split; a `ToolbarSpacer` on button-less screens keeps the traffic
//       lights inside the sidebar with no glass bubble.
//    #2 navigation — per-section CoordFlow `NavigationStack`s in `Group { switch }.id(selectedSection)`;
//       push/pop/pop-to-root/switch with no crash (the `.id` teardown resets the old stack to root).
//    #3 toolbar rendering — never style buttons above the toolbar; the system draws the capsules.
//    #4 sidebar sizing — scrollable list (fits any window height) + a FIXED, non-draggable width
//       (`FixedSidebarWidth` pins the NSSplitViewItem and re-pins on every switch).
//
//  The sidebar still drives the existing `Root.path` via the same `Home` actions the iOS buttons send
//  (RootCoordinator does `state.X = .initial` + `state.path =`); a handful of `Root.path` flows take
//  over the whole window (Keystone setup + the smart-banner destinations).
//

#if os(macOS)
import SwiftUI
import AppKit
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct MacSplitView: View {
    // RULE #4: the sidebar is a fixed width — never resizable, never remembered.
    private let sidebarWidth: CGFloat = 232

    @Environment(\.colorScheme) private var colorScheme
    @Shared(.appStorage(.sensitiveContent)) private var isSensitiveContentHidden = false
    @State private var selectedSection: MacSection = .activity
    @State private var hasInitialized = false
    // RULE #9: hide the sidebar while scan is showing (scan must be a full-window single view).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    let store: StoreOf<Root>
    let tokenName: String
    let networkType: NetworkType

    var body: some View {
        WithPerceptionTracking {
            // A few `Root.path` flows take over the whole window instead of the split. The macOS panel
            // renders the selected *section*, not `store.path` (see `splitView`), so without this these
            // path-driven flows would be invisible on macOS: Keystone HW-wallet setup (multi-step +
            // camera) and the smart-banner destinations (wallet backup, currency-conversion setup, Tor
            // setup, server switch — reached from the sidebar banner's CTAs / tap). Each sets
            // `path = nil` on close, and the `onChange(of: store.path)` below returns us to the split.
            // Scopes mirror RootView's iOS path rendering.
            switch store.path {
            case .addKeystoneHWWalletCoordFlow?:
                AddKeystoneHWWalletCoordFlowView(
                    store: store.scope(state: \.addKeystoneHWWalletCoordFlowState, action: \.addKeystoneHWWalletCoordFlow),
                    tokenName: tokenName
                )
            case .scanCoordFlow?:
                // RULE #9: scan is a full-window SINGLE view — sidebar hidden, never overlaid. Rendered
                // here as a `store.path` takeover (bypasses the split) like the other full-window flows.
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
                    TorSetupView(
                        store: store.scope(state: \.torSetupState, action: \.torSetup)
                    )
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

    // RULE #9: scan is pushed inside the Send / Pay-Swap / More section flows (their `.scan` path
    // element), which on macOS renders in the split detail with the sidebar still visible. Detect it
    // so we collapse the sidebar (below) and let scan own the whole window — nothing overriding it.
    private var isScanActive: Bool {
        store.sendCoordFlowState.path.contains { $0.is(\.scan) }
            || store.swapAndPayCoordFlowState.path.contains { $0.is(\.scan) }
            || store.settingsState.path.contains { $0.is(\.scan) }
    }

    private var splitView: some View {
        // RULE #1/#2: the NATIVE split — it owns the chrome (traffic lights inside the sidebar, the
        // unified glass toolbar). No manual HStack, no SidebarVibrancyView, no title-bar configurator;
        // fighting SwiftUI's window ownership at the view level crashes or gets overridden.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                // RULE #4: seed the initial width; `FixedSidebarWidth` pins the underlying
                // NSSplitViewItem (single-value column width still lets the divider drag) and re-pins
                // on every section switch (SwiftUI re-asserts a resizable width on each body re-run).
                .navigationSplitViewColumnWidth(sidebarWidth)
                .toolbar(removing: .sidebarToggle)
                .background(FixedSidebarWidth(width: sidebarWidth, trigger: selectedSection))
        } detail: {
            rightPanel
                // RULE #2: distinct identity per section → switching FULLY tears down the previous
                // section's NavigationStack (reset to root) instead of the detail column reconciling
                // two mismatched path types.
                .id(selectedSection)
                .navigationTitle("")
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .onAppear {
            // Initialize the default peer-root (Activity) once. Section switches are handled by the
            // sidebar's `selectedSection` onChange; `store.path` is NOT used to drive the panel.
            if !hasInitialized {
                hasInitialized = true
                store.send(selectedSection.action)
                // Start the SmartBanner's sync observation. On iOS this is sent by
                // HomeView.onAppear → Home.onAppear → `.smartBanner(.onAppear)`. HomeView isn't in the
                // macOS tree, so without this the banner never sees sync state. The effect is
                // `.cancellable(cancelInFlight: true)`, so this is idempotent.
                store.send(.home(.smartBanner(.onAppear)))
            }
        }
        .onChange(of: store.path) { _, newPath in
            // A flow that dismisses itself by setting `path = nil` (a finished sub-flow) should return
            // the current section to its root. Re-initialize the selected section.
            if newPath == nil {
                store.send(selectedSection.action)
            }
        }
        // RULE #9: while scan is showing in any section flow, collapse to detail-only so the sidebar is
        // hidden and scan owns the whole window — nothing overrides it. Restores when scan dismisses.
        .onChange(of: isScanActive) { _, scanning in
            columnVisibility = scanning ? .detailOnly : .all
        }
        // Account-switch sheet (account list + Keystone connect). Hosted here on macOS, since HomeView
        // — which hosts it on iOS — is not in the macOS view tree.
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

    // MARK: - Left rail (native NavigationSplitView sidebar — material + lights inside come for free)

    // CRASH FIX (AnyNavigationPath.comparisonTypeMismatch): intercept the sidebar selection to pop EVERY
    // section's NavigationStack to root BEFORE switching. SwiftUI's NavigationSplitView reconciles the
    // detail column's nav state across a section switch; a PUSHED path (e.g. a transaction detail open in
    // Activity) of a different type than the incoming section triggers a try! crash in NavigationColumnState
    // — the `.id(selectedSection)` resets the CONTENT but not that column nav state. Clearing the paths
    // first = nothing to reconcile. We keep the native split layout; the trade-off is the outgoing section
    // resets to root (the intended pop-to-root behaviour).
    private var sectionSelection: Binding<MacSection> {
        Binding(
            get: { selectedSection },
            set: { newSection in
                guard newSection != selectedSection else { return }
                LoggerProxy.event("[macOS nav] section \(selectedSection) -> \(newSection): clearing section paths (avoid comparisonTypeMismatch)")
                store.send(.macResetSectionPaths)
                selectedSection = newSection
            }
        )
    }

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

            // Navigation — native selectable rows. The native (system-accent) selection highlight is
            // fine for Beta; the custom-grey attempts were wider than native and had render latency.
            List(selection: sectionSelection) {
                ForEach(MacSection.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            // Let the sidebar vibrancy material show through uniformly (header + list share one
            // material) instead of the List drawing its own opaque background.
            .scrollContentBackground(.hidden)
            // RULE #4: do NOT disable scrolling — the list must scroll if rows ever overflow so the
            // sidebar fits any window height (today there are few rows, so it won't scroll).
        }
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
                .zashiPlainButtonStyle()
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
            .zashiPlainButtonStyle()
        }
    }

    // MARK: - Right panel

    @ViewBuilder private var rightPanel: some View {
        WithPerceptionTracking {
            // Peer-roots: the LOCAL selection picks the section view directly. No `store.path`, no
            // pushing one section onto another — each is its own independent root. Switching sections
            // resets the chosen section (its `Home` action sets state = `.initial`).
            //
            // RULE #1: sections whose ROOT has no toolbar buttons get a `.macSidebarToolbarSpacer()` so
            // the traffic lights stay inside the sidebar (Activity already has search + filter, so it
            // needs none). The spacer sits at trailing; a pushed screen's back button sits at leading,
            // so they never collide.
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
                .macSidebarToolbarSpacer()
            case .send:
                SendCoordFlowView(
                    store: store.scope(state: \.sendCoordFlowState, action: \.sendCoordFlow),
                    tokenName: tokenName
                )
                .macSidebarToolbarSpacer()
            case .pay, .swap:
                // Same flow, EXACT_INPUT vs EXACT_OUTPUT — the `Home` action flips the mode.
                SwapAndPayCoordFlowView(
                    store: store.scope(state: \.swapAndPayCoordFlowState, action: \.swapAndPayCoordFlow),
                    tokenName: tokenName
                )
                .macSidebarToolbarSpacer()
            case .vote:
                // Beta: Coinholder Voting as a peer-root (its own NavigationStack), rendered in the
                // detail like Send/Pay. iOS still presents it as a popover from Settings.
                VotingCoordFlowView(
                    store: store.scope(state: \.votingCoordFlowState, action: \.votingCoordFlow)
                )
                .macSidebarToolbarSpacer()
            case .more:
                SettingsView(
                    store: store.scope(state: \.settingsState, action: \.settings)
                )
                .macSidebarToolbarSpacer()
            }
        }
    }
}

private enum MacSection: CaseIterable {
    case activity, receive, send, pay, swap, vote, more

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .receive: return String(localizable: .tabsReceive)
        case .send: return String(localizable: .tabsSend)
        case .pay: return String(localizable: .swapAndPayPay)
        case .swap: return String(localizable: .swapAndPaySwap)
        case .vote: return "Beta: Vote"
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
        case .vote: return "hand.raised"
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
        case .vote: return .macVoteSectionSelected
        case .more: return .home(.settingsTapped)
        }
    }
}

/// RULE #4: SwiftUI's `navigationSplitViewColumnWidth` only seeds the INITIAL width and leaves the
/// divider draggable (and macOS remembers a dragged width across launches). Reach the underlying
/// `NSSplitViewItem` and pin `minimumThickness == maximumThickness` (which actually stops the
/// resize), disable collapse, and clear the autosave. SwiftUI re-asserts a resizable width on every
/// `body` re-run (e.g. a section switch), so `trigger` (the selection) makes `updateNSView` fire and
/// re-apply the pin each time.
private struct FixedSidebarWidth: NSViewRepresentable {
    let width: CGFloat
    var trigger: MacSection

    func makeNSView(context: Context) -> NSView { PinView(width: width) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PinView)?.schedulePin()
    }

    final class PinView: NSView {
        let width: CGFloat
        init(width: CGFloat) { self.width = width; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedulePin()
        }

        func schedulePin() {
            guard window != nil else { return }
            // The split controller may not be in the responder chain yet, and SwiftUI re-asserts a
            // resizable column width on later body passes — so retry across a few runloop turns (and
            // re-pin on every update). Deferred so we run AFTER SwiftUI applies its width this cycle.
            attemptPin(retriesLeft: 6)
        }

        private func attemptPin(retriesLeft: Int) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.pinSidebar(), retriesLeft > 0 {
                    self.attemptPin(retriesLeft: retriesLeft - 1)
                }
            }
        }

        /// Forces the sidebar to exactly `width`. The CONSTANT is authoritative — never a persisted
        /// or restored width. SwiftUI's `NavigationSplitView` autosaves the sidebar width under an
        /// "NSSplitView Subview Frames …" key and RESTORES it on launch; left alone that remembered
        /// width overrides the constant forever (ship 320, later change to 300 → existing users keep
        /// 320). We purge that persisted state, stop new saves, and slam the divider every pin.
        @discardableResult
        private func pinSidebar() -> Bool {
            // Find the enclosing NSSplitView.
            var view: NSView? = self
            while let cur = view, !(cur is NSSplitView) { view = cur.superview }
            guard let splitView = view as? NSSplitView else { return false }
            // Find its NSSplitViewController via the responder chain.
            var responder: NSResponder? = splitView
            while let r = responder {
                if let controller = r as? NSSplitViewController,
                   let sidebarItem = controller.splitViewItems.first {
                    sidebarItem.minimumThickness = width
                    sidebarItem.maximumThickness = width
                    sidebarItem.canCollapse = false
                    splitView.autosaveName = ""            // stop persisting the width this session
                    Self.purgeRememberedWidthsOnce()       // delete any width saved by a prior launch
                    splitView.setPosition(width, ofDividerAt: 0)  // override any restored width NOW
                    return true
                }
                responder = r.nextResponder
            }
            return false
        }

        /// One-shot removal of every persisted NavigationSplitView width so a stale "remembered"
        /// value can never win over the constant on the next launch.
        private static var didPurgeRememberedWidths = false
        private static func purgeRememberedWidthsOnce() {
            guard !didPurgeRememberedWidths else { return }
            didPurgeRememberedWidths = true
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSSplitView Subview Frames") {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

private extension View {
    /// RULE #1: a `ToolbarSpacer` (NOT a placeholder item — the system would draw an empty glass
    /// capsule around an item) keeps the unified sidebar (traffic lights inside) on screens that have
    /// no toolbar buttons of their own. No-op below macOS 26.
    @ViewBuilder func macSidebarToolbarSpacer() -> some View {
        if #available(macOS 26.0, *) {
            self.toolbar { ToolbarSpacer(.fixed, placement: .primaryAction) }
        } else {
            self
        }
    }

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
