//
//  ZashiMarkdown.swift
//  Zashi
//
//  Self-contained parser for the unified Zashi/Android markdown grammar used in
//  localized strings. Replaces Apple's proprietary `^[text](style:'...')`
//  custom-attribute markdown (MarkdownDecodableAttributedStringKey).
//
//  Grammar (the shared iOS/Android contract):
//    **bold**        -> .bold
//    *italic*        -> .italic
//    ***boldItalic***-> .boldItalic
//    ==boldPrimary== -> .boldPrimary   (the one custom token)
//    [text](url)     -> .link (+ Foundation .link URL, so SwiftUI Text is tappable)
//
//  Rules: flat (no nesting in v1), total (never throws; unmatched markup is emitted
//  literally), backslash escapes a markdown-significant character, whitespace/newlines
//  are preserved verbatim. See docs/superpowers/specs/2026-06-22-unified-markdown-parser-design.md
//

import Foundation

enum ZashiMarkdown {
    /// Characters a leading backslash can escape into a literal.
    private static let escapable: Set<Character> = ["*", "=", "[", "]", "(", ")", "\\"]

    /// A recognized opening/closing emphasis delimiter run.
    private struct Delimiter {
        let token: [Character]
        let style: ZashiTextAttribute.Value
    }

    /// A successfully parsed `[text](url)` link.
    private struct ParsedLink {
        let text: String
        let url: URL
        let nextIndex: Int
    }

    /// Parses the unified Zashi/Android markdown grammar into a semantic `AttributedString`.
    /// Total: never throws; unmatched markup is emitted as literal text.
    static func parse(_ input: String) -> AttributedString {
        let chars = Array(input)
        let count = chars.count

        var result = AttributedString("")
        var literal = ""
        var i = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            result.append(AttributedString(literal))
            literal = ""
        }

        func appendStyled(_ text: String, style: ZashiTextAttribute.Value, url: URL? = nil) {
            guard !text.isEmpty else { return }
            var piece = AttributedString(text)
            piece.zStyle = style
            if let url {
                piece.link = url
            }
            result.append(piece)
        }

        while i < count {
            let character = chars[i]

            // 1. Escaping: a backslash makes the next significant character literal.
            if character == "\\", i + 1 < count, escapable.contains(chars[i + 1]) {
                literal.append(chars[i + 1])
                i += 2
                continue
            }

            // 2. Link: [text](url)
            if character == "[", let link = ZashiMarkdown.parseLink(chars, from: i) {
                flushLiteral()
                appendStyled(link.text, style: .link, url: link.url)
                i = link.nextIndex
                continue
            }

            // 3. Emphasis delimiter run (** , * , *** , ==).
            if let delimiter = ZashiMarkdown.delimiter(at: i, in: chars) {
                let innerStart = i + delimiter.token.count
                if let close = ZashiMarkdown.findClosing(delimiter, in: chars, after: innerStart) {
                    flushLiteral()
                    appendStyled(String(chars[innerStart..<close]), style: delimiter.style)
                    i = close + delimiter.token.count
                    continue
                }
                // Unmatched: emit the opening run literally and move past it.
                literal.append(contentsOf: chars[i..<innerStart])
                i = innerStart
                continue
            }

            // 4. Plain character.
            literal.append(character)
            i += 1
        }

        flushLiteral()
        return result
    }

    // MARK: - Helpers

    /// Recognizes an emphasis delimiter run starting at `index`. The `*` run length is
    /// capped at 3 (boldItalic); `==` is exactly two `=`.
    private static func delimiter(at index: Int, in chars: [Character]) -> Delimiter? {
        switch chars[index] {
        case "*":
            var run = 0
            var j = index
            while j < chars.count, chars[j] == "*" {
                run += 1
                j += 1
            }
            switch min(run, 3) {
            case 3: return Delimiter(token: ["*", "*", "*"], style: .boldItalic)
            case 2: return Delimiter(token: ["*", "*"], style: .bold)
            default: return Delimiter(token: ["*"], style: .italic)
            }
        case "=":
            if index + 1 < chars.count, chars[index + 1] == "=" {
                return Delimiter(token: ["=", "="], style: .boldPrimary)
            }
            return nil
        default:
            return nil
        }
    }

    /// Finds the next occurrence of the delimiter's token at or after `start`,
    /// returning the index of its first character, or nil if there is no match.
    private static func findClosing(_ delimiter: Delimiter, in chars: [Character], after start: Int) -> Int? {
        let token = delimiter.token
        let length = token.count
        var j = start
        while j + length <= chars.count {
            if Array(chars[j..<(j + length)]) == token {
                return j
            }
            j += 1
        }
        return nil
    }

    /// Parses `[text](url)` starting at `start` (which must point at `[`).
    /// Link text is taken literally (no nested parsing in v1). Returns nil on any
    /// malformation or an unparseable URL, so the caller can fall back to literal text.
    private static func parseLink(_ chars: [Character], from start: Int) -> ParsedLink? {
        let count = chars.count
        var j = start + 1
        var text = ""
        while j < count, chars[j] != "]" {
            text.append(chars[j])
            j += 1
        }
        guard j < count, chars[j] == "]" else { return nil }

        let openParen = j + 1
        guard openParen < count, chars[openParen] == "(" else { return nil }

        var k = openParen + 1
        var urlString = ""
        while k < count, chars[k] != ")" {
            urlString.append(chars[k])
            k += 1
        }
        guard k < count, chars[k] == ")" else { return nil }
        guard let url = URL(string: urlString) else { return nil }

        return ParsedLink(text: text, url: url, nextIndex: k + 1)
    }
}
