//
//  ZashiText.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-14-2024.
//

import SwiftUI

struct ZashiText: View {
    private var attributedString: AttributedString

    var body: some View {
        Text(attributedString)
    }

    init(markdown: String, colorScheme: ColorScheme, textColor: Color? = nil, textSize: CGFloat? = nil) {
        let parsed = ZashiMarkdown.parse(markdown)
        self.attributedString = ZashiText.annotateStyle(from: parsed, colorScheme: colorScheme, textColor: textColor, textSize: textSize)
    }

    private static func annotateStyle(from source: AttributedString, colorScheme: ColorScheme, textColor: Color? = nil, textSize: CGFloat? = nil) -> AttributedString {
        var attrString = source
        for run in attrString.runs {
            if let zStyle = run.zStyle {
                var defaultTextSize: CGFloat = 14
                if let textSize {
                    defaultTextSize = textSize
                }

                switch zStyle {
                case .bold:
                    attrString[run.range].font = .system(size: defaultTextSize, weight: .bold)
                case .boldPrimary:
                    attrString[run.range].font = .system(size: defaultTextSize, weight: .bold)
                    if let textColor {
                        attrString[run.range].foregroundColor = textColor
                    } else {
                        attrString[run.range].foregroundColor = Design.Text.primary.color(colorScheme)
                    }
                case .italic:
                    attrString[run.range].font = .system(size: defaultTextSize).italic()
                case .boldItalic:
                    attrString[run.range].font = .system(size: defaultTextSize, weight: .bold).italic()
                case .link:
                    attrString[run.range].underlineStyle = .single
                }
            }
        }
        return attrString
    }
}

enum ZashiTextAttribute: AttributedStringKey {
    enum Value: String, Codable, Hashable {
        case bold
        case boldPrimary
        case italic
        case boldItalic
        case link
    }

    static let name: String = "style"
}

extension AttributeScopes {
    struct ZashiAppAttributes: AttributeScope {
        let zStyle: ZashiTextAttribute
    }

    var zashiApp: ZashiAppAttributes.Type { ZashiAppAttributes.self }
}

extension AttributeDynamicLookup {
    subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.ZashiAppAttributes, T>) -> T {
        self[T.self]
    }
}
