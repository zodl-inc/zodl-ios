//
//  DesignSystem.swift
//  Zashi
//
//  Created by Lukáš Korba on 28.08.2024.
//

import Foundation
import SwiftUI

public protocol Colorable {
    func color(_ colorScheme: ColorScheme) -> Color
}

public enum Design: Colorable {
    
    case screenBackground
    
    // MARK: Color Variables
    
    public enum Surfaces: Colorable {
        case bgPrimary
        case bgAdjust
        case bgSecondary
        case bgTertiary
        case bgQuaternary
        case strokePrimary
        case strokeSecondary
        case strokeTertiary
        case bgAlt
        case bgHide
        case brandPrimary
        case brandSecondary
        case brandFg
        case divider
    }
    
    public enum Text: Colorable {
        case primary
        case secondary
        case tertiary
        case quaternary
        case support
        case disabled
        case error
        case link
        case opposite
        case oppositeSupport
    }
    
    public enum Btns {
        public enum Primary: Colorable {
            case bg
            case bgHover
            case fg
            case bgDisabled
            case fgDisabled
        }
        
        public enum Secondary: Colorable {
            case bg
            case bgHover
            case fg
            case fgHover
            case border
            case borderHover
            case bgDisabled
            case fgDisabled
            case disabledStroke
        }
        
        public enum Tertiary: Colorable {
            case bg
            case bgHover
            case fg
            case fgHover
            case bgDisabled
            case fgDisabled
        }
        
        public enum Quaternary: Colorable {
            case bg
            case bgHover
            case fg
            case fgHover
            case bgDisabled
            case fgDisabled
        }
        
        public enum Destructive1: Colorable {
            case bg
            case bgHover
            case fg
            case fgHover
            case border
            case borderHover
            case bgDisabled
            case fgDisabled
        }
        
        public enum Destructive2: Colorable {
            case bg
            case bgHover
            case fg
            case bgDisabled
            case fgDisabled
        }
        
        public enum Brand: Colorable {
            case bg
            case bgHover
            case fg
            case fgHover
            case bgDisabled
            case fgDisabled
        }
        
        public enum Ghost: Colorable {
            case bg
            case bgHover
            case fg
            case bgDisabled
            case fgDisabled
        }
    }
    
    public enum Tags: Colorable {
        case tcDefaultFg
        case tcHoverBg
        case tcHoverFg
        case tcCountBg
        case tcCountFg
        case surfaceIndicator
        case surfacePrimary
        case surfaceStroke
    }
    
    public enum Inputs {
        public enum Default: Colorable {
            case bg
            case bgAlt
            case label
            case text
            case hint
            case required
            case icon
            case stroke
        }
        
        public enum Filled: Colorable {
            case bg
            case bgAlt
            case asideBg
            case stroke
            case label
            case text
            case hint
            case icon
            case iconMain
            case required
        }
        
        public enum ErrorFilled: Colorable {
            case bg
            case bgAlt
            case label
            case text
            case textAside
            case hint
            case icon
            case iconMain
            case stroke
            case strokeAlt
            case dropdown
        }
    }
    
    public enum Avatars: Colorable {
        case profileBorder
        case bg
        case bgSecondary
        case status
        case textFg
        case badgeBg
        case badgeFg
    }
    
    public enum Switcher: Colorable {
        case defaultText
        case selectedBg
        case selectedIcon
        case selectedText
        case selectedTagBg
        case selectedStroke
        case surfacePrimary
    }
    
    public enum Checkboxes: Colorable {
        case offBg
        case offStroke
        case offHoverBg
        case offHoverStroke
        case offDisabledBg
        case offDisabledStroke
        case onBg
        case onFg
        case onHoverBg
        case onDisabledBg
        case onDisabledStroke
        case onDisabledFb
    }
    
    public enum HintTooltips: Colorable {
        case surfacePrimary
        case defaultBg
        case defaultFg
        case hoverBg
        case hoverFg
        case focusedBg
        case focusedStroke
        case disabledBg
        case disabledFg
        case titleText
        case bodyText
    }
    
    public enum Dropdowns {
        public enum Default: Colorable {
            case bg
            case label
            case text
            case hint
            case required
            case icon
            case dropdown
            case active
        }
        
