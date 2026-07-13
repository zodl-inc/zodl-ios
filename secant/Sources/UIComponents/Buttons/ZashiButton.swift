//
//  ZashiButton.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-12-2024.
//

import SwiftUI

struct ZashiButton<PrefixContent, AccessoryContent>: View where PrefixContent: View, AccessoryContent: View {
    enum `Type` {
        case primary
        case secondary
        case tertiary
        case quaternary
        case destructive1
        case destructive2
        case brand
        case ghost
    }
    
    @Environment(\.isEnabled) var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    /// macOS: `MacCard` sets this on its content so every button inside a card renders full-bleed
    /// (see `\.zashiButtonFillsWidth`). ORed with the explicit `fillsWidth` param below.
    @Environment(\.zashiButtonFillsWidth) private var envFillsWidth

    let title: String
    let type: `Type`
    let infinityWidth: Bool
    /// macOS only: fill the container's full width, bypassing Rule #7's `Design.Mac.maxButtonWidth` pill
    /// cap — for full-bleed CTAs inside a fixed-width surface like `MacCard` (which turns this on for its
    /// whole content via `\.zashiButtonFillsWidth`). Inert on iOS, which already fills when `infinityWidth`.
    let fillsWidth: Bool
    let fontSize: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat?
    @ViewBuilder let prefixView: PrefixContent?
    @ViewBuilder let accessoryView: AccessoryContent?
    let action: () -> Void

    init(
        _ title: String,
        type: `Type` = .primary,
        infinityWidth: Bool = true,
        fillsWidth: Bool = false,
        fontSize: CGFloat = 16,
        horizontalPadding: CGFloat = 18,
        verticalPadding: CGFloat = 12,
        minHeight: CGFloat? = nil,
        prefixView: PrefixContent?,
        accessoryView: AccessoryContent?,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.type = type
        self.infinityWidth = infinityWidth
        self.fillsWidth = fillsWidth
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.minHeight = minHeight
        self.accessoryView = accessoryView
        self.prefixView = prefixView
        self.action = action
    }
    
    /// Effective full-width decision: the explicit `fillsWidth` param OR the `MacCard`-set environment.
    private var fillsFullWidth: Bool { fillsWidth || envFillsWidth }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 0) {
                if let prefixView {
                    prefixView
                        .padding(.trailing, 8)
                }

                Text(title)
                    .font(.custom(FontFamily.Inter.semiBold.name, size: fontSize))
                    .fixedSize()
                    .minimumScaleFactor(0.5)
                
                if let accessoryView {
                    accessoryView
                        .padding(.leading, 8)
                }
            }
            .zForegroundColor(fgColor())
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
#if os(macOS)
            // macOS: cap the CTA (background INCLUDED) to a logical width and center it, so buttons
            // don't stretch across the wide window. Order matters — cap → background → expand-and-
            // center. Capping only the label and applying the background AFTER the expand-to-infinity
            // frame (the old code) left a full-width background with merely centered text, which is
            // exactly what looked "full width".
            // `fillsFullWidth` (MacCard / explicit param) OPTS OUT of Rule #7's cap so the button fills
            // its container — full-bleed CTAs are the intended style inside a fixed-width card.
            .frame(maxWidth: fillsFullWidth ? .infinity : (infinityWidth ? Design.Mac.maxButtonWidth : nil), minHeight: minHeight)
            .background { buttonBackground }
            .frame(maxWidth: infinityWidth ? .infinity : nil, alignment: .center)
#else
            .frame(maxWidth: infinityWidth ? .infinity : nil, minHeight: minHeight)
            .background { buttonBackground }
