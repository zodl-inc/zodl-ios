//
//  GiftCardSecretGuardTests.swift
//  zodlTests
//
//  Keeping gift card secrets where they belong: `GiftCardSecretDetector` finds a card's link or key
//  anywhere in a text, however it is disguised, and the Swap / Pay address field, the address book
//  and the paste screen use it. Also the gift card scanner's own "not a gift card" message.
//  Every fixture is synthetic: none is a real card.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct GiftCardSecretDetectorTests {
    private static let link = "https://gift.zodl.com/#v=1&key=zgift1syntheticfixture&height=3000000"

    @Test(arguments: [
        link,
        "https://gift.zodl.com#v=1&key=zgift1syntheticfixture",
        "https://link.vizor.cash/payment-links/open#v3=eyJmaXh0dXJlIjp0cnVlfQ",
        // Surrounding text: a whole pasted message.
        "Happy birthday! Here's your gift: \(link) Enjoy",
        // Case, another scheme, no scheme.
        "HTTPS://GIFT.ZODL.COM/#V=1",
        "http://gift.zodl.com/#v=1",
        "gift.zodl.com/#v=1&key=x",
        // A bare key, mainnet and testnet.
        "zgift1syntheticfixture",
        "ZGIFTTEST1SYNTHETICFIXTURE",
        // Invisible and format characters: zero-width space, byte order mark, soft hyphen, bidi override.
        "https://gift\u{200B}.zodl.com/#v=1",
        "\u{FEFF}https://gift.zodl.com/#v=1",
        "https://gift.zo\u{00AD}dl.com/#v=1",
        "\u{202E}zgift1syntheticfixture",
        // Whitespace inside it.
        "https://gift. zodl .com/#v=1",
        "zgift1 synthetic\nfixture",
        // Compatibility forms: full-width letters.
        "ｇｉｆｔ．ｚｏｄｌ．ｃｏｍ",
        // Percent-encoding, once and twice.
        "https%3A%2F%2Fgift.zodl.com%2F%23v%3D1",
        "%67%69%66%74%2E%7A%6F%64%6C%2E%63%6F%6D",
        "%2567%2569%2566%2574%252E%257A%256F%2564%256C%252E%2563%256F%256D",
        "link.vizor.cash%2Fpayment-links%2Fopen"
    ])
    func findsACardSecretHoweverItIsWritten(text: String) {
        #expect(GiftCardSecretDetector.mayContainGiftCardSecret(text))
    }

    @Test(arguments: [
        "",
        "u1syntheticunifiedaddressfixture",
        "zs1syntheticsaplingaddressfixture",
        "t1SyntheticTransparentFixture",
        "0x52908400098527886E0F7030069857D2E4169EE7",
        "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
        "https://zodl.com/",
        "my gift for you",
        "zgift",
        // A malformed escape is kept as it is, and does not fail.
        "100% sure %zz %",
        "%E2%82"
    ])
    func leavesOrdinaryAddressesAlone(text: String) {
        #expect(!GiftCardSecretDetector.mayContainGiftCardSecret(text))
    }
}

// Serialized: the address book and Swap states share process-global `@Shared` slots.
@Suite(.serialized) @MainActor struct GiftCardAddressGuardTests {
    private static let link = "https://gift.zodl.com/#v=1&key=zgift1syntheticfixture&height=3000000"
    private static let disguised = "send to gift\u{200B}.zodl.com/%23v%3D1%26key%3Dzgift1syntheticfixture"

    private func swapToZecState(address: String) -> SwapAndPay.State {
        var state = SwapAndPay.State.initial
        state.isSwapExperienceEnabled = true
        state.isSwapToZecExperienceEnabled = true
        state.amountOverrideForTesting = 10
        state.zecAsset = SwapAsset(provider: "near", chain: "zec", token: "ZEC", assetId: "zec-id", usdPrice: 40, decimals: 8)
        state.selectedAsset = SwapAsset(provider: "near", chain: "eth", token: "ETH", assetId: "eth-id", usdPrice: 2, decimals: 18)
        state.address = address
        return state
    }

    @Test func swapAddressFieldRefusesACardLink() {
        let ordinary = swapToZecState(address: "0x52908400098527886E0F7030069857D2E4169EE7")
        #expect(!ordinary.isGiftCardAddress)
        #expect(ordinary.isValidForm)

        for address in [Self.link, Self.disguised] {
            let state = swapToZecState(address: address)
            #expect(state.isGiftCardAddress)
            #expect(!state.isValidForm)
        }
    }

    @Test func swapContactHoldingACardLinkIsRefused() {
        var state = swapToZecState(address: "")
        state.selectedContact = Contact(address: Self.disguised, name: "Gift", lastUpdated: Date(timeIntervalSince1970: 0), chainId: "eth")
        #expect(state.isGiftCardAddress)
        #expect(!state.isValidForm)
    }