        public enum Disabled: Colorable {
            case bg
            case stroke
            case dropdown
        }
    }
    
    public enum Utility {
        public enum Gray: Colorable {
            case _50
            case _100
            case _200
            case _300
            case _400
            case _500
            case _600
            case _700
            case _800
            case _900
            case _950
        }
        
        public enum SuccessGreen: Colorable {
            case _50
            case _100
            case _200
            case _300
            case _400
            case _500
            case _600
            case _700
            case _800
            case _900
            case _950
        }
        
        public enum ErrorRed: Colorable {
            case _50
            case _100
            case _200
            case _300
            case _400
            case _500
            case _600
            case _700
            case _800
            case _900
            case _950
        }
        
        public enum WarningYellow: Colorable {
            case _50
            case _100
            case _200
            case _300
            case _400
            case _500
            case _600
            case _700
            case _800
            case _900
            case _950
        }
        
        public enum HyperBlue: Colorable {
            case _50
            case _100
            case _200
            case _300
            case _400
            case _500
            case _600
            case _700
            case _800
            case _900
            case _950
        }
        
        public enum Indigo: Colorable {
            case _50
            case _100
            case _200
            case _300
            case _400
            case _500
            case _600
            case _700
            case _800
            case _900
            case _950
        }
        
        public enum Purple: Colorable {
            case _50
            case _100
            case _200
            case _300
            case _400
            case _500
            case _600
            case _700
            case _800
            case _900
            case _950
        }
        
        public enum Brand: Colorable {
            case _50
            case _100
            case _200
            case _300
            case _400
            case _500
            case _600
            case _700
            case _800
            case _900
            case _950
        }
    }
    
    // MARK: - Corner Radius Constants
    
    public enum Radius {
        public static let _none: CGFloat = 0
        public static let _xxs: CGFloat = 2
        public static let _xs: CGFloat = 4
        public static let _sm: CGFloat = 6
        public static let _md: CGFloat = 8
        public static let _lg: CGFloat = 10
        public static let _xl: CGFloat = 12
        public static let _2xl: CGFloat = 16
        public static let _3xl: CGFloat = 20
        public static let _4xl: CGFloat = 24
        public static let _5xl: CGFloat = 32
        public static let _full: CGFloat = 9999
    }
    
    // MARK: - Spacing Constants
    
    public enum Spacing {
        public static let _none: CGFloat = 0
        public static let _xxs: CGFloat = 2
        public static let _xs: CGFloat = 4
        public static let _sm: CGFloat = 6
        public static let _md: CGFloat = 8
        public static let _lg: CGFloat = 12
        public static let _xl: CGFloat = 16
        public static let _2xl: CGFloat = 20
        public static let _3xl: CGFloat = 24
        public static let _4xl: CGFloat = 32
        public static let _5xl: CGFloat = 40
        public static let _6xl: CGFloat = 48
        public static let _7xl: CGFloat = 64
        public static let _8xl: CGFloat = 80
        public static let _9xl: CGFloat = 96
        public static let _10xl: CGFloat = 128
        public static let _11xl: CGFloat = 160
        
        public static var sheetBottomSpace: CGFloat {
            if #available(iOS 26, *) {
                return 0
            } else {
                return 24
            }
        }

        public static var edgeToEdgeSpacing: CGFloat {
            if #available(iOS 26, *) {
                return 12
            } else {
                return 0
            }
        }
        
        public static var navBarButtonPadding: CGFloat {
            if #available(iOS 26, *) {
                return 0
            } else {
                return 8
            }
        }
    }
}

public extension Design {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .screenBackground: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.Base.midnight.color, colorScheme)
        }
    }
}

// MARK: Color Variable Values

public extension Design.Surfaces {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bgPrimary: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.Base.midnight.color, colorScheme)
        case .bgAdjust: return Design.col(Asset.Colors.ZDesign.Base.concrete.color, Asset.Colors.ZDesign.sharkShades02dp.color, colorScheme)
        case .bgSecondary: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .bgTertiary: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case .bgQuaternary: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .strokePrimary: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .strokeSecondary: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case .strokeTertiary: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .bgAlt: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.Base.bone.color, colorScheme)
        case .bgHide: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.Base.midnight.color, colorScheme)
        case .brandPrimary: return Design.col(Asset.Colors.ZDesign.Base.brand.color, Asset.Colors.ZDesign.Base.brand.color, colorScheme)
        case .brandSecondary: return Design.col(Asset.Colors.ZDesign.brand300.color, Asset.Colors.ZDesign.brand600.color, colorScheme)
        case .brandFg: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.Base.midnight.color, colorScheme)
        case .divider: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        }
    }
}

