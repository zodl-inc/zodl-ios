import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct RootGiftCardPasteCleanupTests {
    nonisolated private static let link = "https://gift.zodl.com/#v=1&key=zgifttest1fixture&height=3000000"
    nonisolated private static let replacementLink = "https://gift.zodl.com/#v=1&key=zgifttest1replacement&height=3000000"

    private struct Clipboard {
        var string: RedactableString?
        var reads = 0
        var writes = 0
        var candidates: [RedactableString] = []

        init(_ text: String?) {
            string = text?.redacted
        }
    }

    private func makeStore(_ clipboard: LockIsolated<Clipboard>) -> TestStore<Root.State, Root.Action> {
        withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var state = Root.State.initial
            state.destinationState.destination = .home
            state.splashAppeared = true
            let store = TestStore(initialState: state) { Root() } withDependencies: {
                $0.giftCard = GiftCardClient.mock()
                $0.zcashSDKEnvironment = .live(network: ZcashNetworkBuilder.network(for: .mainnet))
                $0.exchangeRate = .noOp
                $0.walletStorage = .noOp
                $0.userMetadataProvider = UserMetadataProviderClient()
                $0.migrationManager.migrationSyncGateFeed = { AsyncStream { $0.finish() } }
                $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
                $0.sdkSynchronizer = .mocked()
                $0.mainQueue = .immediate
                $0.uriParser = URIParserClient.live()
                $0.pasteboard = PasteboardClient(
                    setString: { value in
                        clipboard.withValue {
                            $0.writes += 1
                            $0.string = value
                        }
                    },
                    clearIfMatches: { value in
                        clipboard.withValue {
                            $0.candidates.append(value)
                            if $0.string == value { $0.string = nil }
                        }
                    },
                    getString: {
                        clipboard.withValue {
                            $0.reads += 1
                            return $0.string
                        }
                    }
                )
            }
            store.exhaustivity = .off(showSkippedAssertions: false)
            return store
        }
    }

    private func openPaste(_ store: TestStore<Root.State, Root.Action>) async {
        await store.send(.home(.redeemGiftCardTapped))
        await store.send(.giftCardCoordFlow(.scan(.pasteTapped)))
        #expect(store.state.giftCardCoordFlowState.pasteLinkState != nil)
    }

    @Test func warningContinueClearsTheOriginalPasteWithoutAnOpenCard() async throws {
        let original = "  \(Self.link)\n"
        let clipboard = LockIsolated(Clipboard(original))
        let store = makeStore(clipboard)
        await openPaste(store)
        await store.send(.giftCardCoordFlow(.pasteLink(.pasteTapped)))
        let payment = try #require(URL(string: "zcash:t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po?amount=1"))

        await store.send(.destination(.deeplink(payment)))
        await store.receive {
            if case .destination(.updateDestination(.deeplinkWarning)) = $0 { true } else { false }
        }
        #expect(store.state.destinationState.destination == .deeplinkWarning)
        #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        #expect(clipboard.value.string == original.redacted)
        await store.send(.deeplinkWarning(.rescanInZashi))
        await store.receive(\.home.scanTapped)
        await store.finish()

        #expect(store.state.path == .scanCoordFlow)
        #expect(store.state.giftCardCoordFlowState.pasteLinkState == nil)
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.candidates == [original.redacted, Self.link.redacted])
        #expect(clipboard.value.reads == 1)
        #expect(clipboard.value.writes == 0)
    }

    @Test(arguments: [false, true])
    func keyboardPasteIsClearedOnParentExit(cancelScanner: Bool) async {
        let clipboard = LockIsolated(Clipboard(Self.link))
        let store = makeStore(clipboard)
        await openPaste(store)
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(Self.link.redacted))))
        if cancelScanner {
            await store.send(.giftCardCoordFlow(.scan(.cancelTapped)))
        } else {
            await store.send(.home(.settingsTapped))
        }
        await store.finish()

        #expect(store.state.path != .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.pasteLinkState == nil)
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.candidates == [Self.link.redacted])
        #expect(clipboard.value.reads == 0)
        #expect(clipboard.value.writes == 0)
    }

    @Test func samePathReplacementRetiresTheOldPasteAndPreservesTheNewCard() async {
        let clipboard = LockIsolated(Clipboard(Self.link))
        let store = makeStore(clipboard)
        await openPaste(store)
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(Self.link.redacted))))
        await store.send(.scanCoordFlow(.scan(.foundGiftCard(Self.replacementLink.redacted))))
        await store.finish()

        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.redeemState?.link == Self.replacementLink.redacted)
        #expect(store.state.giftCardCoordFlowState.pasteLinkState == nil)
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.candidates == [Self.link.redacted])
        #expect(clipboard.value.reads == 0)
    }

    @Test func samePathScannerReplacementPreservesTheNewPasteVisit() async {
        let clipboard = LockIsolated(Clipboard(Self.link))
        let store = makeStore(clipboard)
        await openPaste(store)
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(Self.link.redacted))))
        await store.send(.home(.redeemGiftCardTapped))
        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.candidates == [Self.link.redacted])
        await store.send(.giftCardCoordFlow(.scan(.pasteTapped)))
        clipboard.withValue { $0.string = Self.replacementLink.redacted }
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(Self.replacementLink.redacted))))
        await store.finish()

        #expect(store.state.path == .giftCardCoordFlow)
        #expect(store.state.giftCardCoordFlowState.pasteLinkState?.text == Self.replacementLink.redacted)
        #expect(clipboard.value.string == Self.replacementLink.redacted)
        #expect(clipboard.value.candidates == [Self.link.redacted])
        #expect(clipboard.value.reads == 0)
    }

    @Test func editedPasteRetainsItsSensitiveCandidatesUntilParentExit() async {
        let original = "  \(Self.link)\n"
        let clipboard = LockIsolated(Clipboard(original))
        let store = makeStore(clipboard)
        await openPaste(store)
        await store.send(.giftCardCoordFlow(.pasteLink(.pasteTapped)))
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged("ordinary replacement text".redacted))))
        await store.send(.home(.settingsTapped))
        await store.finish()

        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.candidates == [original.redacted, Self.link.redacted])
        #expect(clipboard.value.reads == 1)
        #expect(store.state.giftCardCoordFlowState.pasteLinkState == nil)
    }

    @Test(arguments: ["copied afterwards", replacementLink])
    func changedClipboardSurvivesParentExit(replacement: String) async {
        let clipboard = LockIsolated(Clipboard(Self.link))
        let store = makeStore(clipboard)
        await openPaste(store)
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(Self.link.redacted))))
        clipboard.withValue { $0.string = replacement.redacted }
        await store.send(.home(.settingsTapped))
        await store.finish()

        #expect(clipboard.value.string == replacement.redacted)
        #expect(clipboard.value.candidates == [Self.link.redacted])
        #expect(clipboard.value.reads == 0)
    }

    @Test(arguments: [false, true])
    func ordinaryTextOrNoPasteDoesNotAccessTheClipboard(openPasteScreen: Bool) async {
        let clipboard = LockIsolated(Clipboard("unrelated clipboard"))
        let store = makeStore(clipboard)
        if openPasteScreen {
            await openPaste(store)
            await store.send(.giftCardCoordFlow(.pasteLink(.textChanged("ordinary text".redacted))))
        } else {
            await store.send(.home(.redeemGiftCardTapped))
        }
        await store.send(.home(.settingsTapped))
        await store.finish()

        #expect(clipboard.value.string == "unrelated clipboard".redacted)
        #expect(clipboard.value.candidates.isEmpty)
        #expect(clipboard.value.reads == 0)
        #expect(clipboard.value.writes == 0)
        #expect(store.state.giftCardCoordFlowState.pasteLinkState == nil)
    }

    enum ChildExit: CaseIterable {
        case back
        case continueToCard
        case cleanUp
        case cleanUpWithCard
    }

    @Test(arguments: ChildExit.allCases)
    func childAndCoordinatorCleanupAreNotRepeatedByRoot(exit: ChildExit) async {
        let clipboard = LockIsolated(Clipboard(Self.link))
        let store = makeStore(clipboard)
        await openPaste(store)
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(Self.link.redacted))))
        switch exit {
        case .back:
            await store.send(.giftCardCoordFlow(.pasteLink(.backTapped)))
            await store.receive(\.giftCardCoordFlow.pasteLink.delegate.back)
        case .continueToCard:
            await store.send(.giftCardCoordFlow(.pasteLink(.continueTapped)))
            await store.receive(\.giftCardCoordFlow.pasteLink.delegate.open)
        case .cleanUp:
            await store.send(.giftCardCoordFlow(.cleanUp))
        case .cleanUpWithCard:
            await store.send(.giftCardCoordFlow(.scan(.foundGiftCard(Self.replacementLink.redacted))))
            await store.send(.giftCardCoordFlow(.cleanUp))
        }
        await store.send(.home(.settingsTapped))
        await store.finish()

        #expect(clipboard.value.string == nil)
        #expect(clipboard.value.candidates == [Self.link.redacted])
        #expect(clipboard.value.reads == 0)
        #expect(clipboard.value.writes == 0)
        #expect(store.state.giftCardCoordFlowState.pasteLinkState == nil)
    }

    enum ParentTransition: CaseIterable {
        case settings
        case freshScanner
        case newCard
        case warningContinue
        case coordinatorCleanup
    }

    @Test(arguments: [false, true], ParentTransition.allCases)
    func editedKeyboardPasteClearsOnParentTransition(deleteField: Bool, transition: ParentTransition) async throws {
        let original = "  \(Self.link)\n"
        let edited = deleteField ? "" : "\(original) "
        let clipboard = LockIsolated(Clipboard(original))
        let store = makeStore(clipboard)
        await openPaste(store)
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(original.redacted))))
        #expect(store.state.giftCardCoordFlowState.pasteLinkState?.isValid == true)
        await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(edited.redacted))))
        #expect(store.state.giftCardCoordFlowState.pasteLinkState?.text == edited.redacted)
        #expect(store.state.giftCardCoordFlowState.pasteLinkState?.isValid == !deleteField)
        #expect(clipboard.value.reads == 0)
        #expect(clipboard.value.writes == 0)
        #expect(clipboard.value.candidates.isEmpty)

        switch transition {
        case .settings:
            await store.send(.home(.settingsTapped))
            #expect(store.state.path != .giftCardCoordFlow)
        case .freshScanner:
            await store.send(.home(.redeemGiftCardTapped))
            #expect(store.state.path == .giftCardCoordFlow)
            #expect(store.state.giftCardCoordFlowState.scanState.isPasteEnabled)
            #expect(store.state.giftCardCoordFlowState.redeemState == nil)
        case .newCard:
            await store.send(.scanCoordFlow(.scan(.foundGiftCard(Self.replacementLink.redacted))))
            #expect(store.state.path == .giftCardCoordFlow)
            #expect(store.state.giftCardCoordFlowState.redeemState?.link == Self.replacementLink.redacted)
        case .warningContinue:
            let payment = try #require(URL(string: "zcash:t1gXqfSSQt6WfpwyuCU3Wi7sSVZ66DYQ3Po?amount=1"))
            await store.send(.destination(.deeplink(payment)))
            await store.receive {
                if case .destination(.updateDestination(.deeplinkWarning)) = $0 { true } else { false }
            }
            #expect(store.state.destinationState.destination == .deeplinkWarning)
            #expect(store.state.giftCardCoordFlowState.redeemState == nil)
            #expect(clipboard.value.string == original.redacted)
            await store.send(.deeplinkWarning(.rescanInZashi))
            await store.receive(\.home.scanTapped)
            #expect(store.state.path == .scanCoordFlow)
        case .coordinatorCleanup:
            await store.send(.giftCardCoordFlow(.cleanUp))
            #expect(store.state.giftCardCoordFlowState.redeemState == nil)
            #expect(store.state.giftCardCoordFlowState.scanState.isPasteEnabled)
        }
        await store.finish()
        #expect(store.state.giftCardCoordFlowState.pasteLinkState == nil)
        #expect(clipboard.value.string == nil)
        let expectedCandidates = deleteField ? [original.redacted] : [original.redacted, edited.redacted]
        #expect(clipboard.value.candidates == expectedCandidates)
        #expect(clipboard.value.reads == 0)
        #expect(clipboard.value.writes == 0)

        if transition == .freshScanner {
            await store.send(.giftCardCoordFlow(.scan(.pasteTapped)))
            clipboard.withValue { $0.string = Self.replacementLink.redacted }
            await store.send(.giftCardCoordFlow(.pasteLink(.textChanged(Self.replacementLink.redacted))))
            #expect(store.state.giftCardCoordFlowState.pasteLinkState?.text == Self.replacementLink.redacted)
            #expect(store.state.giftCardCoordFlowState.pasteLinkState?.clipboardValuesToClear == [Self.replacementLink.redacted])
            #expect(clipboard.value.string == Self.replacementLink.redacted)
        } else {
            await store.send(.home(.settingsTapped))
        }
        await store.finish()
        #expect(clipboard.value.candidates == expectedCandidates)
    }
}
