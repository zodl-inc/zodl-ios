//
//  ZashiFont.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-16-2024
//

import SwiftUI

import Generated

public struct ZashiFontModifier: ViewModifier {
    public enum InternalFontFamily {
        case inter
        case michroma
        case robotoMono
    }
    
    public enum FontWeight: Equatable {
        case black
        case blackItalic
        case bold
        case boldItalic
        case extraBold
        case extraBoldItalic
        case extraLight
        case extraLightItalic
        case italic
        case light
        case lightItalic
        case medium
        case mediumItalic
        case regular
        case semiBold
        case semiBoldItalic
        case thin
        case thinItalic
    }
    
    let weight: FontWeight
    let fontFamily: ZashiFontModifier.InternalFontFamily
    let size: CGFloat
    let color: Color?
    let style: Colorable?

    public func body(content: Content) -> some View {
        if let color {
            content
                .font(.custom(fontName(weight, fontFamily: fontFamily), size: size))
                .foregroundColor(color)
        } else if let style {
            content
                .font(.custom(fontName(weight, fontFamily: fontFamily), size: size))
                .zForegroundColor(style)
        } else {
            EmptyView()
        }
    }
    
    private func fontName(_ weight: FontWeight, fontFamily: ZashiFontModifier.InternalFontFamily = .inter) -> String {
        if fontFamily == .robotoMono {
            switch weight {
            case .bold: return FontFamily.RobotoMono.bold.name
            case .medium: return FontFamily.RobotoMono.medium.name
            case .semiBold: return FontFamily.RobotoMono.semiBold.name
            default: return FontFamily.RobotoMono.regular.name
            }
        } else if fontFamily == .inter {
            switch weight {
            case .black: return FontFamily.Inter.black.name
            case .blackItalic: return FontFamily.Inter.blackItalic.name
            case .bold: return FontFamily.Inter.bold.name
            case .boldItalic: return FontFamily.Inter.boldItalic.name
            case .extraBold: return FontFamily.Inter.extraBold.name
            case .extraBoldItalic: return FontFamily.Inter.extraBoldItalic.name
            case .extraLight: return FontFamily.Inter.extraLight.name
            case .extraLightItalic: return FontFamily.Inter.extraLightItalic.name
            case .italic: return FontFamily.Inter.italic.name
            case .light: return FontFamily.Inter.light.name
            case .lightItalic: return FontFamily.Inter.lightItalic.name
            case .medium: return FontFamily.Inter.medium.name
            case .mediumItalic: return FontFamily.Inter.mediumItalic.name
            case .regular: return FontFamily.Inter.regular.name
            case .semiBold: return FontFamily.Inter.semiBold.name
            case .semiBoldItalic: return FontFamily.Inter.semiBoldItalic.name
            case .thin: return FontFamily.Inter.thin.name
            case .thinItalic: return FontFamily.Inter.thinItalic.name
            }
        } else {
            switch weight {
            case .regular: return FontFamily.Michroma.regular.name
            default: return FontFamily.Michroma.regular.name
            }
        }
    }
}

public extension View {
    func zFont(
        _ weight: ZashiFontModifier.FontWeight = .regular,
        fontFamily: ZashiFontModifier.InternalFontFamily = .inter,
        size: CGFloat,
        style: Colorable
    ) -> some View {
        self.modifier(
            ZashiFontModifier(weight: weight, fontFamily: fontFamily, size: size, color: nil, style: style)
        )
    }
    
    func zFont(
        _ weight: ZashiFontModifier.FontWeight = .regular,
        fontFamily: ZashiFontModifier.InternalFontFamily = .inter,
        size: CGFloat,
        color: Color
    ) -> some View {
        self.modifier(
            ZashiFontModifier(weight: weight, fontFamily: fontFamily, size: size, color: color, style: nil)
        )
    }
}
