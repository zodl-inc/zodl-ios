//
//  GiftCardPasteLinkTests.swift
//  zodlTests
//
//  The "Paste your gift card link" screen (`GiftCardPasteLink`): empty, filled and invalid states,
//  Continue enabled only for a gift card link the client accepts, and the clipboard cleared on
//  Clear or leaving when it still holds sensitive text entered here. Also pins the redeem flow's copy.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

/// A synthetic clipboard: matching clears change its actual contents, while replacements survive.
private struct GiftCardPasteboardFixture {
    var string: RedactableString?
    var readCount = 0
    var writeCount = 0
    var clearCandidates: [RedactableString] = []

    init(_ string: String? = nil) {
        self.string = string?.redacted
    }
}

@Suite(.serialized) @MainActor struct GiftCardPasteLinkTests {
    nonisolated private static let link = "https://gift.zodl.com/#v=1&key=zgifttest1fixture&height=3000000"
    nonisolated private static let vizorLink = "https://link.vizor.cash/payment-links/open#v3=eyJmaXh0dXJlIjp0cnVlfQ"

    private func makeStore(
        clipboard: LockIsolated<GiftCardPasteboardFixture> = LockIsolated(GiftCardPasteboardFixture()),
        client: GiftCardClient = GiftCardClient.mock(),
        state: GiftCardPasteLink.State = GiftCardPasteLink.State()
    ) -> TestStore<GiftCardPasteLink.State, GiftCardPasteLink.Action> {
        TestStore(initialState: state) {
            GiftCardPasteLink()
        } withDependencies: {
            $0.giftCard = client
            $0.pasteboard = PasteboardClient(
                setString: { value in
                    clipboard.withValue {
                        $0.writeCount += 1
                        $0.string = value
                    }
                },
                clearIfMatches: { value in
                    clipboard.withValue {
                        $0.clearCandidates.append(value)
                        if $0.string == value {
                            $0.string = nil
                        }
                    }
                },
                getString: {
                    clipboard.withValue {
                        $0.readCount += 1
                        return $0.string
                    }
                }
            )
        }
    }

    @Test func startsEmptyWithContinueDisabledAndNoError() {
        let state = GiftCardPasteLink.State()
        #expect(state.text == .empty)
        #expect(!state.isValid)
        #expect(!state.isInvalid)
    }

    @Test(arguments: [link, vizorLink])
    func pastingAGiftCardLinkFillsTheFieldAndEnablesContinue(link: String) async {
        let store = makeStore(clipboard: LockIsolated(GiftCardPasteboardFixture("  \(link)\n")))

        await store.send(.pasteTapped) {
            $0.text = link.redacted
            $0.clipboardCandidates = ["  \(link)\n".redacted, link.redacted]
            $0.isValid = true
        }
    }

