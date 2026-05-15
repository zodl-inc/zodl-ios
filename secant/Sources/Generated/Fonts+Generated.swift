// swiftlint:disable all
// Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen

import SwiftUI
#if os(OSX)
  import AppKit.NSFont
#elseif os(iOS) || os(tvOS) || os(watchOS)
  import UIKit.UIFont
#endif

// Deprecated typealiases
@available(*, deprecated, renamed: "FontConvertible.Font", message: "This typealias will be removed in SwiftGen 7.0")
public typealias SystemFont = FontConvertible.SystemFont

// swiftlint:disable superfluous_disable_command
// swiftlint:disable file_length

// MARK: - Fonts

// swiftlint:disable identifier_name line_length type_body_length
public enum FontFamily {
  public enum Inter {
    public static let black = FontConvertible(name: "Inter-Black", family: "Inter", path: "Inter-Black.otf")
    public static let blackItalic = FontConvertible(name: "Inter-BlackItalic", family: "Inter", path: "Inter-BlackItalic.otf")
    public static let bold = FontConvertible(name: "Inter-Bold", family: "Inter", path: "Inter-Bold.otf")
    public static let boldItalic = FontConvertible(name: "Inter-BoldItalic", family: "Inter", path: "Inter-BoldItalic.otf")
    public static let extraBold = FontConvertible(name: "Inter-ExtraBold", family: "Inter", path: "Inter-ExtraBold.otf")
    public static let extraBoldItalic = FontConvertible(name: "Inter-ExtraBoldItalic", family: "Inter", path: "Inter-ExtraBoldItalic.otf")
    public static let extraLight = FontConvertible(name: "Inter-ExtraLight", family: "Inter", path: "Inter-ExtraLight.otf")
    public static let extraLightItalic = FontConvertible(name: "Inter-ExtraLightItalic", family: "Inter", path: "Inter-ExtraLightItalic.otf")
    public static let italic = FontConvertible(name: "Inter-Italic", family: "Inter", path: "Inter-Italic.otf")
    public static let light = FontConvertible(name: "Inter-Light", family: "Inter", path: "Inter-Light.otf")
    public static let lightItalic = FontConvertible(name: "Inter-LightItalic", family: "Inter", path: "Inter-LightItalic.otf")
    public static let medium = FontConvertible(name: "Inter-Medium", family: "Inter", path: "Inter-Medium.otf")
    public static let mediumItalic = FontConvertible(name: "Inter-MediumItalic", family: "Inter", path: "Inter-MediumItalic.otf")
    public static let regular = FontConvertible(name: "Inter-Regular", family: "Inter", path: "Inter-Regular.otf")
    public static let semiBold = FontConvertible(name: "Inter-SemiBold", family: "Inter", path: "Inter-SemiBold.otf")
    public static let semiBoldItalic = FontConvertible(name: "Inter-SemiBoldItalic", family: "Inter", path: "Inter-SemiBoldItalic.otf")
    public static let thin = FontConvertible(name: "Inter-Thin", family: "Inter", path: "Inter-Thin.otf")
    public static let thinItalic = FontConvertible(name: "Inter-ThinItalic", family: "Inter", path: "Inter-ThinItalic.otf")
    public static let all: [FontConvertible] = [black, blackItalic, bold, boldItalic, extraBold, extraBoldItalic, extraLight, extraLightItalic, italic, light, lightItalic, medium, mediumItalic, regular, semiBold, semiBoldItalic, thin, thinItalic]
  }
  public enum Michroma {
    public static let regular = FontConvertible(name: "Michroma-Regular", family: "Michroma", path: "Michroma-Regular.ttf")
    public static let all: [FontConvertible] = [regular]
  }
  public enum RobotoMono {
    public static let bold = FontConvertible(name: "RobotoMono-Bold", family: "Roboto Mono", path: "RobotoMono-Bold.ttf")
    public static let medium = FontConvertible(name: "RobotoMono-Medium", family: "Roboto Mono", path: "RobotoMono-Medium.ttf")
    public static let regular = FontConvertible(name: "RobotoMono-Regular", family: "Roboto Mono", path: "RobotoMono-Regular.ttf")
    public static let semiBold = FontConvertible(name: "RobotoMono-SemiBold", family: "Roboto Mono", path: "RobotoMono-SemiBold.ttf")
    public static let all: [FontConvertible] = [bold, medium, regular, semiBold]
  }
  public enum Zboto {
    public static let regular = FontConvertible(name: "ZbotoRegular", family: "Zboto", path: "Zboto.otf")
    public static let all: [FontConvertible] = [regular]
  }
  public static let allCustomFonts: [FontConvertible] = [Inter.all, Michroma.all, RobotoMono.all, Zboto.all].flatMap { $0 }
  public static func registerAllCustomFonts() {
    allCustomFonts.forEach { $0.register() }
  }
}
// swiftlint:enable identifier_name line_length type_body_length

// MARK: - Implementation Details

public struct FontConvertible {
  public let name: String
  public let family: String
  public let path: String

  #if os(OSX)
  public typealias SystemFont = NSFont
  #elseif os(iOS) || os(tvOS) || os(watchOS)
  public typealias SystemFont = UIFont
  #endif

  public func font(size: CGFloat) -> SystemFont {
    guard let font = SystemFont(font: self, size: size) else {
      fatalError("Unable to initialize font '\(name)' (\(family))")
    }
    return font
  }

  public func textStyle(_ textStyle: Font.TextStyle) -> Font {
    Font.mappedFont(name, textStyle: textStyle)
  }

  public func register() {
    // swiftlint:disable:next conditional_returns_on_newline
    guard let url = url else { return }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }

  fileprivate var url: URL? {
    // swiftlint:disable:next implicit_return
    return BundleToken.bundle.url(forResource: path, withExtension: nil)
  }
}

public extension FontConvertible.SystemFont {
  convenience init?(font: FontConvertible, size: CGFloat) {
    #if os(iOS) || os(tvOS) || os(watchOS)
    if !UIFont.fontNames(forFamilyName: font.family).contains(font.name) {
      font.register()
    }
    #elseif os(OSX)
    if let url = font.url, CTFontManagerGetScopeForURL(url as CFURL) == .none {
      font.register()
    }
    #endif

    self.init(name: font.name, size: size)
  }
}

// swiftlint:disable convenience_type
private final class BundleToken {
  static let bundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle(for: BundleToken.self)
    #endif
  }()
}

fileprivate extension Font {
  static func mappedFont(_ name: String, textStyle: TextStyle) -> Font {
    let fontSize = UIFont.preferredFont(forTextStyle: self.mapToUIFontTextStyle(textStyle)).pointSize
    return Font.custom(name, size: fontSize, relativeTo: textStyle)
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func mapToUIFontTextStyle(_ textStyle: SwiftUI.Font.TextStyle) -> UIFont.TextStyle {
    switch textStyle {
    case .largeTitle:
      return .largeTitle
    case .title:
      return .title1
    case .title2:
      return .title2
    case .title3:
      return .title3
    case .headline:
      return .headline
    case .subheadline:
      return .subheadline
    case .callout:
      return .callout
    case .body:
      return .body
    case .caption:
      return .caption1
    case .caption2:
      return .caption2
    case .footnote:
      return .footnote
    @unknown default:
      fatalError("Missing a TextStyle mapping")
    }
  }
}

// swiftlint:enable convenience_type

extension FontConvertible: @unchecked Sendable { }
// swiftlint:enable all
