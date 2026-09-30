//
//  ZashiMarkdownParserTests.swift
//  zodlTests
//
//  Tests for the unified Zashi/Android markdown parser (ZashiMarkdown).
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct ZashiMarkdownParserTests {
    // MARK: - Helpers

    private struct Span: Equatable {
        let text: String
        let style: ZashiTextAttribute.Value?
        let link: URL?

        init(_ text: String, _ style: ZashiTextAttribute.Value?, link: URL? = nil) {
            self.text = text
            self.style = style
            self.link = link
        }
    }

    private func spans(of string: AttributedString) -> [Span] {
        string.runs.map { run in
            Span(String(string[run.range].characters), run.zStyle, link: run.link)
        }
    }

    private func plainText(of string: AttributedString) -> String {
        String(string.characters)
    }

    // MARK: - Plain text

    @Test func plainTextPassesThroughUnstyled() {
        let result = ZashiMarkdown.parse("Hello world")
        #expect(plainText(of: result) == "Hello world")
        #expect(spans(of: result) == [Span("Hello world", nil)])
    }

    @Test func emptyInputProducesEmptyString() {
        let result = ZashiMarkdown.parse("")
        #expect(plainText(of: result) == "")
    }

    // MARK: - Single styles

    @Test func boldDelimitersProduceBoldStyle() {
        let result = ZashiMarkdown.parse("**bold**")
        #expect(plainText(of: result) == "bold")
        #expect(spans(of: result) == [Span("bold", .bold)])
    }

    @Test func italicDelimitersProduceItalicStyle() {
        let result = ZashiMarkdown.parse("*italic*")
        #expect(plainText(of: result) == "italic")
        #expect(spans(of: result) == [Span("italic", .italic)])
    }

    @Test func tripleDelimitersProduceBoldItalicStyle() {
        let result = ZashiMarkdown.parse("***both***")
        #expect(plainText(of: result) == "both")
        #expect(spans(of: result) == [Span("both", .boldItalic)])
    }

    @Test func doubleEqualsProducesBoldPrimaryStyle() {
        let result = ZashiMarkdown.parse("==primary==")
        #expect(plainText(of: result) == "primary")
        #expect(spans(of: result) == [Span("primary", .boldPrimary)])
    }

    @Test func linkProducesLinkStyleAndURL() {
        let url = URL(string: "https://electriccoin.co")
        let result = ZashiMarkdown.parse("[ECC](https://electriccoin.co)")
        #expect(plainText(of: result) == "ECC")
        #expect(spans(of: result) == [Span("ECC", .link, link: url)])
    }

    // MARK: - Composition

    @Test func styledSpanSurroundedByPlainText() {
        let result = ZashiMarkdown.parse("a **bold** b")
        #expect(plainText(of: result) == "a bold b")
        #expect(spans(of: result) == [Span("a ", nil), Span("bold", .bold), Span(" b", nil)])
    }

    @Test func multipleSequentialStyledSpans() {
        let result = ZashiMarkdown.parse("==Warning:== keep slippage ==under 2%== please")
        #expect(plainText(of: result) == "Warning: keep slippage under 2% please")
        #expect(spans(of: result) == [
            Span("Warning:", .boldPrimary),
            Span(" keep slippage ", nil),
            Span("under 2%", .boldPrimary),
            Span(" please", nil)
        ])
    }

    @Test func adjacentDifferentStylesWithoutSeparator() {
        let result = ZashiMarkdown.parse("**b**==p==")
        #expect(spans(of: result) == [Span("b", .bold), Span("p", .boldPrimary)])
    }

    @Test func linkFollowedByBoldPrimary() {
        let url = URL(string: "https://x.io")
        let result = ZashiMarkdown.parse("[a](https://x.io) and ==b==")
        #expect(spans(of: result) == [
            Span("a", .link, link: url),
            Span(" and ", nil),
            Span("b", .boldPrimary)
        ])
    }

    // MARK: - Unmatched / malformed → literal, never throws

    @Test func unmatchedBoldRendersLiterally() {
        let result = ZashiMarkdown.parse("**bold")
        #expect(plainText(of: result) == "**bold")
        #expect(spans(of: result) == [Span("**bold", nil)])
    }

    @Test func unmatchedBoldPrimaryRendersLiterally() {
        let result = ZashiMarkdown.parse("==x")
        #expect(plainText(of: result) == "==x")
        #expect(spans(of: result) == [Span("==x", nil)])
    }

    @Test func unclosedLinkRendersLiterally() {
        let result = ZashiMarkdown.parse("[text](no-close")
        #expect(plainText(of: result) == "[text](no-close")
        #expect(spans(of: result).allSatisfy { $0.style == nil })
    }

    // MARK: - Escaping

    @Test func backslashEscapesDelimiter() {
        let result = ZashiMarkdown.parse("\\*not italic\\*")
        #expect(plainText(of: result) == "*not italic*")
        #expect(spans(of: result) == [Span("*not italic*", nil)])
    }

    @Test func backslashEscapesEqualsRun() {
        // The backslash escapes the first '=', breaking the '==' run so no boldPrimary forms.
        let result = ZashiMarkdown.parse("\\==not primary==")
        #expect(plainText(of: result) == "==not primary==")
        #expect(spans(of: result).allSatisfy { $0.style == nil })
    }

    @Test func escapedBackslashIsLiteral() {
        let result = ZashiMarkdown.parse("a \\\\ b")
        #expect(plainText(of: result) == "a \\ b")
    }

    // MARK: - Whitespace / content preservation

    @Test func newlinesAndWhitespacePreserved() {
        let input = "line one\n\nline  two   end"
        let result = ZashiMarkdown.parse(input)
        #expect(plainText(of: result) == input)
    }

    @Test func percentSignIsNotSpecial() {
        let result = ZashiMarkdown.parse("==50%==")
        #expect(plainText(of: result) == "50%")
        #expect(spans(of: result) == [Span("50%", .boldPrimary)])
    }

    @Test func interpolatedValueInsideBoldPrimary() {
        let result = ZashiMarkdown.parse("from ==123 ZEC== now")
        #expect(spans(of: result) == [
            Span("from ", nil),
            Span("123 ZEC", .boldPrimary),
            Span(" now", nil)
        ])
    }

    // MARK: - Link contract (flat, no nesting in v1)

    @Test func linkTextIsNotReparsedForNesting() {
        let url = URL(string: "https://x.io")
        let result = ZashiMarkdown.parse("[a*b*c](https://x.io)")
        #expect(spans(of: result) == [Span("a*b*c", .link, link: url)])
    }
}
