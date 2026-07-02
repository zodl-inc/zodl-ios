//
//  zodlmac_internalApp.swift
//  zodlmac-internal
//
//  macOS app entry. Mirrors the iOS `SecantApp` (AppDelegate is iOS-only, so the root store is
//  created here and the launch / foreground / background lifecycle is driven via scenePhase).
//

import SwiftUI
import AppKit
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@main
struct zodlmac_internalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
    @State private var didFinishLaunching = false
    @State private var didEnterBackgroundOnce = false

    let rootStore = StoreOf<Root>(
        initialState: .initial
    ) {
        Root()
//            .logging()
    }

    init() {
        FontFamily.registerAllCustomFonts()
        NSDecimalNumber.defaultBehavior = Zatoshi.decimalHandler
        setupFeatureFlags()
        // Startup-pop fix (sidebar): delete any NSSplitView width remembered by a PREVIOUS launch
        // BEFORE any window exists. The old purge ran inside FixedSidebarWidth's async pin — after
        // the split view had already restored the stale width on frame 1 — so launch showed
        // remembered-width → slam-to-240, the visible sidebar pop.
        MacSidebarDefaults.purgeRememberedWidths()
    }

    var body: some Scene {
        // Empty window title: macOS uses the window title as the navigation fallback, which surfaced as a
        // non-contextual "← Zodl" on every back button. Blank it for Beta (screens can set their own
        // contextual navigationTitle later — e.g. "← Vote"). The app name in the dock/menu is the bundle
        // name, unaffected.
        WindowGroup("") {
            RootView(
                store: rootStore,
                tokenName: TargetConstants.tokenName,
                networkType: TargetConstants.zcashNetwork.networkType
            )
            .frame(width: WindowSize.width, height: WindowSize.height)
            .background(FixedWindowConfigurator())
            .font(.custom(FontFamily.Inter.regular.name, size: 17))
            // macOS gives every default-styled Button a bezeled gray background; iOS doesn't.
            // Force plain app-wide so buttons render only their own (iOS) styling — custom
            // ZashiButton backgrounds stay, raw icon/text buttons go flat like on iOS.
            .zashiPlainButtonStyle()
            // Same story for text fields: macOS draws a native bezel/inset; iOS is borderless and
            // the app supplies its own background + padding. Force plain so inputs match iOS.
            .textFieldStyle(.plain)
            .onAppear {
                guard !didFinishLaunching else { return }
                didFinishLaunching = true
                rootStore.send(.initialization(.appDelegate(.didFinishLaunching)))
                MacMenuSimplifier.simplifyDeferred()
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    // iOS only fires willEnterForeground when returning from the background —
                    // NOT at cold launch, where didFinishLaunching already runs initialSetups.
                    // Without this guard the first `.active` runs initialSetups a second time →
                    // a second engine handle → SQLite "database is locked" and a racing sync
                    // that drops transactions and balance.
                    if didEnterBackgroundOnce {
                        rootStore.send(.initialization(.appDelegate(.willEnterForeground)))
                    }
                case .background:
                    didEnterBackgroundOnce = true
                    rootStore.send(.initialization(.appDelegate(.didEnterBackground)))
                default:
                    break
                }
            }
        }
        .windowResizability(.contentSize)
        // Startup-pop fix (window size): tell the SCENE the window size up front. Without this the
        // window is born at a system-default frame and only resizes once the content's
        // `.frame(width:height:)` lays out (via `.contentSize` resizability) — a visible
        // size/position correction AFTER first display. With the scene-level default the window is
        // CREATED at 900×720, so `.defaultPosition(.center)` below can place it correctly on frame 1.
        .defaultSize(width: WindowSize.width, height: WindowSize.height)
        // Center on the FIRST launch only (no saved frame); afterwards macOS restores the window's last
        // position via SwiftUI's standard frame autosave. No forced re-centering on every open — that was
        // the visible startup jump (see FixedWindowConfigurator).
        .defaultPosition(.center)
        // Single-window app: remove the "New Window" command (and its ⌘N) so neither the menu nor the
        // shortcut can spawn a confusing second Zodl window. The File menu itself (which otherwise lingers
        // with just "Close") is dropped in MacMenuSimplifier.
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

