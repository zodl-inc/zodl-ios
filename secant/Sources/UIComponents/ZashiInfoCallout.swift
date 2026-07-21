//
//  ZashiInfoCallout.swift
//  zodl
//
//  Design-system info callout (MOB-1497 T2). Generalizes the Orchard-spend disclaimer card in
//  `SendFormView.orchardSpendDisclaimerCard()` (SendFormView.swift:324-345) into three reusable
//  styles that the migration Entry/Review/Scheduled/Status/Plan screens adopt in later MOB-1497
//  tasks: `.warning` mirrors the SendForm card verbatim (WarningYellow background + text, trailing
//  icon); `.filled` swaps in the neutral secondary-surface palette and supports an optional
//  semibold prefix run (e.g. a ZEC amount) ahead of the regular body copy; `.plain` drops the
//  background/padding for an inline note with a leading icon instead.
//

import SwiftUI

struct ZashiInfoCallout: View {
    @Environment(\.colorScheme) private var colorScheme

    enum Style {
        case warning
        case filled
        case plain
    }

    let style: Style
    let title: String
    // Named apart from the `body` init parameter below since `View.body` already claims that name.
    let bodyText: String
    let boldBodyPrefix: String?

    init(
        style: Style,
        title: String,
        body: String,
        boldBodyPrefix: String? = nil
    ) {
        self.style = style
        self.title = title
        self.bodyText = body
        self.boldBodyPrefix = boldBodyPrefix
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isIconLeading {
                icon
            }

            VStack(alignment: .leading, spacing: textGap) {
                Text(title)
                    .zFont(.medium, size: 14, style: titleColor)
                    .fixedSize(horizontal: false, vertical: true)

                calloutBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isIconLeading {
                icon
            }
        }
        .padding(contentPadding)
        .background {
            if let backgroundColor {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(backgroundColor.color(colorScheme))
            }
        }
    }

    // MARK: - Icon

    @ViewBuilder private var icon: some View {
        Asset.Assets.infoOutline.image
            .zImage(size: 16, style: iconColor)
    }

    // MARK: - Body text (optionally a bold prefix run followed by the regular remainder)

    @ViewBuilder private var calloutBody: some View {
        if let boldBodyPrefix, !boldBodyPrefix.isEmpty {
            boldPrefixedBody(boldBodyPrefix)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(bodyText)
                .zFont(size: bodyFontSize, style: bodyColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // `Text` concatenation (`+`) requires both runs to stay `Text`, so this rebuilds the same
    // font + color pair `.zFont` applies internally (`.font(.custom(...))` then the token's own
    // `.color(colorScheme)`) instead of calling `.zFont`, which returns `some View` and would lose
    // the ability to concatenate. Both runs are still styled entirely from `Design` tokens.
    // The prefix deliberately shares `titleColor` — the canvas draws the bold amount run in the
    // same primary tone as the title (Figma 3480:7631); rename the token if a style ever needs
    // the two to diverge.
    private func boldPrefixedBody(_ prefix: String) -> Text {
        Text(prefix)
            .font(.custom(FontFamily.Inter.semiBold.name, size: bodyFontSize))
            .foregroundColor(titleColor.color(colorScheme))
        + Text(bodyText)
            .font(.custom(FontFamily.Inter.regular.name, size: bodyFontSize))
            .foregroundColor(bodyColor.color(colorScheme))
    }

    // MARK: - Style tokens

    private var isIconLeading: Bool {
        switch style {
        case .plain: return true
        case .warning, .filled: return false
        }
    }

    private var contentPadding: CGFloat {
        switch style {
        case .warning, .filled: return 16
        case .plain: return 0
        }
    }

    private var textGap: CGFloat {
        switch style {
        case .warning, .filled: return 4
        case .plain: return 2
        }
    }

    private var bodyFontSize: CGFloat {
        switch style {
        case .filled: return 14
        case .warning, .plain: return 12
        }
    }

    private var backgroundColor: Colorable? {
        switch style {
        case .warning: return Design.Utility.WarningYellow._50
        case .filled: return Design.Surfaces.bgSecondary
        case .plain: return nil
        }
    }

    private var titleColor: Colorable {
        switch style {
        case .warning: return Design.Utility.WarningYellow._700
        case .filled, .plain: return Design.Text.primary
        }
    }

    private var bodyColor: Colorable {
        switch style {
        case .warning: return Design.Utility.WarningYellow._700
        case .filled, .plain: return Design.Text.tertiary
        }
    }

    private var iconColor: Colorable {
        switch style {
        case .warning: return Design.Utility.WarningYellow._700
        case .filled, .plain: return Design.Text.tertiary
        }
    }
}

// MARK: - Previews

#Preview {
    VStack(spacing: 24) {
        ZashiInfoCallout(
            style: .warning,
            title: "Reduced privacy for this transfer",
            body: "This transaction spends Orchard funds, which may reveal information to network observers."
        )

        ZashiInfoCallout(
            style: .filled,
            title: "Dust remainder",
            body: "will be swept into your next scheduled transfer.",
            boldBodyPrefix: "0.5 ZEC "
        )

        ZashiInfoCallout(
            style: .filled,
            title: "Dust remainder",
            body: "No dust remains after this transfer."
        )

        ZashiInfoCallout(
            style: .plain,
            title: "Missed window",
            body: "Migration resumes automatically the next time the app is online."
        )
    }
    .padding(16)
}
