//
//  MacCard.swift
//  Zashi
//
//  macOS: a SINGLE root-hosted card presenter (MODALS.md Rule #5). Every `.zashiSheet` /
//  `.zashiSelectorSheet` on macOS writes its content to a `MacCardCoordinator` injected via the
//  environment by `.macCardHost()` at the app root, which renders ONE centered, dimmed, dynamically-sized
//  card OVER THE WHOLE WINDOW — outside the content cap (`Design.Mac.viewCapWidth` / `macCappedScreenContent`). The content is
//  built in the child's body (store + colorScheme correct). It renders DETACHED here, OUTSIDE the
//  presenting view's TCA observation, so the `.zashiSheet` / `.zashiSelectorSheet` plumbing wraps it in
//  `WithPerceptionTracking` (MODALS.md Rule #5b) — without that, store changes update state but the card
//  redraws a stale snapshot (filter chips not toggling, etc.). The environment (down-propagation) reliably
//  crosses NavigationStack / NavigationSplitView, where a PreferenceKey (up-propagation) is consumed by
//  the container. iOS keeps native `.sheet` / `.popover`.
//
//  Single slot — there's only ever one card (these exist only because there's no always-one iOS `.sheet`).
//

#if os(macOS)
import SwiftUI

@Observable
final class MacCardCoordinator {
    var entry: MacCardEntry?
}

struct MacCardEntry: Identifiable {
    let id: UUID
    let content: () -> AnyView
    /// nil = hug content (the `.zashiSheet` shape); set = definite width (the `.zashiSelectorSheet` list).
    let fixedWidth: CGFloat?
    let fixedHeightRange: ClosedRange<CGFloat>?
    let horizontalPadding: CGFloat
    /// The selector draws its own close button; the standard sheet relies on the host's.
    let showsCloseButton: Bool
    let dismiss: () -> Void
}

extension View {
    /// Write this card to the root `.macCardHost()`. Built in the child's body (store + colorScheme).
    func macCardPublish(
        isPresented: Bool,
        fixedWidth: CGFloat? = nil,
        fixedHeightRange: ClosedRange<CGFloat>? = nil,
        horizontalPadding: CGFloat,
        showsCloseButton: Bool,
        dismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        modifier(
            MacCardPublishModifier(
                isPresented: isPresented,
                fixedWidth: fixedWidth,
                fixedHeightRange: fixedHeightRange,
                horizontalPadding: horizontalPadding,
                showsCloseButton: showsCloseButton,
                dismiss: dismiss,
                cardContent: { AnyView(content()) }
            )
        )
    }

    /// Root: own the coordinator + render the one teleported card, full-window, above the content cap.
    func macCardHost() -> some View {
        modifier(MacCardHostModifier())
    }
}

private struct MacCardPublishModifier: ViewModifier {
    @Environment(MacCardCoordinator.self) private var coordinator: MacCardCoordinator?
    @Environment(\.colorScheme) private var colorScheme
    @State private var id = UUID()

    let isPresented: Bool
    let fixedWidth: CGFloat?
    let fixedHeightRange: ClosedRange<CGFloat>?
    let horizontalPadding: CGFloat
    let showsCloseButton: Bool
    let dismiss: () -> Void
    let cardContent: () -> AnyView

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, presented in sync(presented) }
            // Re-publish when colorScheme flips so a card open across a dark-mode toggle re-themes.
            .onChange(of: colorScheme) { _, _ in if isPresented { sync(true) } }
            .onAppear { if isPresented { sync(true) } }
            .onDisappear { if coordinator?.entry?.id == id { coordinator?.entry = nil } }
    }

    private func sync(_ presented: Bool) {
        guard let coordinator else { return }
        if presented {
            coordinator.entry = MacCardEntry(
                id: id,
                content: cardContent,
                fixedWidth: fixedWidth,
                fixedHeightRange: fixedHeightRange,
                horizontalPadding: horizontalPadding,
                showsCloseButton: showsCloseButton,
                dismiss: dismiss
            )
        } else if coordinator.entry?.id == id {
            coordinator.entry = nil
        }
    }
}

private struct MacCardHostModifier: ViewModifier {
    @State private var coordinator = MacCardCoordinator()

    func body(content: Content) -> some View {
        content
            .environment(coordinator)
            .overlay {
                if let entry = coordinator.entry {
                    MacCardOverlay(entry: entry)
                }
            }
    }
}

private struct MacCardOverlay: View {
    let entry: MacCardEntry

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .onTapGesture { entry.dismiss() }

            cardWithChrome
                // macOS: every ZashiButton inside a MacCard renders full-bleed (bypassing Rule #7's
                // maxButtonWidth cap) — a fixed-width card is exactly where a capped, centered pill
                // looks wrong. This is the rule for cards; the `fillsWidth` param does the same for a
                // full-width button OUTSIDE a card.
                .environment(\.zashiButtonFillsWidth, true)
        }
    }

    @ViewBuilder private var cardWithChrome: some View {
        if let width = entry.fixedWidth {
            GeometryReader { geo in
                sizedCard {
                    entry.content()
                        .frame(
                            width: width,
                            height: entry.fixedHeightRange.map {
                                max($0.lowerBound, min($0.upperBound, geo.size.height - 80))
                            }
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        } else {
            sizedCard {
                VStack(alignment: .leading, spacing: 0) {
                    entry.content()
                }
                .padding(.horizontal, entry.horizontalPadding)
                .padding(.vertical, Design.Spacing._3xl)
                .frame(maxWidth: Design.Mac.cardMaxWidth)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func sizedCard(@ViewBuilder _ inner: () -> some View) -> some View {
        inner()
            .macSheetCardSurface()
            .overlay(alignment: .topTrailing) { closeAffordance }
            .shadow(color: Color.black.opacity(0.25), radius: 24, x: 0, y: 10)
            .padding(40)
    }

    @ViewBuilder private var closeAffordance: some View {
        if entry.showsCloseButton {
            Button {
                entry.dismiss()
            } label: {
                Asset.Assets.buttonCloseX.image
                    .zImage(size: 24, style: Design.Text.primary)
                    .padding(Design.Spacing._lg)
            }
            .zashiPlainButtonStyle()
            .keyboardShortcut(.cancelAction)
        } else {
            // ESC still dismisses even when the content draws its own close button.
            Button("") { entry.dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
    }
}
#else
import SwiftUI

extension View {
    /// iOS: no-op — cards present as native `.sheet`s, so there's no root host to render.
    func macCardHost() -> some View { self }
}
#endif
