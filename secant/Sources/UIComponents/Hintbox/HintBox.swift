//
//  HintBox.swift
//  Zashi
//
//  Created by Lukáš Korba on 2026-07-01.
//
//  A shared "(i) note" row — an info icon beside a short explanatory note, shown above a screen's
//  bottom CTA(s). Replaces the icon + Text HStacks that had been copy-pasted (and had drifted) across
//  ~9 screens.
//
//  Two typographic variants, matching what those call sites used:
//    • .plain    — an already-localized plain string at size 12 (swap / currency / Tor notes).
//    • .markdown — a Zashi-styled markdown string at size 14 (wallet-birthday / restore notes).
//
//  Width:
//    • iOS  — full width (Rule #11), unchanged.
//    • macOS — matches the CTA beneath it. In a normal screen flow the button is capped
//      (`Design.Mac.maxButtonWidth`, Rule #7), so the note caps + centers to that same width rather
//      than spanning the whole `viewCapWidth` content column — a wide note over a short button looked
//      wrong. Inside a `MacCard` the buttons render full-bleed (`\.zashiButtonFillsWidth`), so the
//      note fills too. Either way the note lines up with the button below it.
//

import SwiftUI

struct HintBox: View {
    enum Style {
        case plain
        case markdown
    }

    @Environment(\.colorScheme) private var colorScheme
    /// Set to `true` by `MacCard` on its content (see `\.zashiButtonFillsWidth`). When the surrounding
    /// buttons render full-bleed the note fills too; otherwise it caps to the button width. macOS only.
    @Environment(\.zashiButtonFillsWidth) private var fillsWidth

    let text: String
    let style: Style
    let iconStyle: Colorable

    init(_ text: String, style: Style = .plain, iconStyle: Colorable = Design.Text.primary) {
        self.text = text
        self.style = style
        self.iconStyle = iconStyle
    }

    var body: some View {
        HStack(alignment: .top, spacing: style == .markdown ? 8 : 0) {
            Asset.Assets.infoCircle.image
                .zImage(size: 20, style: iconStyle)
                .padding(.trailing, style == .markdown ? 0 : 12)

            note
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hintBoxMacWidth(fillsWidth: fillsWidth)
    }

    @ViewBuilder private var note: some View {
        switch style {
        case .plain:
            Text(text)
                .zFont(size: 12, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .markdown:
            if let attributed = try? AttributedString(markdown: text, including: \.zashiApp) {
                ZashiText(withAttributedString: attributed, colorScheme: colorScheme)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    /// macOS: cap the note to the CTA button width (`Design.Mac.maxButtonWidth`) and center it so it
    /// lines up with the capped button below (Rule #7) — unless we're inside a `MacCard`, where the
    /// buttons fill their width and so should the note. iOS: no-op (full width, Rule #11).
    @ViewBuilder func hintBoxMacWidth(fillsWidth: Bool) -> some View {
#if os(macOS)
        if fillsWidth {
            self
        } else {
            frame(maxWidth: Design.Mac.maxButtonWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
#else
        self
#endif
    }
}