public extension Design.Text {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .primary: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .secondary: return Design.col(Asset.Colors.ZDesign.gray800.color, Asset.Colors.ZDesign.shark200.color, colorScheme)
        case .tertiary: return Design.col(Asset.Colors.ZDesign.gray700.color, Asset.Colors.ZDesign.shark200.color, colorScheme)
        case .quaternary: return Design.col(Asset.Colors.ZDesign.gray600.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case .support: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .disabled: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case .error: return Design.col(Asset.Colors.ZDesign.errorRed500.color, Asset.Colors.ZDesign.errorRed300.color, colorScheme)
        case .link: return Design.col(Asset.Colors.ZDesign.hyperBlue500.color, Asset.Colors.ZDesign.hyperBlue300.color, colorScheme)
        case .opposite: return Design.col(Asset.Colors.ZDesign.gray25.color, Asset.Colors.ZDesign.Base.obsidian.color, colorScheme)
        case .oppositeSupport: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        }
    }
}

public extension Design.Btns.Primary {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.Base.bone.color, colorScheme)
        case .bgHover: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.gray100.color, colorScheme)
        case .fg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.Base.obsidian.color, colorScheme)
        case .bgDisabled: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fgDisabled: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        }
    }
}

public extension Design.Btns.Secondary {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.Base.midnight.color, colorScheme)
        case .bgHover: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fg: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .fgHover: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .border: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .borderHover: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case .bgDisabled: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fgDisabled: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case .disabledStroke: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        }
    }
}

public extension Design.Btns.Tertiary {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .bgHover: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case .fg: return Design.col(Asset.Colors.ZDesign.gray700.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case .fgHover: return Design.col(Asset.Colors.ZDesign.gray700.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case .bgDisabled: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fgDisabled: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        }
    }
}

public extension Design.Btns.Quaternary {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .bgHover: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case .fg: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .fgHover: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .bgDisabled: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fgDisabled: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        }
    }
}

public extension Design.Btns.Destructive1 {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.errorRed950.color, colorScheme)
        case .bgHover: return Design.col(Asset.Colors.ZDesign.errorRed50.color, Asset.Colors.ZDesign.espresso900.color, colorScheme)
        case .fg: return Design.col(Asset.Colors.ZDesign.errorRed600.color, Asset.Colors.ZDesign.errorRed100.color, colorScheme)
        case .fgHover: return Design.col(Asset.Colors.ZDesign.errorRed700.color, Asset.Colors.ZDesign.errorRed50.color, colorScheme)
        case .border: return Design.col(Asset.Colors.ZDesign.errorRed300.color, Asset.Colors.ZDesign.errorRed800.color, colorScheme)
        case .borderHover: return Design.col(Asset.Colors.ZDesign.errorRed300.color, Asset.Colors.ZDesign.errorRed700.color, colorScheme)
        case .bgDisabled: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fgDisabled: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        }
    }
}

public extension Design.Btns.Destructive2 {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.errorRed600.color, Asset.Colors.ZDesign.errorRed600.color, colorScheme)
        case .bgHover: return Design.col(Asset.Colors.ZDesign.errorRed700.color, Asset.Colors.ZDesign.errorRed700.color, colorScheme)
        case .fg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.errorRed50.color, colorScheme)
        case .bgDisabled: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fgDisabled: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        }
    }
}

public extension Design.Btns.Brand {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.brand400.color, Asset.Colors.ZDesign.brand400.color, colorScheme)
        case .bgHover: return Design.col(Asset.Colors.ZDesign.brand300.color, Asset.Colors.ZDesign.brand300.color, colorScheme)
        case .fg: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.Base.obsidian.color, colorScheme)
        case .fgHover: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.Base.obsidian.color, colorScheme)
        case .bgDisabled: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fgDisabled: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        }
    }
}