private extension zodlmac_internalApp {
    func setupFeatureFlags() {
        // macOS: Flexa package is excluded; biometric (Touch ID) is supported.
        $featureFlags.withLock {
            $0 = FeatureFlags(
                appLaunchBiometric: true,
                flexa: false
            )
        }
    }
}

/// Simplifies the macOS menu bar for a single-window app: keep only the app menu (trimmed to a single
/// "Quit Zodl"), Edit, and Window; drop File (its "New Window" spawned a confusing second window), View,
/// and Help. Menus are identified STRUCTURALLY — by their items' selectors and `NSApp.windowsMenu`, never
/// by title — so it survives localized (e.g. Spanish) builds. Runs once, after the system builds the menu.
private enum MacMenuSimplifier {
    static func simplifyDeferred() {
        // Defer to the next runloop so SwiftUI/AppKit has finished installing the default main menu.
        DispatchQueue.main.async { simplify() }
    }

    static func simplify() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let windowsMenu = NSApp.windowsMenu
        let editActions: Set<Selector> = [NSSelectorFromString("paste:"), NSSelectorFromString("selectAll:")]
        let windowActions: Set<Selector> = [
            NSSelectorFromString("performMiniaturize:"),
            NSSelectorFromString("performZoom:"),
            NSSelectorFromString("arrangeInFront:")
        ]

        // Drop every top-level menu except the app menu (always first), Edit, and Window.
        var removable: [NSMenuItem] = []
        for (index, item) in mainMenu.items.enumerated() {
            if index == 0 { continue }
            let submenuItems = item.submenu?.items ?? []
            let isWindow = item.submenu === windowsMenu
                || submenuItems.contains { $0.action.map(windowActions.contains) ?? false }
            let isEdit = submenuItems.contains { $0.action.map(editActions.contains) ?? false }
            if isWindow || isEdit { continue }
            removable.append(item)
        }
        removable.forEach { mainMenu.removeItem($0) }

        // App menu → "Zodl" with a single "Quit Zodl" item (drop About / Settings / Services / Hide …).
        guard let appItem = mainMenu.items.first, let appMenu = appItem.submenu else { return }
        appItem.title = "Zodl"
        appMenu.title = "Zodl"
        let terminate = #selector(NSApplication.terminate(_:))
        appMenu.items
            .filter { $0.action != terminate }
            .forEach { appMenu.removeItem($0) }
        appMenu.items.first { $0.action == terminate }?.title = "Quit Zodl"
    }
}

private enum WindowSize {
    // Fixed landscape window for the macOS split layout — sourced from the single Mac sizing
    // namespace so the whole app resizes from one place (Design.Mac).
    static let width: CGFloat = Design.Mac.windowWidth
    static let height: CGFloat = Design.Mac.windowHeight
}

/// Locks the macOS window to a fixed size and disables the full-screen (green) button, so the
/// iOS phone layout always renders at its intended proportions.
private struct FixedWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.remove(.resizable)
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            // Lock the content size so a screen with tall, unconstrained content (e.g. the voting
            // "how to vote" screen) can't grow the window (which also enlarged the sidebar). With the
            // size locked, such a screen is clamped to the fixed pane and its ScrollView scrolls instead.
            let fixedContent = NSSize(width: WindowSize.width, height: WindowSize.height)
            window.contentMinSize = fixedContent
            window.contentMaxSize = fixedContent
            // Startup-pop fix (competing geometry sources): macOS window STATE RESTORATION (the
            // secure-coding mechanism, separate from frame autosave) re-applies stored geometry
            // AFTER first display — a second restore source that can yank a just-placed window.
            // A single fixed-size window needs no state restoration; SwiftUI's frame autosave
            // (which applies BEFORE display) remains the one position-persistence channel.
            window.isRestorable = false
            // Window POSITION is left to macOS — standard best-practice behavior. SwiftUI's WindowGroup
            // restores the last frame across launches, and `.defaultPosition(.center)` on the scene centers
            // it on the very first launch (no saved frame). The previous code disabled frame autosave and
            // re-centered on EVERY open, deferred to run after SwiftUI's restore — which yanked the window
            // from its restored spot to center, a visible jump. macOS already constrains a restored frame to
            // the visible area, so the old "too-low / offscreen" worry is handled by the system. Only the
            // size stays locked (above); the origin is the user's / system's to remember.
        }
    }
}