#endif
        }
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: Design.Radius._xl)
            .fill(bgColor().color(colorScheme))
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .stroke(strokeColor().color(colorScheme))
            }
    }
    
    private func bgColor() -> Colorable {
        switch type {
        case .primary:
            return isEnabled
            ? Design.Btns.Primary.bg
            : Design.Btns.Primary.bgDisabled
        case .secondary:
            return isEnabled
            ? Design.Btns.Secondary.bg
            : Design.Btns.Secondary.bgDisabled
        case .tertiary:
            return isEnabled
            ? Design.Btns.Tertiary.bg
            : Design.Btns.Tertiary.bgDisabled
        case .quaternary:
            return isEnabled
            ? Design.Btns.Quaternary.bg
            : Design.Btns.Quaternary.bgDisabled
        case .destructive1:
            return isEnabled
            ? Design.Btns.Destructive1.bg
            : Design.Btns.Destructive1.bgDisabled
        case .destructive2:
            return isEnabled
            ? Design.Btns.Destructive2.bg
            : Design.Btns.Destructive2.bgDisabled
        case .brand:
            return isEnabled
            ? Design.Btns.Brand.bg
            : Design.Btns.Brand.bgDisabled
        case .ghost:
            return isEnabled
            ? Design.Btns.Ghost.bg
            : Design.Btns.Ghost.bgDisabled
        }
    }
    
    private func fgColor() -> Colorable {
        switch type {
        case .primary:
            return isEnabled
            ? Design.Btns.Primary.fg
            : Design.Btns.Primary.fgDisabled
        case .secondary:
            return isEnabled
            ? Design.Btns.Secondary.fg
            : Design.Btns.Secondary.fgDisabled
        case .tertiary:
            return isEnabled
            ? Design.Btns.Tertiary.fg
            : Design.Btns.Tertiary.fgDisabled
        case .quaternary:
            return isEnabled
            ? Design.Btns.Quaternary.fg
            : Design.Btns.Quaternary.fgDisabled
        case .destructive1:
            return isEnabled
            ? Design.Btns.Destructive1.fg
            : Design.Btns.Destructive1.fgDisabled
        case .destructive2:
            return isEnabled
            ? Design.Btns.Destructive2.fg
            : Design.Btns.Destructive2.fgDisabled
        case .brand:
            return isEnabled
            ? Design.Btns.Brand.fg
            : Design.Btns.Brand.fgDisabled
        case .ghost:
            return isEnabled
            ? Design.Btns.Ghost.fg
            : Design.Btns.Ghost.fgDisabled
        }
    }

    private func strokeColor() -> Colorable {
        switch type {
        case .primary:
            return isEnabled
            ? Design.Btns.Primary.bg
            : Design.Btns.Primary.bgDisabled
        case .secondary:
            return isEnabled
            ? Design.Btns.Secondary.border
            : Design.Btns.Secondary.bgDisabled
        case .tertiary:
            return isEnabled
            ? Design.Btns.Tertiary.bg
            : Design.Btns.Tertiary.bgDisabled
        case .quaternary:
            return isEnabled
            ? Design.Btns.Quaternary.bg
            : Design.Btns.Quaternary.bgDisabled
        case .destructive1:
            return isEnabled
            ? Design.Btns.Destructive1.border
            : Design.Btns.Destructive1.bgDisabled
        case .destructive2:
            return isEnabled
            ? Design.Btns.Destructive2.bg
            : Design.Btns.Destructive2.bgDisabled
        case .brand:
            return isEnabled
            ? Design.Btns.Brand.bg
            : Design.Btns.Brand.bgDisabled
        case .ghost:
            return isEnabled
            ? Design.Btns.Ghost.bg
            : Design.Btns.Ghost.bgDisabled
        }
    }
}

/// Plain button styling that makes the ENTIRE frame tappable on macOS. SwiftUI's `.plain` style on
/// macOS only hit-tests the *drawn* parts of a label, so transparent gaps — `Spacer`s, the padding
/// between an icon and a chevron — ignore clicks (rows respond only on their icon/label). Adding
/// `.contentShape(Rectangle())` makes the whole label rectangle the hit area, so full rows
/// (transaction rows, settings rows, the account switcher) respond anywhere, matching iOS. Defined
/// cross-platform but only applied on macOS via `View.zashiPlainButtonStyle()`.
struct FullAreaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

extension View {
    /// Plain button style, but full-frame tappable on macOS (see `FullAreaButtonStyle`). On iOS this
    /// is exactly `.zashiPlainButtonStyle()`, so the shipping iOS app is byte-for-byte unchanged.
    @ViewBuilder func zashiPlainButtonStyle() -> some View {
#if os(macOS)
        buttonStyle(FullAreaButtonStyle())
#else
        buttonStyle(.plain)
#endif
    }
}

/// macOS: `MacCard` sets this to `true` on its content so every `ZashiButton` inside a card renders
/// full-bleed (bypassing Rule #7's `Design.Mac.maxButtonWidth` cap) without each call site opting in.
/// Default `false` → the normal capped, centered pill everywhere else. `ZashiButton` ORs it with the
/// explicit `fillsWidth` param.
private struct ZashiButtonFillsWidthKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var zashiButtonFillsWidth: Bool {
        get { self[ZashiButtonFillsWidthKey.self] }
        set { self[ZashiButtonFillsWidthKey.self] = newValue }
    }
}

