//
//  ActionRow.swift
//  Zashi
//
//  Created by Lukáš Korba on 22.08.2024.
//

import SwiftUI

import Generated

public struct ActionRow<AccessoryContent>: View where AccessoryContent: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    
    let icon: Image
    let title: String
    let desc: String?
    let customIcon: Bool
    @ViewBuilder let accessoryView: AccessoryContent?
    let divider: Bool
    let horizontalPadding: CGFloat
    let glassBackground: Bool
    let action: () -> Void
    
    public init(
        icon: Image,
        title: String,
        desc: String? = nil,
        customIcon: Bool = false,
        accessoryView: AccessoryContent? = EmptyView(),
        divider: Bool = true,
        horizontalPadding: CGFloat = 20,
        glassBackground: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.desc = desc
        self.customIcon = customIcon
        self.accessoryView = accessoryView
        self.divider = divider
        self.horizontalPadding = horizontalPadding
        self.glassBackground = glassBackground
        self.action = action
    }
    
    public var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if customIcon {
                        icon
                            .resizable()
                            .frame(width: 40, height: 40)
                            .padding(.trailing, 16)
                    } else {
                        icon
                            .zImage(
                                size: 20,
                                style: isEnabled
                                    ? Design.Text.primary
                                    : Design.Text.disabled
                            )
                            .padding(10)
                            .background {
                                Circle()
                                    .fill(isEnabled
                                          ? Design.Surfaces.bgTertiary.color(colorScheme)
                                          : Design.Surfaces.bgSecondary.color(colorScheme))
                            }
                            .padding(.trailing, 16)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if let accessoryView {
                            HStack(spacing: 0) {
                                Text(title)
                                    .zFont(.semiBold, size: 16, style: isEnabled
                                           ? Design.Text.primary
                                           : Design.Text.disabled
                                    )
                                    .fixedSize(horizontal: false, vertical: true)
                                    .minimumScaleFactor(0.6)
                                    .lineLimit(1)

                                accessoryView
                                    .padding(.leading, 8)
                            }
                        } else {
                            Text(title)
                                .zFont(
                                    .semiBold,
                                    size: 16,
                                    style: isEnabled
                                    ? Design.Text.primary
                                    : Design.Text.disabled
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                        }
                        
                        if let desc {
                            Text(desc)
                                .zFont(size: 12, style: Design.Text.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                                .lineSpacing(1.2)
                                .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: 2)
                    
                    if isEnabled {
                        Asset.Assets.chevronRight.image
                            .zImage(size: 20, style: Design.Text.quaternary)
                    }
                }
                .padding(.horizontal, horizontalPadding)

                if divider {
                    Design.Surfaces.divider.color(colorScheme)
                        .frame(height: 1)
                        .padding(.top, 12)
                }
            }
        }
        .padding(.top, 12)
        //.background(Asset.Colors.background.color)
    }
}
