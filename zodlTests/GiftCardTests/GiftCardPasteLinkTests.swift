//
//  GiftCardPasteLinkTests.swift
//  zodlTests
//
//  The "Paste your gift card link" screen (`GiftCardPasteLink`): empty, filled and invalid states,
//  Continue enabled only for a gift card link the client accepts, and the clipboard cleared on
//  leaving when it still holds the gift card link pasted here. Also pins the redeem flow's copy.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@MainActor struct GiftCardPasteLinkTests {
    nonisolated private static let link = "https://gift.zodl.com/#v=1&key=zgifttest1fixture&height=3000000"
    nonisolated private static let vizorLink = "https://link.vizor.cash/payment-links/open#v3=eyJmaXh0dXJlIjp0cnVlfQ"

    private func makeStore(
        clipboard: String? = nil,
        cleared: LockIsolated<[RedactableString]> = LockIsolated([]),
        client: GiftCardClient = .mock()
    ) -> TestStore<GiftCardPasteLink.State, GiftCardPasteLink.Action> {
        TestStore(initialState: GiftCardPasteLink.State()) {
            GiftCardPasteLink()
        } withDependencies: {
            $0.giftCard = client
            $0.pasteboard = PasteboardClient(
                setString: { _ in },
                clearIfMatches: { value in cleared.withValue { $0.append(value) } },
                getString: { clipboard?.redacted }
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
        let store = makeStore(clipboard: "  \(link)\n")

        await store.send(.pasteTapped) {
            $0.text = link.redacted
            $0.pastedLink = "  \(link)\n".redacted
            $0.isValid = true
        }
    }

    @Test(arguments: ["zodl.com/gift/8f2k", "u1notagiftcard", "https://example.com/#v=1"])
    func pastingSomethingElseMarksTheFieldInvalid(text: String) async {
        let cleared = LockIsolated<[RedactableString]>([])
        let store = makeStore(clipboard: text, cleared: cleared)

        await store.send(.pasteTapped) {
            $0.text = text.redacted
            $0.isInvalid = true
        }

        // Not a gift card link, so leaving does not touch the clipboard.
        await store.send(.backTapped) {
            $0.text = .empty
            $0.isInvalid = false
        }
        await store.receive(\.delegate.back)
        #expect(cleared.value.isEmpty)
    }

    @Test(arguments: [nil, ""] as [String?])
    func pastingAnEmptyClipboardChangesNothing(clipboard: String?) async {
        let store = makeStore(clipboard: clipboard)
        await store.send(.pasteTapped)
    }

    /// A link the parser rejects as damaged looks like a gift card link but cannot be opened.
    @Test func damagedGiftCardLinkIsInvalid() async {
        let store = makeStore()
        await store.send(.textChanged("https://gift.zodl.com/#".redacted)) {
            $0.text = "https://gift.zodl.com/#".redacted
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
            $0.isValid = true
        }
    }

    /// While a link is being typed, its start is not flagged as invalid.
    @Test(arguments: ["h", "https://gift", "HTTPS://GIFT.ZODL.COM/", "https://link.vizor.cash/pay"])
    func startOfALinkIsNotFlagged(text: String) async {
        let store = makeStore()
        await store.send(.textChanged(text.redacted)) {
            $0.text = text.redacted
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
        let cleared = LockIsolated<[RedactableString]>([])
        let original = "  \(Self.link)\n"
        let store = makeStore(clipboard: original, cleared: cleared)

        await store.send(.pasteTapped) {
            $0.text = Self.link.redacted
            $0.pastedLink = original.redacted
            $0.isValid = true
        }
        await store.send(.continueTapped) {
            $0.text = .empty
            $0.pastedLink = nil
            $0.isValid = false
        }
        await store.receive(.delegate(.open(Self.link.redacted)))
        // Matched against the untrimmed original: the clipboard holds that, not the trimmed text.
        #expect(cleared.value == [original.redacted])
    }

    @Test func typedLinkDoesNotTouchTheClipboard() async {
        let cleared = LockIsolated<[RedactableString]>([])
        let store = makeStore(cleared: cleared)

        await store.send(.textChanged(Self.link.redacted)) {
            $0.text = Self.link.redacted
            $0.isValid = true
        }
        await store.send(.continueTapped) {
            $0.text = .empty
            $0.isValid = false
        }
        await store.receive(.delegate(.open(Self.link.redacted)))
        #expect(cleared.value.isEmpty)
    }

    @Test func backClearsAPastedGiftCardLinkFromTheClipboard() async {
        let cleared = LockIsolated<[RedactableString]>([])
        let store = makeStore(clipboard: Self.link, cleared: cleared)

        await store.send(.pasteTapped) {
            $0.text = Self.link.redacted
            $0.pastedLink = Self.link.redacted
            $0.isValid = true
        }
        await store.send(.backTapped) {
            $0.text = .empty
            $0.pastedLink = nil
            $0.isValid = false
        }
        await store.receive(.delegate(.back))
        #expect(cleared.value == [Self.link.redacted])
    }
}

/// The redeem flow's copy, as the final designs word it, in both languages.
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
        ("es", "giftCard.success.descNoAmount", "Tu regalo está en camino a tu billetera.\nAparecerá en tu actividad en breve.")
    ])
    func copyMatchesTheDesign(language: String, key: String, value: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: key, value: nil, table: "Localizable") == value)
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