    @Test(arguments: ["zodl.com/gift/8f2k", "u1notagiftcard", "https://example.com/#v=1"])
    func pastingSomethingElseMarksTheFieldInvalid(text: String) async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture(text))
        let store = makeStore(clipboard: clipboard)

        await store.send(.pasteTapped) {
            $0.text = text.redacted
            $0.isInvalid = true
        }

        // Not a gift card link, so leaving does not touch the clipboard.
        await store.send(.backTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isInvalid = false
        }
        await store.receive(\.delegate.back)
        #expect(clipboard.value.clearCandidates.isEmpty)
        #expect(clipboard.value.string == text.redacted)
        #expect(clipboard.value.readCount == 1)
    }

    @Test(arguments: [nil, ""] as [String?])
    func pastingAnEmptyClipboardChangesNothing(clipboard: String?) async {
        let store = makeStore(clipboard: LockIsolated(GiftCardPasteboardFixture(clipboard)))
        await store.send(.pasteTapped)
    }

    /// A link the parser rejects as damaged looks like a gift card link but cannot be opened.
    @Test func damagedGiftCardLinkIsInvalid() async {
        let store = makeStore()
        await store.send(.textChanged("https://gift.zodl.com/#".redacted)) {
            $0.text = "https://gift.zodl.com/#".redacted
            $0.clipboardCandidates = ["https://gift.zodl.com/#".redacted]
            $0.isInvalid = true
        }
    }

    /// A link for a newer format, or for another network, still opens: the redeem screen explains
    /// why it cannot be redeemed here.
    @Test func linkTheRedeemScreenExplainsCanContinue() async {
        var client = GiftCardClient.mock()
        client.parse = { _ in throw GiftCardClientError.unsupportedVersion }
        let store = makeStore(client: client)
        await store.send(.textChanged(Self.link.redacted)) {
            $0.text = Self.link.redacted
            $0.clipboardCandidates = [Self.link.redacted]
            $0.isValid = true
        }
    }

    /// While a link is being typed, its start is not flagged as invalid.
    @Test(arguments: ["h", "https://gift", "HTTPS://GIFT.ZODL.COM/", "https://link.vizor.cash/pay"])
    func startOfALinkIsNotFlagged(text: String) async {
        let store = makeStore()
        await store.send(.textChanged(text.redacted)) {
            $0.text = text.redacted
            if text == "HTTPS://GIFT.ZODL.COM/" {
                $0.clipboardCandidates = [text.redacted]
            }
        }
    }

    @Test func clearEmptiesTheField() async {
        let store = makeStore()
        await store.send(.textChanged("zodl.com/gift/8f2k".redacted)) {
            $0.text = "zodl.com/gift/8f2k".redacted
            $0.isInvalid = true
        }
        await store.send(.clearTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isInvalid = false
        }
    }

    @Test func continueIsIgnoredUntilTheLinkIsValid() async {
        let store = makeStore()
        await store.send(.continueTapped)
        await store.send(.textChanged("zodl.com/gift/8f2k".redacted)) {
            $0.text = "zodl.com/gift/8f2k".redacted
            $0.isInvalid = true
        }
        await store.send(.continueTapped)
    }

    @Test func continueOpensTheTrimmedLinkAndClearsThePastedOneFromTheClipboard() async {
        let original = "  \(Self.link)\n"
        let clipboard = LockIsolated(GiftCardPasteboardFixture(original))
        let store = makeStore(clipboard: clipboard)

        await store.send(.pasteTapped) {
            $0.text = Self.link.redacted
            $0.clipboardCandidates = [original.redacted, Self.link.redacted]
            $0.isValid = true
        }
        await store.send(.continueTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isValid = false
        }
        await store.receive(.delegate(.open(Self.link.redacted)))
        // Matched against the untrimmed original, which the clipboard holds, and against the
        // field's text; each is cleared only if the clipboard still holds exactly that.
        #expect(clipboard.value.clearCandidates == [original.redacted, Self.link.redacted])
        #expect(clipboard.value.string == nil)
    }

    /// A link that reached the field without the Paste button (a paste from the keyboard or a long
    /// press) is cleared from the clipboard too, if the clipboard still holds exactly that text.
    @Test func linkPastedIntoTheFieldIsClearedFromTheClipboardOnContinue() async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture(Self.link))
        let store = makeStore(clipboard: clipboard)

        await store.send(.textChanged(Self.link.redacted)) {
            $0.text = Self.link.redacted
            $0.clipboardCandidates = [Self.link.redacted]
            $0.isValid = true
        }
        await store.send(.continueTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isValid = false
        }
        await store.receive(.delegate(.open(Self.link.redacted)))
        #expect(clipboard.value.clearCandidates == [Self.link.redacted])
        #expect(clipboard.value.string == nil)
    }

    @Test func textHoldingACardSecretIsClearedFromTheClipboardOnBack() async {
        let text = "my card zgifttest1fixture".redacted
        let clipboard = LockIsolated(GiftCardPasteboardFixture(text.data))
        let store = makeStore(clipboard: clipboard)

        await store.send(.textChanged(text)) {
            $0.clipboardCandidates = [text]
            $0.text = text
            $0.isInvalid = true
        }
        await store.send(.backTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isInvalid = false
        }
        await store.receive(.delegate(.back))
        #expect(clipboard.value.clearCandidates == [text])
        #expect(clipboard.value.string == nil)
    }

    @Test(arguments: ["https://gift.zo", "ordinary text"])
    func typedTextWithoutACardSecretDoesNotTouchTheClipboard(text: String) async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture("ordinary clipboard"))
        let store = makeStore(clipboard: clipboard)
        let isInvalid = text == "ordinary text"

        await store.send(.textChanged(text.redacted)) {
            $0.text = text.redacted
            $0.isInvalid = isInvalid
        }
        await store.send(.clearTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isInvalid = false
        }
        await store.send(.backTapped)
        await store.receive(\.delegate.back)
        #expect(clipboard.value.clearCandidates.isEmpty)
        #expect(clipboard.value.readCount == 0)
        #expect(clipboard.value.writeCount == 0)
        #expect(clipboard.value.string == "ordinary clipboard".redacted)
    }

    @Test func backClearsAPastedGiftCardLinkFromTheClipboard() async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture(Self.link))
        let store = makeStore(clipboard: clipboard)

        await store.send(.pasteTapped) {
            $0.text = Self.link.redacted
            $0.clipboardCandidates = [Self.link.redacted]
            $0.isValid = true
        }
        await store.send(.backTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isValid = false
        }
        await store.receive(.delegate(.back))
        #expect(clipboard.value.clearCandidates == [Self.link.redacted])
        #expect(clipboard.value.string == nil)
    }

    /// Keyboard and long-press pastes arrive as textChanged without reading the clipboard.
    @Test(arguments: [
        (link, true),
        (vizorLink, true),
        ("  \(link)\n", true),
        ("  \(vizorLink)\n", true),
        ("my card zgifttest1fixture", false),
        ("my card \(vizorLink) enjoy", false)
    ])
    func clearImmediatelyRemovesSensitiveFieldTextBeforeBack(text: String, isValid: Bool) async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture(text))
        let store = makeStore(clipboard: clipboard)

        await store.send(.textChanged(text.redacted)) {
            $0.text = text.redacted
            $0.clipboardCandidates = [text.redacted]
            $0.isValid = isValid
            $0.isInvalid = !isValid
        }
        #expect(clipboard.value.readCount == 0)
        await store.send(.clearTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isValid = false
            $0.isInvalid = false
        }
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.clearCandidates == [text.redacted])
        #expect(store.state.clipboardCandidates.isEmpty)
        #expect(!store.state.isValid)
        #expect(!store.state.isInvalid)

        await store.send(.backTapped)
        await store.receive(\.delegate.back)
        #expect(clipboard.value.clearCandidates == [text.redacted])
        #expect(clipboard.value.readCount == 0)
    }

    @Test(arguments: [link, vizorLink, "my card zgifttest1fixture"])
    func clearImmediatelyRemovesTheOriginalPasteButtonValue(text: String) async {
        let original = "  \(text)\n"
        let clipboard = LockIsolated(GiftCardPasteboardFixture(original))
        let store = makeStore(clipboard: clipboard)
        let isValid = text != "my card zgifttest1fixture"

        await store.send(.pasteTapped) {
            $0.text = text.redacted
            $0.clipboardCandidates = [original.redacted, text.redacted]
            $0.isValid = isValid
            $0.isInvalid = !isValid
        }
        await store.send(.clearTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isValid = false
            $0.isInvalid = false
        }
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.clearCandidates == [original.redacted, text.redacted])
        #expect(clipboard.value.readCount == 1)

        await store.send(.backTapped)
        await store.receive(\.delegate.back)
        #expect(clipboard.value.clearCandidates == [original.redacted, text.redacted])
        #expect(clipboard.value.readCount == 1)
    }

    @Test(arguments: [false, true])
    func clearPreservesReplacementClipboardContent(usePasteButton: Bool) async {
        let original = "  \(Self.link)\n"
        let replacement = "replacement clipboard content".redacted
        let clipboard = LockIsolated(GiftCardPasteboardFixture(original))
        let store = makeStore(clipboard: clipboard)

        if usePasteButton {
            await store.send(.pasteTapped) {
                $0.text = Self.link.redacted
                $0.clipboardCandidates = [original.redacted, Self.link.redacted]
                $0.isValid = true
            }
        } else {
            await store.send(.textChanged(original.redacted)) {
                $0.clipboardCandidates = [original.redacted]
                $0.text = original.redacted
                $0.isValid = true
            }
        }
        clipboard.withValue { $0.string = replacement }
        await store.send(.clearTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isValid = false
        }
        #expect(clipboard.value.string == replacement)
        let expectedCandidates = usePasteButton ? [original.redacted, Self.link.redacted] : [original.redacted]
        #expect(clipboard.value.clearCandidates == expectedCandidates)
        #expect(clipboard.value.readCount == (usePasteButton ? 1 : 0))

        await store.send(.backTapped)
        await store.receive(\.delegate.back)
        #expect(clipboard.value.string == replacement)
        #expect(store.state.clipboardValuesToClear.isEmpty)
    }

    enum KeyboardEdit: CaseIterable {
        case appendSpace
        case removeFinalCharacter
        case removeMarkers
        case ordinaryText
        case empty

        func apply(to original: String) -> String {
            switch self {
            case .appendSpace:
                return "\(original) "
            case .removeFinalCharacter:
                return String(original.trimmingCharacters(in: .whitespacesAndNewlines).dropLast())
            case .removeMarkers:
                return original
                    .replacingOccurrences(of: "gift.zodl.com", with: "example.com")
                    .replacingOccurrences(of: "zgifttest1", with: "fixture")
                    .replacingOccurrences(of: "link.vizor.cash/payment-links", with: "example.com/cards")
            case .ordinaryText:
                return "ordinary replacement text"
            case .empty:
                return ""
            }
        }
    }

    @Test(
        arguments: [link, vizorLink, "  \(link)\n", "  \(vizorLink)\n"],
        KeyboardEdit.allCases.flatMap { edit in [false, true].map { (edit, $0) } }
    )
    func editedKeyboardPasteClearsOriginalOnExit(original: String, exit: (KeyboardEdit, Bool)) async {
        let (edit, useBack) = exit
        let clipboard = LockIsolated(GiftCardPasteboardFixture(original))
        let store = makeStore(clipboard: clipboard)
        store.exhaustivity = .off(showSkippedAssertions: false)
        let edited = edit.apply(to: original)

        await store.send(.textChanged(original.redacted))
        #expect(store.state.isValid)
        await store.send(.textChanged(edited.redacted))
        #expect(store.state.text == edited.redacted)
        #expect(clipboard.value.readCount == 0)
        #expect(clipboard.value.writeCount == 0)
        #expect(clipboard.value.clearCandidates.isEmpty)
        store.exhaustivity = .on
        if useBack {
            await store.send(.backTapped) {
                $0 = GiftCardPasteLink.State()
            }
            await store.receive(.delegate(.back))
        } else {
            await store.send(.clearTapped) {
                $0 = GiftCardPasteLink.State()
            }
        }
        #expect(clipboard.value.string == nil)
        #expect(store.state.clipboardValuesToClear.isEmpty)
        #expect(store.state.text == .empty)
        #expect(!store.state.isValid)
        #expect(!store.state.isInvalid)
        #expect(clipboard.value.readCount == 0)
        #expect(clipboard.value.writeCount == 0)
    }

    @Test(arguments: [link, vizorLink, "  \(link)\n", "  \(vizorLink)\n"])
    func editedKeyboardPasteContinuesWithTrimmedLink(original: String) async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture(original))
        let store = makeStore(clipboard: clipboard)
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.textChanged(original.redacted))
        await store.send(.textChanged("\(original) ".redacted))
        #expect(store.state.isValid)
        #expect(!store.state.isInvalid)
        #expect(clipboard.value.readCount == 0)
        #expect(clipboard.value.writeCount == 0)
        #expect(clipboard.value.clearCandidates.isEmpty)
        store.exhaustivity = .on
        await store.send(.continueTapped) {
            $0 = GiftCardPasteLink.State()
        }
        let link = original.trimmingCharacters(in: .whitespacesAndNewlines).redacted
        await store.receive(.delegate(.open(link)))
        #expect(clipboard.value.string == nil)
        #expect(store.state.clipboardValuesToClear.isEmpty)
        #expect(store.state.text == .empty)
    }

    @Test func invalidContinueRetainsEditedPasteCandidates() async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture(Self.link))
        let store = makeStore(clipboard: clipboard)
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.textChanged(Self.link.redacted))
        await store.send(.textChanged("ordinary replacement text".redacted))
        #expect(!store.state.isValid)
        #expect(store.state.isInvalid)
        store.exhaustivity = .on
        await store.send(.continueTapped)
        await store.finish()
        #expect(store.state.clipboardValuesToClear == [Self.link.redacted])
        #expect(store.state.text == "ordinary replacement text".redacted)
        #expect(clipboard.value.string == Self.link.redacted)
        #expect(clipboard.value.clearCandidates.isEmpty)
        #expect(clipboard.value.readCount == 0)
        #expect(clipboard.value.writeCount == 0)
        await store.send(.backTapped) {
            $0 = GiftCardPasteLink.State()
        }
        await store.receive(.delegate(.back))
        #expect(clipboard.value.string == nil)
        #expect(store.state.clipboardValuesToClear.isEmpty)
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)], [false, true])
    func mixedInputsKeepEveryOriginalUntilExit(routes: (Bool, Bool), clearEarlier: Bool) async {
        let first = "  \(Self.link)\n"
        let second = "\t\(Self.vizorLink) "
        let clipboard = LockIsolated(GiftCardPasteboardFixture(first))
        let store = makeStore(clipboard: clipboard)
        store.exhaustivity = .off(showSkippedAssertions: false)
        if routes.0 {
            await store.send(.pasteTapped)
        } else {
            await store.send(.textChanged(first.redacted))
        }
        #expect(store.state.isValid)
        await store.send(.textChanged("".redacted))
        #expect(!store.state.isValid)
        #expect(!store.state.isInvalid)
        #expect(clipboard.value.clearCandidates.isEmpty)
        clipboard.withValue { $0.string = second.redacted }
        if routes.1 {
            await store.send(.pasteTapped)
        } else {
            await store.send(.textChanged(second.redacted))
        }
        #expect(store.state.isValid)
        await store.send(.textChanged("ordinary replacement text".redacted))
        #expect(!store.state.isValid)
        #expect(store.state.isInvalid)
        #expect(store.state.clipboardValuesToClear.contains(first.redacted))
        #expect(store.state.clipboardValuesToClear.contains(second.redacted))
        #expect(!store.state.clipboardValuesToClear.contains("ordinary replacement text".redacted))
        #expect(clipboard.value.readCount == (routes.0 ? 1 : 0) + (routes.1 ? 1 : 0))
        #expect(clipboard.value.writeCount == 0)
        #expect(clipboard.value.clearCandidates.isEmpty)
        clipboard.withValue { $0.string = (clearEarlier ? first : second).redacted }
        store.exhaustivity = .on
        await store.send(.backTapped) {
            $0 = GiftCardPasteLink.State()
        }
        await store.receive(.delegate(.back))
        #expect(clipboard.value.string == nil)
        #expect(store.state.clipboardValuesToClear.isEmpty)
    }

    @Test func exactVariantsAreRetainedOnceUntilCleanup() async {
        let first = "  \(Self.link)\n".redacted
        let second = "\t\(Self.link) ".redacted
        let clipboard = LockIsolated(GiftCardPasteboardFixture(second.data))
        let store = makeStore(clipboard: clipboard)
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.textChanged(first))
        await store.send(.textChanged(second))
        await store.send(.textChanged(first))
        await store.send(.textChanged("".redacted))
        #expect(store.state.clipboardValuesToClear == [first, second])
        #expect(clipboard.value.readCount == 0)
        #expect(clipboard.value.writeCount == 0)
        #expect(clipboard.value.clearCandidates.isEmpty)
        store.exhaustivity = .on
        await store.send(.clearTapped) {
            $0 = GiftCardPasteLink.State()
        }
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.clearCandidates == [first, second])
        #expect(store.state.clipboardValuesToClear.isEmpty)
    }

    @Test func clearedVisitDoesNotReuseEarlierCandidates() async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture(Self.link))
        let store = makeStore(clipboard: clipboard)
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.textChanged(Self.link.redacted))
        store.exhaustivity = .on
        await store.send(.clearTapped) {
            $0 = GiftCardPasteLink.State()
        }
        #expect(clipboard.value.string == nil)
        clipboard.withValue { $0.string = Self.link.redacted }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.textChanged(Self.vizorLink.redacted))
        await store.send(.textChanged("".redacted))
        #expect(store.state.clipboardValuesToClear == [Self.vizorLink.redacted])
        store.exhaustivity = .on
        await store.send(.backTapped) {
            $0 = GiftCardPasteLink.State()
        }
        await store.receive(.delegate(.back))
        #expect(clipboard.value.string == Self.link.redacted)
        #expect(clipboard.value.clearCandidates == [Self.link.redacted, Self.vizorLink.redacted])
        #expect(store.state.clipboardValuesToClear.isEmpty)
    }

    @Test(arguments: ["ordinary replacement text", "https://gift.zodl.com/#v=1&key=zgifttest1unseen&height=3000000"])
    func editedPastePreservesUnseenClipboardReplacement(replacement: String) async {
        let clipboard = LockIsolated(GiftCardPasteboardFixture(Self.link))
        let store = makeStore(clipboard: clipboard)
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.textChanged(Self.link.redacted))
        await store.send(.textChanged("".redacted))
        clipboard.withValue { $0.string = replacement.redacted }
        store.exhaustivity = .on
        await store.send(.clearTapped) {
            $0 = GiftCardPasteLink.State()
        }
        #expect(clipboard.value.string == replacement.redacted)
        #expect(clipboard.value.clearCandidates == [Self.link.redacted])
        #expect(clipboard.value.readCount == 0)
        #expect(clipboard.value.writeCount == 0)
        #expect(store.state.clipboardValuesToClear.isEmpty)
    }

    @Test(arguments: [link, vizorLink, "my card zgifttest1fixture"])
    func directlyInitializedSensitiveTextIsCleared(text: String) async {
        var state = GiftCardPasteLink.State()
        state.text = text.redacted
        let clipboard = LockIsolated(GiftCardPasteboardFixture(text))
        let store = makeStore(clipboard: clipboard, state: state)
        await store.send(.clearTapped) {
            $0.text = .empty
        }
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.clearCandidates == [text.redacted])
        #expect(store.state.clipboardValuesToClear.isEmpty)
    }

    @Test func invalidSensitiveKeyboardInputIsRetainedAfterEditing() async {
        let original = "my card zgifttest1fixture"
        let clipboard = LockIsolated(GiftCardPasteboardFixture(original))
        let store = makeStore(clipboard: clipboard)
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.textChanged(original.redacted))
        #expect(!store.state.isValid)
        #expect(store.state.isInvalid)
        await store.send(.textChanged("ordinary replacement text".redacted))
        #expect(store.state.clipboardValuesToClear == [original.redacted])
        store.exhaustivity = .on
        await store.send(.backTapped) {
            $0 = GiftCardPasteLink.State()
        }
        await store.receive(.delegate(.back))
        #expect(clipboard.value.string == nil)
        #expect(store.state.clipboardValuesToClear.isEmpty)
        #expect(clipboard.value.readCount == 0)
        #expect(clipboard.value.writeCount == 0)
    }
}

