//
//  PrivacyBadge.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-19-2024.
//

import SwiftUI

struct PrivacyBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    
    enum Privacy {
        case low
        case max
    }
    
    let privacy: Privacy
    
    init(_ privacy: Privacy) {
        self.privacy = privacy
    }
    
    var body: some View {
        HStack(spacing: 0) {
            if privacy == .max {
                Asset.Assets.Icons.shieldTickFilled.image
                    .zImage(size: 14, style: Design.Utility.Purple._700)
                    .padding(.trailing, 4)
            } else {
                Asset.Assets.Icons.alertCircle.image
                    .zImage(size: 14, style: Design.Utility.WarningYellow._700)
                    .padding(.trailing, 4)
            }
            
            Text(privacy == .max
                 ? String(localizable: .componentMaxPrivacy)
                 : String(localizable: .componentLowPrivacy)
            )
            .zFont(
                .medium,
                size: 14,
                style: privacy == .max
                ? Design.Utility.Purple._700
                : Design.Utility.WarningYellow._700
            )
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(privacy == .max
                      ? Design.Utility.Purple._50.color(colorScheme)
                      : Design.Utility.WarningYellow._50.color(colorScheme)
                )
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                        .stroke(privacy == .max
                                ? Design.Utility.Purple._200.color(colorScheme)
                                : Design.Utility.WarningYellow._200.color(colorScheme)
                        )
                }
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        PrivacyBadge(.max)
        PrivacyBadge(.low)
    }
}