    @Test func swapFormNeverOffersACardLinkAsANewContact() async {
        var state = swapToZecState(address: Self.link)
        state.isNotAddressInAddressBook = true
        state.isAddressBookHintVisible = true
        let store = TestStore(initialState: state) { SwapAndPay() }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.addressBookUpdated) {
            $0.isNotAddressInAddressBook = false
            $0.isAddressBookHintVisible = false
        }
    }

    @Test func addressBookRefusesACardLink() {
        var state = AddressBook.State()
        state.context = .swap
        state.name = "Gift"
        state.selectedChain = SwapAsset(provider: "", chain: "eth", token: "ETH", assetId: "", usdPrice: 0, decimals: 0)
        state.address = "0x52908400098527886E0F7030069857D2E4169EE7"
        state.isValidForm = true
        #expect(!state.isGiftCardAddress)
        #expect(!state.isSaveButtonDisabled)

        for address in [Self.link, Self.disguised] {
            state.address = address
            #expect(state.isGiftCardAddress)
            #expect(state.isSaveButtonDisabled)
            #expect(state.invalidAddressErrorText == String(localizable: .addressBookErrorGiftCardLink))
        }
    }

    @Test func savingACardLinkAsAContactTouchesNothing() async {
        let calls = LockIsolated(0)
        var state = AddressBook.State()
        state.context = .swap
        state.name = "Gift"
        state.address = Self.disguised
        state.$zashiWalletAccount.withLock {
            $0 = WalletAccount(Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)), name: "Zodl", keySource: nil,
                seedFingerprint: nil, hdAccountIndex: Zip32AccountIndex(0), ufvk: nil, uivk: nil
            ))
        }
        let store = TestStore(initialState: state) {
            AddressBook()
        } withDependencies: {
            $0.addressBook.deleteContact = { _, _ in
                calls.withValue { $0 += 1 }
                return (.empty, .notAttempted)
            }
            $0.addressBook.storeContact = { _, _ in
                calls.withValue { $0 += 1 }
                return (.empty, .notAttempted)
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.saveButtonTapped)
        await store.finish()
        #expect(calls.value == 0)
        state.$zashiWalletAccount.withLock { $0 = nil }
    }

    @Test func liveAddressBookRefusesToStoreACardLink() {
        let account = Account(
            id: AccountUUID(id: [UInt8](repeating: 0, count: 16)), name: "Zodl", keySource: nil,
            seedFingerprint: nil, hdAccountIndex: Zip32AccountIndex(0), ufvk: nil, uivk: nil
        )
        let contact = Contact(address: Self.disguised, name: "Gift", lastUpdated: Date(timeIntervalSince1970: 0), chainId: "eth")
        #expect(throws: AddressBookClient.AddressBookClientError.giftCardLink) {
            _ = try AddressBookClient.live().storeContact(account, contact)
        }
    }
}

@MainActor struct GiftCardScannerMessageTests {
    private func store(_ state: Scan.State) -> TestStore<Scan.State, Scan.Action> {
        let store = TestStore(initialState: state) {
            Scan()
        } withDependencies: {
            $0.giftCard = .mock()
            $0.mainQueue = .immediate
            $0.zcashSDKEnvironment = .testnet
            $0.uriParser.isValidURI = { _, _ in false }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    /// A QR code that is not a gift card is called that, not "not a valid Zcash address".
    @Test func giftCardScannerNamesGiftCards() async {
        let store = store(.giftCardScanner)

        await store.send(.scan("zcash:u1syntheticfixture?amount=1".redacted))
        await store.receive(.scanFailed(.invalidQRCode)) {
            $0.info = String(localizable: .giftCardScanInvalid)
        }
        await store.receive(.clearInfo) {
            $0.info = ""
        }

        await store.send(.scanFailed(.invalidQRCode)) {
            $0.info = String(localizable: .giftCardScanInvalid)
        }
    }

    @Test func rescannerAsksToScanWithZodlAndNamesGiftCards() {
        let state = Scan.State.giftCardRescanner
        #expect(state.instructions == String(localizable: .giftCardRescanInstructions))
        #expect(state.invalidCodeInfo == String(localizable: .giftCardScanInvalid))
    }

    /// Other scanners keep their own messages.
    @Test func addressScannerIsUnchanged() async {
        var state = Scan.State.initial
        state.checkers = [.zcashAddressScanChecker]
        let store = store(state)

        await store.send(.scan("not-an-address".redacted))
        await store.receive(.scanFailed(.noQRCodeFound)) {
            $0.info = String(localizable: .scanInvalidImage)
        }
        await store.send(.scanFailed(.invalidQRCode)) {
            $0.info = String(localizable: .scanInvalidQR)
        }
    }
}

@MainActor struct GiftCardPasteSecretTests {
    /// Text that holds a card's link somewhere inside it is not a link Continue opens, but it is
    /// still cleared from the clipboard when the screen is left.
    @Test func pastedTextHoldingACardSecretIsClearedOnLeaving() async {
        let pasted = "Your gift: https://gift.zodl.com/#v=1&key=zgift1syntheticfixture enjoy"
        let cleared = LockIsolated<[RedactableString]>([])
        let store = TestStore(initialState: GiftCardPasteLink.State()) {
            GiftCardPasteLink()
        } withDependencies: {
            $0.giftCard = .mock()
            $0.pasteboard = PasteboardClient(
                setString: { _ in },
                clearIfMatches: { value in cleared.withValue { $0.append(value) } },
                getString: { pasted.redacted }
            )
        }

        await store.send(.pasteTapped) {
            $0.text = pasted.redacted
            $0.clipboardCandidates = [pasted.redacted]
            $0.isInvalid = true
        }
        await store.send(.backTapped) {
            $0.text = .empty
            $0.clipboardCandidates = []
            $0.isInvalid = false
        }
        await store.receive(.delegate(.back))
        #expect(cleared.value == [pasted.redacted])
    }
}