/// The redeem flow's copy, as the final designs word it, in both languages. Screens the designs
/// don't cover follow Android's wording; Spanish keeps "tarifa de red" for the network fee.
@Suite struct GiftCardCopyTests {
    @Test(arguments: [
        ("en", "giftCard.moreTitle", "Redeem Gift Card"),
        ("es", "giftCard.moreTitle", "Canjear tarjeta de regalo"),
        ("en", "giftCard.homeDesc", "Scan or paste a Zcash gift card to add its funds to your wallet."),
        ("es", "giftCard.homeDesc", "Escanea o pega una tarjeta de regalo de Zcash para sumar sus fondos a tu billetera."),
        ("en", "giftCard.checking.desc", "Checking your gift card. This can take a moment."),
        ("en", "giftCard.pending.title", "Preparing your gift…"),
        ("es", "giftCard.pending.title", "Preparando tu regalo…"),
        ("en", "giftCard.empty.desc", "This gift card was already redeemed, or hasn't been funded yet. Try again in a few minutes."),
        ("en", "giftCard.ready.title", "You received a gift!"),
        ("es", "giftCard.ready.title", "¡Recibiste un regalo!"),
        ("en", "giftCard.ready.note", "The funds will be sent to your %@ wallet. The network fee is already deducted from the amount shown."),
        ("es", "giftCard.ready.note", "Los fondos se enviarán a tu billetera %@. La tarifa de red ya está descontada del monto mostrado."),
        ("en", "giftCard.ready.noteNoWallet", "The network fee is already deducted from the amount shown."),
        ("en", "giftCard.dust.desc", "This gift card holds too little to cover the network fee, so there's nothing to redeem."),
        ("es", "giftCard.dust.desc", "Esta tarjeta de regalo tiene muy poco para cubrir la tarifa de red, así que no hay nada que canjear."),
        ("en", "giftCard.scanInvalid", "This isn't a valid gift card. Scan the gift card's QR code or copy its link and try again."),
        ("es", "giftCard.scanInvalid", "Esta no es una tarjeta de regalo válida. Escanea el código QR de la tarjeta o copia su enlace e inténtalo de nuevo."),
        ("en", "giftCard.rescanInstructions", "Looks like you opened a gift card from another app. For better safety and security, scan the gift card's QR code with Zodl."),
        ("es", "giftCard.rescanInstructions", "Parece que abriste una tarjeta de regalo desde otra aplicación. Para mayor seguridad y protección, escanea el código QR de la tarjeta de regalo con Zodl."),
        ("en", "swap.giftCardAddressNotAllowed", "Gift card links can't be used as swap addresses. Use Redeem Gift Card instead."),
        ("en", "addressBook.error.giftCardLink", "Gift card links can't be saved as contacts. Use Redeem Gift Card instead."),
        ("es", "addressBook.error.giftCardLink", "Los enlaces de tarjetas de regalo no se pueden guardar como contactos. Usa Canjear tarjeta de regalo."),
        ("en", "giftCard.paste.title", "Paste your gift card link"),
        ("es", "giftCard.paste.title", "Pega el enlace de tu tarjeta de regalo"),
        ("en", "giftCard.paste.invalid", "This link is not a valid gift card. Check it and try again."),
        ("es", "giftCard.paste.invalid", "Este enlace no es una tarjeta de regalo válida. Revísalo e inténtalo de nuevo."),
        ("en", "giftCard.redeem.memo", "Gift Card"),
        ("en", "giftCard.success.descNoAmount", "Your gift is on its way to your wallet.\nIt will show up in your activity shortly."),
        ("es", "giftCard.success.descNoAmount", "Tu regalo está en camino a tu billetera.\nAparecerá en tu actividad en breve."),
        ("en", "giftCard.checkFailed.title", "Couldn't check your gift"),
        ("es", "giftCard.checkFailed.title", "No pudimos verificar tu regalo"),
        ("en", "giftCard.checkFailed.desc", "Something went wrong while checking the gift card. Check your connection and try again."),
        ("es", "giftCard.checkFailed.desc", "Algo salió mal al verificar la tarjeta de regalo. Revisa tu conexión e inténtalo de nuevo."),
        ("en", "giftCard.invalid.title", "Invalid gift card"),
        ("es", "giftCard.invalid.title", "Tarjeta de regalo inválida"),
        ("en", "giftCard.invalid.desc", "This link isn't a valid gift card. Check the link and try again."),
        ("es", "giftCard.invalid.desc", "Este enlace no es una tarjeta de regalo válida. Revisa el enlace e inténtalo de nuevo."),
        ("en", "giftCard.wrongNetwork.desc", "This gift card was made for a different Zcash network than this wallet."),
        ("es", "giftCard.wrongNetwork.desc", "Esta tarjeta de regalo fue creada para una red de Zcash distinta a la de esta billetera."),
        ("en", "giftCard.unavailable.title", "Not available yet"),
        ("es", "giftCard.unavailable.title", "Todavía no disponible"),
        ("en", "giftCard.unavailable.desc", "Redeeming gift cards isn't available in this version of the app."),
        ("es", "giftCard.unavailable.desc", "Canjear tarjetas de regalo no está disponible en esta versión de la app."),
        ("en", "giftCard.unsupported.title", "Not available yet"),
        ("en", "giftCard.unsupported.desc", "Redeeming this gift card isn't available in this version of the app."),
        ("en", "giftCard.redeeming.title", "Redeeming your gift…"),
        ("es", "giftCard.redeeming.title", "Canjeando tu regalo…"),
        ("en", "giftCard.redeeming.desc", "Sending the gift card's funds to your wallet."),
        ("es", "giftCard.redeeming.desc", "Enviando los fondos de la tarjeta de regalo a tu billetera."),
        ("es", "giftCard.checkAgain", "Verificar de nuevo"),
        ("es", "giftCard.messageFromSender", "Mensaje de quien la envía"),
        ("es", "giftCard.empty.title", "Nada para canjear")
    ])
    func copyMatchesTheDesign(language: String, key: String, value: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: key, value: nil, table: "Localizable") == value)
    }

    /// Spanish gift card copy says "tarifa de red" for the network fee, never "comisión de red".
    @Test func spanishCopyCallsTheFeeTarifaDeRed() throws {
        let path = try #require(Bundle.main.path(forResource: "es", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for key in ["giftCard.ready.note", "giftCard.ready.noteNoWallet", "giftCard.dust.desc"] {
            let text = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            #expect(text.contains("tarifa de red"), "\(key)")
            #expect(!text.contains("comisión"), "\(key)")
        }
    }

    @Test(arguments: ["en", "es"])
    func readyNoteNamesTheWallet(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let format = bundle.localizedString(forKey: "giftCard.ready.note", value: nil, table: "Localizable")
        #expect(String(format: format, "Keystone").contains("Keystone"))
    }

    @Test(arguments: ["en", "es"])
    func amountCopyTakesTheReceivedAmount(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for key in ["giftCard.pending.desc", "giftCard.success.desc"] {
            let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
            #expect(String(format: format, "0.1 ZEC").hasPrefix("0.1 ZEC "), "\(language) \(key)")
        }
    }
}
