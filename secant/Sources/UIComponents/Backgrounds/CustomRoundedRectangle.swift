//
//  CustomCornerRadius.swift
//  Zodl
//
//  Created by Lukáš Korba on 10.02.2026.
//

import Foundation
import SwiftUI

struct CustomRoundedRectangle: Shape {
    var corners: UIRectCorner
    var radius: CGFloat

    init(corners: UIRectCorner, radius: CGFloat) {
        self.corners = corners
        self.radius = radius
    }
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
