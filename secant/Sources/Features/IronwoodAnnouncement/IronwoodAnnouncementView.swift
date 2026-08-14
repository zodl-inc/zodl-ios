//
//  IronwoodAnnouncementView.swift
//  Zashi
//
//  Created by Michal Fousek on 25.07.2026.
//

import SwiftUI
import ComposableArchitecture

// This is the Ironwood support article: it is about moving funds, not the general Ironwood
// news. Both the "Learn more" button and the tappable "our guide" link in the guide line below
// point at this same article by decision.
private let ironwoodAnnouncementFAQURL = "https://support.zodl.com/article/42-moving-your-funds-to-ironwood"

struct IronwoodAnnouncementView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<IronwoodAnnouncement>

    init(store: StoreOf<IronwoodAnnouncement>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                // Items 1-7 of the design live in this ScrollView. The Figma frame draws this copy
                // as fixed with the buttons pinned below it, which has ample slack on the 852pt
                // frame it was drawn at but almost none on a 667pt iPhone SE — where the guide
                // line ends directly above the buttons. Any longer translation of this copy, or a
                // smaller device, tips it over. The text column therefore scrolls while the
                // buttons stay pinned outside it. Do not "simplify" this back to a plain VStack.
                //
                // Note this screen's text does NOT grow with the user's text-size setting: `zFont`
                // uses `Font.custom(_:size:)` without `relativeTo:`, so the whole app renders at
                // fixed point sizes. If Dynamic Type is ever adopted, this ScrollView is already
                // what keeps the buttons reachable.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 1. Brandmark pair. Dark mark first so the yellow mark draws on top of it.
                        //
                        // The ZODL badge is composed rather than taken from `zashiLogoWithBackground`:
                        // that asset ships a black-on-white variant for light mode and a
                        // white-on-black one for dark, so it blends into whatever is behind it
                        // instead of staying a fixed badge — in light mode it renders as a bare
                        // dark glyph with no circle at all. Compositing the transparent mark over a
                        // filled circle keeps it a badge, and `Design.Logo.primary` / `.opposite`
                        // invert together so it stays legible in both colour schemes.
                        HStack(spacing: -3) {
                            Asset.Assets.zashiLogo.image
                                .zImage(size: 26, style: Design.Logo.primary)
                                .frame(width: 48, height: 48)
                                .background {
                                    Circle()
                                        .foregroundColor(Design.Logo.opposite.color(colorScheme))
                                }

                            Asset.Assets.zcashZecLogo.image
                                .resizable()
                                .frame(width: 48, height: 48)
                        }
                        // Extra offset for this header block itself, on top of the hidden
                        // app-bar spacing applied to the whole content below. Together they
                        // reproduce the Figma frame's `opacity-0` status bar + top app bar,
                        // which are invisible but still occupy layout space.
                        .padding(.top, Design.Spacing._lg)

                        // 3. Title
                        Text(localizable: .ironwoodAnnouncementTitle)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Design.Spacing._xl)

                        // 5. Three paragraphs, 12pt apart.
                        Text(localizable: .ironwoodAnnouncementBody1)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Design.Spacing._lg)

                        Text(localizable: .ironwoodAnnouncementBody2)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Design.Spacing._lg)

                        Text(localizable: .ironwoodAnnouncementBody3)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Design.Spacing._lg)

                        // 7. Guide line: prefix + tappable link + suffix. Tapping the link opens
                        // the in-app browser instead of leaving the app.
                        Text(guideAttributedString())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Design.Spacing._3xl)
                            .environment(\.openURL, OpenURLAction { _ in
                                store.send(.guideTapped)
                                return .handled
                            })
                    }
                }
                .scrollBounceBasedOnSizeIfAvailable()

                // 8. Flexible space: absorbs any leftover height so the buttons stay pinned to
                // the bottom when the content above is short, and shrinks to nothing (letting
                // the ScrollView above take over and scroll) when the content overflows.
                Spacer()

                // 9. The screen's ONLY button, pinned outside the scroll view, and the only
                // way to acknowledge the announcement. "Learn more" stood above it until
                // 2026-08-08 (Lukas): it opened the very same support article the inline guide
                // link opens — the store's own arms were byte-identical — so the duplicate was
                // removed and the guide link is now the single route to the article. What
                // remains is one dismiss.
                ZashiButton(String(localizable: .ironwoodAnnouncementContinue)) {
                    store.send(.continueTapped)
                }
                .padding(.bottom, Design.Spacing._3xl)
            }
            // In the Figma frame the status bar and the top app bar are present but at
            // `opacity-0` — invisible, yet they still occupy space, which is why the content
            // starts well down the screen. This reproduces that reserved space: 12pt top inset +
            // 36pt bar height + 12pt bottom inset = 60pt. Not an arbitrary magic number.
            .padding(.top, 60)
            .sheet(isPresented: $store.isInAppBrowserOn) {
                if let url = URL(string: ironwoodAnnouncementFAQURL) {
                    InAppBrowserView(url: url)
                }
            }
        }
        .zashiNavigationBarHidden(true)
        .screenHorizontalPadding()
        .applyScreenBackground()
    }

    /// Builds the guide sentence (prefix + tappable link + suffix) as a single `AttributedString`
    /// concatenated from three separately-localized fragments, so each stays translatable and the
    /// link range is known by construction rather than found by searching the rendered string.
    private func guideAttributedString() -> AttributedString {
        var prefix = AttributedString(String(localizable: .ironwoodAnnouncementGuidePrefix))
        prefix.font = Font.custom(FontFamily.Inter.medium.name, size: 14)
        prefix.foregroundColor = Design.Text.primary.color(colorScheme)

        var link = AttributedString(String(localizable: .ironwoodAnnouncementGuideLink))
        link.font = Font.custom(FontFamily.Inter.semiBold.name, size: 14)
        link.underlineStyle = .single
        link.foregroundColor = Design.Text.link.color(colorScheme)
        link.link = URL(string: ironwoodAnnouncementFAQURL)

        var suffix = AttributedString(String(localizable: .ironwoodAnnouncementGuideSuffix))
        suffix.font = Font.custom(FontFamily.Inter.medium.name, size: 14)
        suffix.foregroundColor = Design.Text.primary.color(colorScheme)

        return prefix + link + suffix
    }
}

private extension View {
    /// `scrollBounceBehavior` requires iOS 16.4 and the app deploys to 16.0, so it is applied only
    /// where available. Without it a screen whose content already fits still rubber-bands, which
    /// reads as sloppy; on 16.0-16.3 that bounce is accepted rather than dropping the ScrollView,
    /// which is what keeps the buttons reachable on a small device.
    @ViewBuilder
    func scrollBounceBasedOnSizeIfAvailable() -> some View {
        if #available(iOS 16.4, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        IronwoodAnnouncementView(store: IronwoodAnnouncement.initial)
    }
}

// MARK: - Store

extension IronwoodAnnouncement {
    @MainActor static let initial = StoreOf<IronwoodAnnouncement>(
        initialState: .initial
    ) {
        IronwoodAnnouncement()
    }
}

// MARK: - Placeholders

extension IronwoodAnnouncement.State {
    static let initial = IronwoodAnnouncement.State()
}
