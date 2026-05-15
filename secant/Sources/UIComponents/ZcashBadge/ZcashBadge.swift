//
//  ZcashBadge.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.05.2022.
//

import SwiftUI

struct ZcashBadge: View {
    @Environment(\.colorScheme) var colorScheme

    init() {}
    
    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let outterPadding = proxy.size.height * 0.015
                let firstPadding = proxy.size.height * 0.075 + outterPadding
                let secondRingPadding = firstPadding * 1.5
                let outerShadowDrop = proxy.size.height * 0.14
                let outerShadowOffset = proxy.size.height * 0.055

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Asset.Colors.primary.color,
                                Asset.Colors.primary.color
                            ],
                            startPoint: UnitPoint(x: 0.5, y: 0),
                            endPoint: UnitPoint(x: 0.5, y: 1)
                        )
                    )
                    .if(colorScheme == .light) { view in
                        view.shadow(
                            color: Asset.Colors.primary.color,
                            radius: outerShadowDrop,
                            x: outerShadowOffset,
                            y: outerShadowOffset
                        )
                    }

                Circle()
                    .foregroundColor(Asset.Colors.primary.color)
                    .padding(outterPadding)

                Circle()
                    .foregroundColor(Asset.Colors.primary.color)
                    .padding(firstPadding)

                Circle()
                    .foregroundColor(Asset.Colors.primary.color)
                    .padding(secondRingPadding)

                ZcashSymbol()
                    .fill(Asset.Colors.primary.color)
                    .padding(firstPadding + secondRingPadding)
            }
        }
    }
}
