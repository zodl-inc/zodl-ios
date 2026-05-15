//
//  SecantTextStyles.swift
//  Zashi
//
//  Created by Francisco Gindre on 10/28/21.
//

import Foundation
import SwiftUI

extension Text {
    func captionText() -> some View {
        self.modifier(CaptionTextStyle())
    }

    func bodyText() -> some View {
        self.modifier(BodyTextStyle())
    }

    func titleText() -> some View {
        self.modifier(TitleTextStyle())
    }

    func paragraphText() -> some View {
        self.modifier(ParagraphStyle())
    }

    /// Body text style. Used for content.  Roboto-Regular 18pt
    private struct BodyTextStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .foregroundColor(Asset.Colors.primary.color)
                .font(
                    .custom(FontFamily.Inter.regular.name, size: 18)
                )
        }
    }

    /// Used for additional information, explanations, context (usually paragraphs)
    private struct ParagraphStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .foregroundColor(Asset.Colors.primary.color)
                .font(
                    .custom(FontFamily.Inter.regular.name, size: 16)
                )
        }
    }

    private struct TitleTextStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .foregroundColor(Asset.Colors.primary.color)
                .font(
                    .custom(FontFamily.Inter.regular.name, size: 24)
                )
                .shadow(color: Asset.Colors.primary.color, radius: 1, x: 0, y: 1)
        }
    }

    private struct CaptionTextStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .foregroundColor(Asset.Colors.primary.color)
                .font(
                    .custom(FontFamily.Inter.regular.name, size: 16)
                )
                .shadow(color: Asset.Colors.primary.color, radius: 1, x: 0, y: 1)
        }
    }
}
