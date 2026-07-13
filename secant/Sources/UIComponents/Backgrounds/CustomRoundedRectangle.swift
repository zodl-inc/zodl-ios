//
//  CustomCornerRadius.swift
//  Zodl
//
//  Created by Lukáš Korba on 10.02.2026.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Cross-platform corner set (mirrors UIKit's `UIRectCorner`) so `CustomRoundedRectangle`
/// works on both iOS and macOS.
nonisolated struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorner(rawValue: 1 << 0)
    static let topRight = RectCorner(rawValue: 1 << 1)
    static let bottomLeft = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]

#if canImport(UIKit)
    var uiRectCorner: UIRectCorner {
        var result: UIRectCorner = []
        if contains(.topLeft) { result.insert(.topLeft) }
        if contains(.topRight) { result.insert(.topRight) }
        if contains(.bottomLeft) { result.insert(.bottomLeft) }
        if contains(.bottomRight) { result.insert(.bottomRight) }
        return result
    }
#endif
}

struct CustomRoundedRectangle: Shape {
    var corners: RectCorner
    var radius: CGFloat

    init(corners: RectCorner, radius: CGFloat) {
        self.corners = corners
        self.radius = radius
    }

    func path(in rect: CGRect) -> Path {
#if canImport(UIKit)
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners.uiRectCorner,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
#else
        return UnevenRoundedRectangle(
            topLeadingRadius: corners.contains(.topLeft) ? radius : 0,
            bottomLeadingRadius: corners.contains(.bottomLeft) ? radius : 0,
            bottomTrailingRadius: corners.contains(.bottomRight) ? radius : 0,
            topTrailingRadius: corners.contains(.topRight) ? radius : 0
        ).path(in: rect)
#endif
    }
}