extension ZashiButton where PrefixContent == EmptyView, AccessoryContent == EmptyView {
    init(
        _ title: String,
        type: `Type` = .primary,
        infinityWidth: Bool = true,
        fillsWidth: Bool = false,
        fontSize: CGFloat = 16,
        horizontalPadding: CGFloat = 18,
        verticalPadding: CGFloat = 12,
        minHeight: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title,
            type: type,
            infinityWidth: infinityWidth,
            fillsWidth: fillsWidth,
            fontSize: fontSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            minHeight: minHeight,
            prefixView: nil,
            accessoryView: nil,
            action: action
        )
    }
}

extension ZashiButton where PrefixContent == EmptyView {
    init(
        _ title: String,
        type: `Type` = .primary,
        infinityWidth: Bool = true,
        fillsWidth: Bool = false,
        fontSize: CGFloat = 16,
        horizontalPadding: CGFloat = 18,
        verticalPadding: CGFloat = 12,
        minHeight: CGFloat? = nil,
        accessoryView: AccessoryContent,
        action: @escaping () -> Void
    ) {
        self.init(
            title,
            type: type,
            infinityWidth: infinityWidth,
            fillsWidth: fillsWidth,
            fontSize: fontSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            minHeight: minHeight,
            prefixView: nil,
            accessoryView: accessoryView,
            action: action
        )
    }
}

extension ZashiButton where AccessoryContent == EmptyView {
    init(
        _ title: String,
        type: `Type` = .primary,
        infinityWidth: Bool = true,
        fillsWidth: Bool = false,
        fontSize: CGFloat = 16,
        horizontalPadding: CGFloat = 18,
        verticalPadding: CGFloat = 12,
        minHeight: CGFloat? = nil,
        prefixView: PrefixContent,
        action: @escaping () -> Void
    ) {
        self.init(
            title,
            type: type,
            infinityWidth: infinityWidth,
            fillsWidth: fillsWidth,
            fontSize: fontSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            minHeight: minHeight,
            prefixView: prefixView,
            accessoryView: nil,
            action: action
        )
    }
}

#Preview {
    VStack(spacing: 15) {
        ZashiButton("Button") {}
        ZashiButton("Button", type: .secondary) {}
        ZashiButton("Button", type: .tertiary) {}
        ZashiButton("Button", type: .quaternary) {}
        ZashiButton("Button", type: .destructive1) {}
        ZashiButton("Button", type: .destructive2) {}
        ZashiButton("Button", type: .brand) {}
        ZashiButton("Button", type: .ghost) {}
    }
    .screenHorizontalPadding()
}

#Preview {
    VStack(spacing: 15) {
        ZashiButton(
            "Button",
            prefixView: 
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
        
        ZashiButton(
            "Button",
            type: .secondary,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
        
        ZashiButton(
            "Button",
            type: .tertiary,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
        
        ZashiButton(
            "Button",
            type: .quaternary,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
        
        ZashiButton(
            "Button",
            type: .destructive1,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
        
        ZashiButton(
            "Button",
            type: .destructive2,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
        
        ZashiButton(
            "Button",
            type: .brand,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
        
        ZashiButton(
            "Button",
            type: .ghost,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
    }
    .screenHorizontalPadding()
}

#Preview {
    VStack(spacing: 15) {
        ZashiButton(
            "Button",
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
            .disabled(true)
        
        ZashiButton(
            "Button",
            type: .secondary,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
            .disabled(true)
        
        ZashiButton(
            "Button",
            type: .tertiary,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
            .disabled(true)
        
        ZashiButton(
            "Button",
            type: .quaternary,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
            .disabled(true)
        
        ZashiButton(
            "Button",
            type: .destructive1,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
            .disabled(true)
        
        ZashiButton(
            "Button",
            type: .destructive2,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
            .disabled(true)
        
        ZashiButton(
            "Button",
            type: .brand,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
            .disabled(true)
        
        ZashiButton(
            "Button",
            type: .ghost,
            prefixView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary),
            accessoryView:
                Asset.Assets.Icons.key.image
                    .zImage(size: 20, style: Design.Text.primary)
        ) {}
            .disabled(true)
    }
    .screenHorizontalPadding()
}
