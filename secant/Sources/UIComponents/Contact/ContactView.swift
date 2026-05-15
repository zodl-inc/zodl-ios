//
//  ContactView.swift
//
//
//  Created by Lukáš Korba on 09.09.2024.
//

import SwiftUI

struct ContactView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    var iconText: String
    var tickerIcon: Image?
    var title: String
    var desc: String?
    var descIsAddress: Bool
    var action: () -> Void
    
    init(
        iconText: String,
        tickerIcon: Image? = nil,
        title: String,
        desc: String? = nil,
        descIsAddress: Bool = false,
        action: @escaping () -> Void
    ) {
        self.iconText = iconText
        self.tickerIcon = tickerIcon
        self.title = title
        self.desc = desc
        self.descIsAddress = descIsAddress
        self.action = action
    }
    
    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ZStack {
                        Text(iconText)
                            .minimumScaleFactor(0.5)
                            .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                            .zForegroundColor(Design.Avatars.textFg)
                            .frame(width: 20, height: 20)
                            .padding(10)
                            .background {
                                Circle()
                                    .fill(Design.Avatars.bg.color(colorScheme))
                            }
                            .padding(.trailing, 16)
                        
                        if let tickerIcon {
                            tickerIcon
                                .zImage(size: 25, style: Design.screenBackground)
                                .offset(x: 10, y: 12)
                                .overlay {
                                    tickerIcon
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                        .offset(x: 10, y: 12)
                                }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.custom(FontFamily.Inter.semiBold.name, size: 14))
                            .zForegroundColor(Design.Text.primary)
                        
                        if let desc {
                            Text(desc)
                                .zFont(fontFamily: descIsAddress ? .robotoMono : .inter, size: 14, style: Design.Text.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.trailing, 16)
                    
                    Spacer(minLength: 2)
                    
                    Asset.Assets.chevronRight.image
                        .zImage(size: 20, style: Design.Text.tertiary)
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.top, 12)
    }
}

#Preview {
    ContactView(
        iconText: "LK",
        title: "test",
        action: { }
    )
}
