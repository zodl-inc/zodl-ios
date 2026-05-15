//
//  ScrollableWhenScaled.swift
//  Zashi
//
//  Created by Francisco Gindre on 12/27/21.
//

import SwiftUI

// swiftlint:disable:next private_over_fileprivate strict_fileprivate
fileprivate struct ScrollableWhenScaledUpModifier: ViewModifier {
    @ScaledMetric var scale: CGFloat = 1

    func body(content: Content) -> some View {
        if scale > 1 {
            ScrollView {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    func scrollableWhenScaledUp() -> some View {
        self.modifier(ScrollableWhenScaledUpModifier())
    }
}
