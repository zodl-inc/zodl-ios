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
    
    let title: String
    let type: `Type`
    let infinityWidth: Bool
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
        fontSize: CGFloat = 16,
        horizontalPadding: CGFloat = 18,
        verticalPadding: CGFloat = 12,
        minHeight: CGFloat? = nil,
        prefixView: PrefixContent? = EmptyView(),
        accessoryView: AccessoryContent? = EmptyView(),
        action: @escaping () -> Void
    ) {
        self.title = title
        self.type = type
        self.infinityWidth = infinityWidth
        self.fontSize = fontSize
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.minHeight = minHeight
        self.accessoryView = accessoryView
        self.prefixView = prefixView
        self.action = action
    }
    
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
            .frame(maxWidth: infinityWidth ? .infinity : nil, minHeight: minHeight)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .fill(bgColor().color(colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                            .stroke(strokeColor().color(colorScheme))
                    }
            }
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