public extension Design.Btns.Ghost {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark950.color, colorScheme)
        case .bgHover: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.gray900.color, colorScheme)
        case .fg: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .bgDisabled: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .fgDisabled: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        }
    }
}

public extension Design.Tags {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .tcDefaultFg: return Design.col(Asset.Colors.ZDesign.gray400.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case .tcHoverBg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case .tcHoverFg: return Design.col(Asset.Colors.ZDesign.gray600.color, Asset.Colors.ZDesign.shark200.color, colorScheme)
        case .tcCountBg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .tcCountFg: return Design.col(Asset.Colors.ZDesign.gray700.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case .surfaceIndicator: return Design.col(Asset.Colors.ZDesign.successGreen600.color, Asset.Colors.ZDesign.successGreen500.color, colorScheme)
        case .surfacePrimary: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.Base.midnight.color, colorScheme)
        case .surfaceStroke: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        }
    }
}

public extension Design.Inputs.Default {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .bgAlt: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark950.color, colorScheme)
        case .label: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .text: return Design.col(Asset.Colors.ZDesign.gray600.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .hint: return Design.col(Asset.Colors.ZDesign.gray700.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case .required: return Design.col(Asset.Colors.ZDesign.errorRed600.color, Asset.Colors.ZDesign.errorRed400.color, colorScheme)
        case .icon: return Design.col(Asset.Colors.ZDesign.gray400.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .stroke: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        }
    }
}

public extension Design.Inputs.Filled {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .bgAlt: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark950.color, colorScheme)
        case .asideBg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .stroke: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .label: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .text: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark100.color, colorScheme)
        case .hint: return Design.col(Asset.Colors.ZDesign.gray700.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case .icon: return Design.col(Asset.Colors.ZDesign.gray400.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .iconMain: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case .required: return Design.col(Asset.Colors.ZDesign.errorRed600.color, Asset.Colors.ZDesign.errorRed400.color, colorScheme)
        }
    }
}

public extension Design.Inputs.ErrorFilled {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark950.color, colorScheme)
        case .bgAlt: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .label: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .text: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark100.color, colorScheme)
        case .textAside: return Design.col(Asset.Colors.ZDesign.gray600.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .hint: return Design.col(Asset.Colors.ZDesign.errorRed600.color, Asset.Colors.ZDesign.errorRed400.color, colorScheme)
        case .icon: return Design.col(Asset.Colors.ZDesign.errorRed500.color, Asset.Colors.ZDesign.errorRed400.color, colorScheme)
        case .iconMain: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case .stroke: return Design.col(Asset.Colors.ZDesign.errorRed400.color, Asset.Colors.ZDesign.errorRed500.color, colorScheme)
        case .strokeAlt: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .dropdown: return Design.col(Asset.Colors.ZDesign.gray400.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        }
    }
}

public extension Design.Avatars {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .profileBorder: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.Base.obsidian.color, colorScheme)
        case .bg: return Design.col(Asset.Colors.ZDesign.gray600.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case .bgSecondary: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case .status: return Design.col(Asset.Colors.ZDesign.successGreen500.color, Asset.Colors.ZDesign.successGreen400.color, colorScheme)
        case .textFg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark100.color, colorScheme)
        case .badgeBg: return Design.col(Asset.Colors.ZDesign.hyperBlue400.color, Asset.Colors.ZDesign.hyperBlue400.color, colorScheme)
        case .badgeFg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.Base.obsidian.color, colorScheme)
        }
    }
}

public extension Design.Switcher {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .defaultText: return Design.col(Asset.Colors.ZDesign.gray800.color, Asset.Colors.ZDesign.shark200.color, colorScheme)
        case .selectedBg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .selectedIcon: return Design.col(Asset.Colors.ZDesign.gray600.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case .selectedText: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .selectedTagBg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark100.color, colorScheme)
        case .selectedStroke: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark200.color, colorScheme)
        case .surfacePrimary: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        }
    }
}
            
