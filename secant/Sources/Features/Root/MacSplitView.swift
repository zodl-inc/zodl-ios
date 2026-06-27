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
    private let sidebarWidth: CGFloat = Design.Mac.sidebarWidth

    @Environment(\.colorScheme) private var colorScheme
    @Shared(.appStorage(.sensitiveContent)) private var isSensitiveContentHidden = false
    @State private var selectedSection: MacSection = .activity
    // The section the DETAIL actually renders (vs `selectedSection`, the sidebar highlight). On a switch
    // it goes selected -> nil (a one-frame blank) -> new, so the popped root never renders: the user sees
    // B -> blank -> C, not B -> A -> C. The nil frame also breaks SwiftUI's path reconcile (the crash).
    @State private var detailSection: MacSection? = .activity
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

    // RULE #10: lock the user into a ZEC broadcast. Send, Pay and Swap ALL converge on the same
    // SendConfirmation sending / result screens (`.sending` + `.sendResult{Pending,Success,Failure}`) —
    // hosted by SendCoordFlow for Send and by SwapAndPayCoordFlow for Pay/Swap. Once ANY of them reaches
    // those screens, promote to full-window (hide the sidebar) so the user can't tap another section and
    // abandon an in-flight broadcast. "Close" on the result pops the path → this goes false → the split
    // (sidebar) returns. (Pre-broadcast confirmation / Keystone-signing screens intentionally keep the
    // sidebar — the user can still back out there.)
    private var isBroadcastLocked: Bool {
        store.sendCoordFlowState.path.contains {
            $0.is(\.sending) || $0.is(\.sendResultPending) || $0.is(\.sendResultSuccess) || $0.is(\.sendResultFailure)
        } || store.swapAndPayCoordFlowState.path.contains {
            $0.is(\.sending) || $0.is(\.sendResultPending) || $0.is(\.sendResultSuccess) || $0.is(\.sendResultFailure)
        }
    }

    // A flow owns the whole window (sidebar hidden): scan = RULE #9, a Send/Pay/Swap broadcast = RULE #10.
    private var isFullWindowFlow: Bool {
        isScanActive || isBroadcastLocked
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
            // RULE #2 + crash + UX: render the new section via `detailSection`, which goes X -> nil (a
            // one-frame blank) -> Y on a switch. The nil frame (a) breaks SwiftUI's X-path↔Y-path reconcile
            // that crashes (comparisonTypeMismatch), and (b) HIDES the pop-to-root — the user sees B ->
            // blank -> C, never the popped root A. The blank is the screen background, a brief neutral frame.
            Group {
                if detailSection != nil {
                    rightPanel
                } else {
                    // Keep a ToolbarSpacer on the blank frame (RULE #1) so the traffic lights stay INSIDE
                    // the sidebar during the transition. Without it the blank has no toolbar content, the
                    // lights jump out to the title bar for one frame and back, and the whole window "pops".
                    Asset.Colors.background.color.ignoresSafeArea()
                        .macSidebarToolbarSpacer()
                }
            }
            .id(detailSection)
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
            // the current section to its root. Re-initialize the selected section — UNLESS a transaction
            // Result screen just asked to redirect to Activity (handled below), which supersedes the re-init.
            if newPath == nil && !store.macRedirectToActivityAfterClose {
                store.send(selectedSection.action)
            }
        }
        .onChange(of: store.macRedirectToActivityAfterClose) { _, redirect in
            // macOS: a transaction Result screen (Send / Pay / Swap — incl. Keystone & scan) was closed.
            // Land the user on Activity so the just-finished transaction is visible at the top; the section
            // switch's `macResetSectionPaths` also pops the finished flow to root. Then clear the flag.
            // Covers Keystone too — it dismisses via a binding (not `path`), so a path-only hook would miss it.
            guard redirect else { return }
            store.send(.macRedirectToActivityHandled)
            selectSection(.activity)
        }
        // RULE #9 (scan) + RULE #10 (Send/Pay/Swap broadcast lock): collapse to detail-only so the sidebar
        // is hidden and the flow owns the whole window — the user can't switch sections (so can't cancel an
        // in-flight broadcast). Restores to .all when the flow ends (scan dismissed / result closed).
        .onChange(of: isFullWindowFlow) { _, full in
            columnVisibility = full ? .detailOnly : .all
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
        // Smart-banner help sheet (shielding / sync error / …). Hosted here on macOS (MODALS.md Rule #5):
        // the banner lives in the sidebar, so a `.zashiSheet` on it would clamp the card to the sidebar
        // width. At the window root it covers the whole window. iOS presents it inline from SmartBannerView.
        .zashiSheet(
            isPresented: Binding(
                get: { store.homeState.smartBannerState.isSmartBannerSheetPresented },
                set: { newValue in
                    if !newValue && store.homeState.smartBannerState.isSmartBannerSheetPresented {
                        store.send(.home(.smartBanner(.closeSheetTapped)))
                    }
                }
            )
        ) {
            SmartBannerHelpSheetView(
                store: store.scope(state: \.homeState.smartBannerState, action: \.home.smartBanner),
                tokenName: tokenName
            )
        }
        // Smart-banner sync-timeout sheet — hosted at the root on macOS for the same reason (MODALS.md
        // Rule #5). iOS presents it inline from SmartBannerView.
        .zashiSheet(
            isPresented: Binding(
                get: { store.homeState.smartBannerState.isSyncTimedOutSheetPresented },
                set: { newValue in
                    if !newValue && store.homeState.smartBannerState.isSyncTimedOutSheetPresented {
                        store.send(.home(.smartBanner(.binding(.set(\.isSyncTimedOutSheetPresented, false)))))
                    }
                }
            )
        ) {
            SmartBannerSyncTimeoutSheetView(
                store: store.scope(state: \.homeState.smartBannerState, action: \.home.smartBanner)
            )
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
            set: { newSection in selectSection(newSection) }
        )
    }

    // Switch the macOS sidebar to `newSection` with the THREE-PHASE blank-then-reveal: clear paths + move
    // the sidebar highlight + BLANK the detail (detailSection = nil) THIS frame, then reveal the new
    // section NEXT runloop. The one-frame blank both (a) breaks SwiftUI's path reconcile (the crash) and
    // (b) HIDES the pop-to-root, so the user sees B -> blank -> C, never the popped root A. Shared by the
    // sidebar selection binding and the post-transaction redirect to Activity.
    private func selectSection(_ newSection: MacSection) {
        guard newSection != selectedSection else { return }
        LoggerProxy.event("[macOS nav] section \(selectedSection) -> \(newSection): blank-then-reveal (avoid comparisonTypeMismatch + hide pop-to-root)")
        store.send(.macResetSectionPaths)
        selectedSection = newSection
        detailSection = nil
        DispatchQueue.main.async {
            detailSection = newSection
        }
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
                    Text(localizable: .generalBalance)
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
        init(width: CGFloat) {
            self.width = width
            super.init(frame: .zero)
        }
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
