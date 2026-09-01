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
        // Check for updates at launch — runs regardless of wallet onboarding state
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            Updater.checkAndUpdate(log: { msg in
                NSLog("[Updater] %@", msg)
                print("[Updater] \(msg)")
            })
        }
    }

    var body: some Scene {
        // App Review Guideline 4 (external-testing finding, 2026-07-02): closing the main window
        // left NO menu item to reopen it (single fixed window, ⌘N removed, File menu dropped).
        // `Window` — SwiftUI's single-window scene — is the remedy, with a consequence we KEEP
        // deliberately (verified 2026-07-16, MOB-1486): because this window is the app's ONLY
        // scene, macOS QUITS the app when it closes — "If your app uses a single window as its
        // primary scene, the app quits when the window closes" (SwiftUI `Window` docs). That is
        // the platform convention for single-window apps AND a security property this wallet
        // relies on: everything in memory — including a partially typed recovery phrase on the
        // restore screen — dies with the process. The pre-2026-07-02 `WindowGroup` build kept
        // running windowless, which is exactly where the external security audit reproduced the
        // "typed recovery phrase reappears after close→reopen" finding.
        // ⚠️ Adding ANY second scene (a Settings window, menu-bar extra, auxiliary panel)
        // silently restores keep-running-after-close semantics and resurrects that finding — if
        // you do, wipe `Root.State.onboardingState` on main-window close first (see MOB-1486).
        // B4-20: the scene title MUST stay EMPTY — SwiftUI re-asserts it onto the NSWindow on
        // every navigation push, and a non-empty title becomes the "← Zodl" back-button fallback
        // on every pushed screen (a one-time title blank does NOT stick). The Window-menu reopen
        // item is therefore provided EXPLICITLY (ZodlWindowCommands below) instead of relying on
        // the scene-title-derived automatic item.
        Window("", id: "main") {
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
                // Update check runs from init() — do not call again here
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
                        // Also check for updates on foreground
                        DispatchQueue.global().async {
                            Updater.checkAndUpdate(log: { msg in NSLog("[Updater] %@", msg) })
                        }
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
            ZodlWindowCommands()
        }
    }
}

/// Guideline 4: an EXPLICIT "Zodl" item in the Window menu that focuses (or deminiaturizes) the
/// main window. Closing the window quits the app (single-`Window` scene — see the scene comment,
/// MOB-1486), so "reopen after close" no longer arises; the item stays for the minimized case
/// and App Review parity. Explicit because the scene's automatic item is derived from the scene
/// title, which must stay empty (see the `Window("")` comment — B4-20).
private struct ZodlWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("Zodl") { openWindow(id: "main") }
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

        // B4-20 companion: the scene title must stay EMPTY (see the `Window("")` comment), so
        // SwiftUI's AUTOMATIC scene item in the Window menu would render as a blank row next to
        // the explicit "Zodl" command (ZodlWindowCommands). Scrub empty-titled rows; the live
        // window's own list entry is named via `changeWindowsItem` in FixedWindowConfigurator.
        if let windows = windowsMenu {
            windows.items
                .filter { $0.title.isEmpty && !$0.isSeparatorItem }
                .forEach { windows.removeItem($0) }
        }

        // App menu → "Zodl" with exactly "About Zodl" + "Quit Zodl" (drop Settings / Services /
        // Hide …). About uses the STANDARD system panel — icon, name, version — the most
        // minimal native design there is, and cheap App Review insurance (reviewers nit a
        // missing About).
        guard let appItem = mainMenu.items.first, let appMenu = appItem.submenu else { return }
        appItem.title = "Zodl"
        appMenu.title = "Zodl"
        let terminate = #selector(NSApplication.terminate(_:))
        let about = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        let kept: Set<Selector> = [terminate, about]
        appMenu.items
            .filter { item in item.action.map { !kept.contains($0) } ?? true }
            .forEach { appMenu.removeItem($0) }
        appMenu.items.first { $0.action == about }?.title = "About Zodl"
        appMenu.items.first { $0.action == terminate }?.title = "Quit Zodl"
        // Standard grouping: About ─ separator ─ Quit.
        if appMenu.items.count == 2 {
            appMenu.insertItem(.separator(), at: 1)
        }
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
            // Guideline-4 companion: the SCENE is titled "Zodl" purely to name the Window-menu
            // reopen item — on screen the title bar must stay EMPTY, or macOS uses it as the
            // navigation back-button fallback ("← Zodl" on every screen, the old papercut).
            window.title = ""
            // …but the Window menu labels a LIVE (open/minimized) window by its title, so with a
            // blank title the window's own menu entry rendered as an unlabeled line — plausibly
            // the reviewer's actual sighting when minimized. Name the menu entry independently
            // of the on-screen title (selecting it also deminiaturizes).
            NSApp.changeWindowsItem(window, title: "Zodl", filename: false)
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