public extension Design.Checkboxes {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .offBg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .offStroke: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .offHoverBg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case .offHoverStroke: return Design.col(Asset.Colors.ZDesign.gray400.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .offDisabledBg: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .offDisabledStroke: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case .onBg: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .onFg: return Design.col(Asset.Colors.ZDesign.Base.bone.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .onHoverBg: return Design.col(Asset.Colors.ZDesign.gray800.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case .onDisabledBg: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .onDisabledStroke: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case .onDisabledFb: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        }
    }
}

public extension Design.HintTooltips {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .surfacePrimary: return Design.col(Asset.Colors.ZDesign.gray950.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case .defaultBg: return Design.col(Asset.Colors.ZDesign.gray950.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case .defaultFg: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark200.color, colorScheme)
        case .hoverBg: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .hoverFg: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark200.color, colorScheme)
        case .focusedBg: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case .focusedStroke: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case .disabledBg: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case .disabledFg: return Design.col(Asset.Colors.ZDesign.gray400.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case .titleText: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .bodyText: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        }
    }
}

public extension Design.Dropdowns.Default {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .label: return Design.col(Asset.Colors.ZDesign.Base.obsidian.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        case .text: return Design.col(Asset.Colors.ZDesign.gray600.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .hint: return Design.col(Asset.Colors.ZDesign.gray700.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case .required: return Design.col(Asset.Colors.ZDesign.errorRed600.color, Asset.Colors.ZDesign.errorRed400.color, colorScheme)
        case .icon: return Design.col(Asset.Colors.ZDesign.gray400.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case .dropdown: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case .active: return Design.col(Asset.Colors.ZDesign.successGreen500.color, Asset.Colors.ZDesign.successGreen400.color, colorScheme)
        }
    }
}

public extension Design.Dropdowns.Disabled {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case .bg: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case .stroke: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case .dropdown: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        }
    }
}

public extension Design.Utility.Gray {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case ._50: return Design.col(Asset.Colors.ZDesign.gray50.color, Asset.Colors.ZDesign.shark950.color, colorScheme)
        case ._100: return Design.col(Asset.Colors.ZDesign.gray100.color, Asset.Colors.ZDesign.shark900.color, colorScheme)
        case ._200: return Design.col(Asset.Colors.ZDesign.gray200.color, Asset.Colors.ZDesign.shark800.color, colorScheme)
        case ._300: return Design.col(Asset.Colors.ZDesign.gray300.color, Asset.Colors.ZDesign.shark700.color, colorScheme)
        case ._400: return Design.col(Asset.Colors.ZDesign.gray400.color, Asset.Colors.ZDesign.shark600.color, colorScheme)
        case ._500: return Design.col(Asset.Colors.ZDesign.gray500.color, Asset.Colors.ZDesign.shark500.color, colorScheme)
        case ._600: return Design.col(Asset.Colors.ZDesign.gray600.color, Asset.Colors.ZDesign.shark400.color, colorScheme)
        case ._700: return Design.col(Asset.Colors.ZDesign.gray700.color, Asset.Colors.ZDesign.shark300.color, colorScheme)
        case ._800: return Design.col(Asset.Colors.ZDesign.gray800.color, Asset.Colors.ZDesign.shark200.color, colorScheme)
        case ._900: return Design.col(Asset.Colors.ZDesign.gray900.color, Asset.Colors.ZDesign.shark100.color, colorScheme)
        case ._950: return Design.col(Asset.Colors.ZDesign.gray950.color, Asset.Colors.ZDesign.shark50.color, colorScheme)
        }
    }
}

public extension Design.Utility.SuccessGreen {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case ._50: return Design.col(Asset.Colors.ZDesign.successGreen50.color, Asset.Colors.ZDesign.successGreen950.color, colorScheme)
        case ._100: return Design.col(Asset.Colors.ZDesign.successGreen100.color, Asset.Colors.ZDesign.successGreen900.color, colorScheme)
        case ._200: return Design.col(Asset.Colors.ZDesign.successGreen200.color, Asset.Colors.ZDesign.successGreen800.color, colorScheme)
        case ._300: return Design.col(Asset.Colors.ZDesign.successGreen300.color, Asset.Colors.ZDesign.successGreen700.color, colorScheme)
        case ._400: return Design.col(Asset.Colors.ZDesign.successGreen400.color, Asset.Colors.ZDesign.successGreen600.color, colorScheme)
        case ._500: return Design.col(Asset.Colors.ZDesign.successGreen500.color, Asset.Colors.ZDesign.successGreen500.color, colorScheme)
        case ._600: return Design.col(Asset.Colors.ZDesign.successGreen600.color, Asset.Colors.ZDesign.successGreen400.color, colorScheme)
        case ._700: return Design.col(Asset.Colors.ZDesign.successGreen700.color, Asset.Colors.ZDesign.successGreen300.color, colorScheme)
        case ._800: return Design.col(Asset.Colors.ZDesign.successGreen800.color, Asset.Colors.ZDesign.successGreen200.color, colorScheme)
        case ._900: return Design.col(Asset.Colors.ZDesign.successGreen900.color, Asset.Colors.ZDesign.successGreen100.color, colorScheme)
        case ._950: return Design.col(Asset.Colors.ZDesign.successGreen950.color, Asset.Colors.ZDesign.successGreen50.color, colorScheme)
        }
    }
}

public extension Design.Utility.ErrorRed {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case ._50: return Design.col(Asset.Colors.ZDesign.errorRed50.color, Asset.Colors.ZDesign.errorRed950.color, colorScheme)
        case ._100: return Design.col(Asset.Colors.ZDesign.errorRed100.color, Asset.Colors.ZDesign.errorRed900.color, colorScheme)
        case ._200: return Design.col(Asset.Colors.ZDesign.errorRed200.color, Asset.Colors.ZDesign.errorRed800.color, colorScheme)
        case ._300: return Design.col(Asset.Colors.ZDesign.errorRed300.color, Asset.Colors.ZDesign.errorRed700.color, colorScheme)
        case ._400: return Design.col(Asset.Colors.ZDesign.errorRed400.color, Asset.Colors.ZDesign.errorRed600.color, colorScheme)
        case ._500: return Design.col(Asset.Colors.ZDesign.errorRed500.color, Asset.Colors.ZDesign.errorRed500.color, colorScheme)
        case ._600: return Design.col(Asset.Colors.ZDesign.errorRed600.color, Asset.Colors.ZDesign.errorRed400.color, colorScheme)
        case ._700: return Design.col(Asset.Colors.ZDesign.errorRed700.color, Asset.Colors.ZDesign.errorRed300.color, colorScheme)
        case ._800: return Design.col(Asset.Colors.ZDesign.errorRed800.color, Asset.Colors.ZDesign.errorRed200.color, colorScheme)
        case ._900: return Design.col(Asset.Colors.ZDesign.errorRed900.color, Asset.Colors.ZDesign.errorRed100.color, colorScheme)
        case ._950: return Design.col(Asset.Colors.ZDesign.errorRed900.color, Asset.Colors.ZDesign.errorRed50.color, colorScheme)
        }
    }
}

public extension Design.Utility.WarningYellow {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case ._50: return Design.col(Asset.Colors.ZDesign.warningYellow50.color, Asset.Colors.ZDesign.warningYellow950.color, colorScheme)
        case ._100: return Design.col(Asset.Colors.ZDesign.warningYellow100.color, Asset.Colors.ZDesign.warningYellow900.color, colorScheme)
        case ._200: return Design.col(Asset.Colors.ZDesign.warningYellow200.color, Asset.Colors.ZDesign.warningYellow800.color, colorScheme)
        case ._300: return Design.col(Asset.Colors.ZDesign.warningYellow300.color, Asset.Colors.ZDesign.warningYellow700.color, colorScheme)
        case ._400: return Design.col(Asset.Colors.ZDesign.warningYellow400.color, Asset.Colors.ZDesign.warningYellow600.color, colorScheme)
        case ._500: return Design.col(Asset.Colors.ZDesign.warningYellow500.color, Asset.Colors.ZDesign.warningYellow500.color, colorScheme)
        case ._600: return Design.col(Asset.Colors.ZDesign.warningYellow600.color, Asset.Colors.ZDesign.warningYellow400.color, colorScheme)
        case ._700: return Design.col(Asset.Colors.ZDesign.warningYellow700.color, Asset.Colors.ZDesign.warningYellow300.color, colorScheme)
        case ._800: return Design.col(Asset.Colors.ZDesign.warningYellow800.color, Asset.Colors.ZDesign.warningYellow200.color, colorScheme)
        case ._900: return Design.col(Asset.Colors.ZDesign.warningYellow900.color, Asset.Colors.ZDesign.warningYellow100.color, colorScheme)
        case ._950: return Design.col(Asset.Colors.ZDesign.warningYellow900.color, Asset.Colors.ZDesign.warningYellow50.color, colorScheme)
        }
    }
}

public extension Design.Utility.HyperBlue {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case ._50: return Design.col(Asset.Colors.ZDesign.hyperBlue50.color, Asset.Colors.ZDesign.hyperBlue950.color, colorScheme)
        case ._100: return Design.col(Asset.Colors.ZDesign.hyperBlue100.color, Asset.Colors.ZDesign.hyperBlue900.color, colorScheme)
        case ._200: return Design.col(Asset.Colors.ZDesign.hyperBlue200.color, Asset.Colors.ZDesign.hyperBlue800.color, colorScheme)
        case ._300: return Design.col(Asset.Colors.ZDesign.hyperBlue300.color, Asset.Colors.ZDesign.hyperBlue700.color, colorScheme)
        case ._400: return Design.col(Asset.Colors.ZDesign.hyperBlue400.color, Asset.Colors.ZDesign.hyperBlue600.color, colorScheme)
        case ._500: return Design.col(Asset.Colors.ZDesign.hyperBlue500.color, Asset.Colors.ZDesign.hyperBlue500.color, colorScheme)
        case ._600: return Design.col(Asset.Colors.ZDesign.hyperBlue600.color, Asset.Colors.ZDesign.hyperBlue400.color, colorScheme)
        case ._700: return Design.col(Asset.Colors.ZDesign.hyperBlue700.color, Asset.Colors.ZDesign.hyperBlue300.color, colorScheme)
        case ._800: return Design.col(Asset.Colors.ZDesign.hyperBlue800.color, Asset.Colors.ZDesign.hyperBlue200.color, colorScheme)
        case ._900: return Design.col(Asset.Colors.ZDesign.hyperBlue900.color, Asset.Colors.ZDesign.hyperBlue100.color, colorScheme)
        case ._950: return Design.col(Asset.Colors.ZDesign.hyperBlue900.color, Asset.Colors.ZDesign.hyperBlue50.color, colorScheme)
        }
    }
}

public extension Design.Utility.Indigo {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case ._50: return Design.col(Asset.Colors.ZDesign.indigo50.color, Asset.Colors.ZDesign.indigo950.color, colorScheme)
        case ._100: return Design.col(Asset.Colors.ZDesign.indigo100.color, Asset.Colors.ZDesign.indigo900.color, colorScheme)
        case ._200: return Design.col(Asset.Colors.ZDesign.indigo200.color, Asset.Colors.ZDesign.indigo800.color, colorScheme)
        case ._300: return Design.col(Asset.Colors.ZDesign.indigo300.color, Asset.Colors.ZDesign.indigo700.color, colorScheme)
        case ._400: return Design.col(Asset.Colors.ZDesign.indigo400.color, Asset.Colors.ZDesign.indigo600.color, colorScheme)
        case ._500: return Design.col(Asset.Colors.ZDesign.indigo500.color, Asset.Colors.ZDesign.indigo500.color, colorScheme)
        case ._600: return Design.col(Asset.Colors.ZDesign.indigo600.color, Asset.Colors.ZDesign.indigo400.color, colorScheme)
        case ._700: return Design.col(Asset.Colors.ZDesign.indigo700.color, Asset.Colors.ZDesign.indigo300.color, colorScheme)
        case ._800: return Design.col(Asset.Colors.ZDesign.indigo800.color, Asset.Colors.ZDesign.indigo200.color, colorScheme)
        case ._900: return Design.col(Asset.Colors.ZDesign.indigo900.color, Asset.Colors.ZDesign.indigo100.color, colorScheme)
        case ._950: return Design.col(Asset.Colors.ZDesign.indigo900.color, Asset.Colors.ZDesign.indigo50.color, colorScheme)
        }
    }
}

public extension Design.Utility.Purple {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case ._50: return Design.col(Asset.Colors.ZDesign.purple50.color, Asset.Colors.ZDesign.purple950.color, colorScheme)
        case ._100: return Design.col(Asset.Colors.ZDesign.purple100.color, Asset.Colors.ZDesign.purple900.color, colorScheme)
        case ._200: return Design.col(Asset.Colors.ZDesign.purple200.color, Asset.Colors.ZDesign.purple800.color, colorScheme)
        case ._300: return Design.col(Asset.Colors.ZDesign.purple300.color, Asset.Colors.ZDesign.purple700.color, colorScheme)
        case ._400: return Design.col(Asset.Colors.ZDesign.purple400.color, Asset.Colors.ZDesign.purple600.color, colorScheme)
        case ._500: return Design.col(Asset.Colors.ZDesign.purple500.color, Asset.Colors.ZDesign.purple500.color, colorScheme)
        case ._600: return Design.col(Asset.Colors.ZDesign.purple600.color, Asset.Colors.ZDesign.purple400.color, colorScheme)
        case ._700: return Design.col(Asset.Colors.ZDesign.purple700.color, Asset.Colors.ZDesign.purple300.color, colorScheme)
        case ._800: return Design.col(Asset.Colors.ZDesign.purple800.color, Asset.Colors.ZDesign.purple200.color, colorScheme)
        case ._900: return Design.col(Asset.Colors.ZDesign.purple900.color, Asset.Colors.ZDesign.purple100.color, colorScheme)
        case ._950: return Design.col(Asset.Colors.ZDesign.purple950.color, Asset.Colors.ZDesign.purple50.color, colorScheme)
        }
    }
}

public extension Design.Utility.Brand {
    func color(_ colorScheme: ColorScheme) -> Color {
        switch self {
        case ._50: return Design.col(Asset.Colors.ZDesign.brand50.color, Asset.Colors.ZDesign.brand950.color, colorScheme)
        case ._100: return Design.col(Asset.Colors.ZDesign.brand100.color, Asset.Colors.ZDesign.brand900.color, colorScheme)
        case ._200: return Design.col(Asset.Colors.ZDesign.brand200.color, Asset.Colors.ZDesign.brand800.color, colorScheme)
        case ._300: return Design.col(Asset.Colors.ZDesign.brand300.color, Asset.Colors.ZDesign.brand700.color, colorScheme)
        case ._400: return Design.col(Asset.Colors.ZDesign.brand400.color, Asset.Colors.ZDesign.brand600.color, colorScheme)
        case ._500: return Design.col(Asset.Colors.ZDesign.brand500.color, Asset.Colors.ZDesign.brand500.color, colorScheme)
        case ._600: return Design.col(Asset.Colors.ZDesign.brand600.color, Asset.Colors.ZDesign.brand400.color, colorScheme)
        case ._700: return Design.col(Asset.Colors.ZDesign.brand700.color, Asset.Colors.ZDesign.brand300.color, colorScheme)
        case ._800: return Design.col(Asset.Colors.ZDesign.brand800.color, Asset.Colors.ZDesign.brand200.color, colorScheme)
        case ._900: return Design.col(Asset.Colors.ZDesign.brand900.color, Asset.Colors.ZDesign.brand100.color, colorScheme)
        case ._950: return Design.col(Asset.Colors.ZDesign.brand900.color, Asset.Colors.ZDesign.brand50.color, colorScheme)
        }
    }
}

// MARK: Helpers

private extension Design {
     static func col(_ light: Color, _ dark: Color, _ colorScheme: ColorScheme) -> Color {
         colorScheme == .light ? light : dark
    }
}

// MARK: - View Modifiers

struct ZashiForegroundColorModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    let style: Colorable

    func body(content: Content) -> some View {
        content.foregroundColor(style.color(colorScheme))
    }
}

public extension View {
    func zForegroundColor(_ style: Colorable) -> some View {
        modifier(ZashiForegroundColorModifier(style: style))
    }
}

struct ZashiColorBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    let style: Colorable

    func body(content: Content) -> some View {
        content.background(style.color(colorScheme))
    }
}

public extension View {
    func zBackground(_ style: Colorable) -> some View {
        modifier(ZashiColorBackgroundModifier(style: style))
    }
}
