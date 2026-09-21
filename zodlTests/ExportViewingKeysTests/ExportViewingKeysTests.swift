//
//  ExportViewingKeysTests.swift
//  zodlTests
//

import ComposableArchitecture
import CustomDump
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ExportViewingKeysTests {
    private static let png = ViewingKeyPNG(data: Data([0x89, 0x50, 0x4e, 0x47]))

    @Test(arguments: 0..<8)
    func onlyThreeAcknowledgementsPermitFullExport(_ bits: Int) async throws {
        let store = try await makeStore()

        await store.send(.selectKind(.full)) {
            $0.selectedKind = .full
        }
        await store.send(.continueTapped) {
            $0.consent = []
            $0.isConsentPresented = true
        }
        for (index, item) in ViewingKeyConsent.allCases.enumerated() where bits & (1 << index) != 0 {
            await store.send(.consentChanged(item, true)) {
                $0.consent.insert(item)
            }
        }
        if bits == 7 {
            await store.send(.exportFullTapped) {
                $0.isConsentPresented = false
                $0.pendingFullExport = true
            }
        } else {
            await store.send(.exportFullTapped)
        }
        #expect(store.state.detail == nil)
        if bits == 7 {
            await store.send(.consentDismissed) {
                $0.pendingFullExport = false
                $0.detail = ExportViewingKeys.State.Detail(kind: .full)
            }
        } else {
            await store.send(.consentDismissed) {
                $0.consent = []
                $0.isConsentPresented = false
            }
        }
        #expect((store.state.detail != nil) == (bits == 7))
    }

    @Test
    func chooserRequiresSelectionAndAnAvailableKey() async throws {
        let store = try await makeStore()

        #expect(!store.state.canContinue)
        await store.send(.continueTapped)
        await store.send(.selectKind(.incoming)) {
            $0.selectedKind = .incoming
        }
        #expect(store.state.canContinue)
        await store.send(.selectKind(.incoming))
        await store.send(.continueTapped) {
            $0.detail = ExportViewingKeys.State.Detail(kind: .incoming)
        }

        let unavailableStore = try await makeStore(keysAvailable: false)
        await unavailableStore.send(.selectKind(.full)) {
            $0.selectedKind = .full
            $0.unavailableKey = true
        }
        #expect(!unavailableStore.state.canContinue)
        await unavailableStore.send(.continueTapped)
    }

    @Test
    func fullConsentCancellationRetainsSelectionAndNextAttemptStartsFresh() async throws {
        let store = try await makeStore()

        await store.send(.selectKind(.full)) {
            $0.selectedKind = .full
        }
        await store.send(.continueTapped) {
            $0.consent = []
            $0.isConsentPresented = true
        }
        await store.send(.consentChanged(.history, true)) {
            $0.consent = [.history]
        }
        await store.send(.cancelConsent) {
            $0.consent = []
            $0.isConsentPresented = false
            $0.pendingFullExport = false
        }
        #expect(store.state.selectedKind == .full)
        await store.send(.continueTapped) {
            $0.consent = []
            $0.isConsentPresented = true
        }
    }

    @Test
    func swipingConsentAwayRetainsSelectionAndNextAttemptStartsFresh() async throws {
        let store = try await makeStore()
        await store.send(.selectKind(.full)) {
            $0.selectedKind = .full
        }
        await store.send(.continueTapped) {
            $0.consent = []
            $0.isConsentPresented = true
        }
        await store.send(.consentChanged(.recipient, true)) {
            $0.consent = [.recipient]
        }

        await store.send(.consentDismissed) {
            $0.consent = []
            $0.isConsentPresented = false
        }
        #expect(store.state.selectedKind == .full)
        await store.send(.continueTapped) {
            $0.consent = []
            $0.isConsentPresented = true
        }
    }

    @Test
    func directFullExportAndDismissalCannotBypassTheOpenConsentSheet() async throws {
        let store = try await makeStore()

        await store.send(.selectKind(.full)) {
            $0.selectedKind = .full
        }
        for item in ViewingKeyConsent.allCases {
            await store.send(.consentChanged(item, true))
        }
        await store.send(.exportFullTapped)
        await store.send(.consentDismissed)
        #expect(store.state.detail == nil)
    }

    @Test
    func featureStateDiagnosticsCannotTraverseViewingKeys() async throws {
        let store = try await makeStore()
        let account = try #require(store.state.selectedWalletAccount)
        let incoming = try #require(account.account.uivk?.stringEncoded)
        let full = try #require(account.account.ufvk?.stringEncoded)
        var dump = ""

        customDump(store.state, to: &dump)

        #expect(!dump.contains(incoming))
        #expect(!dump.contains(full))
    }

    @Test(arguments: ViewingKeyTab.allCases)
    func hiddenShareIsRejectedOnEveryTab(_ tab: ViewingKeyTab) async throws {
        let store = try await makeStore()

        await enterIncomingDetail(store)
        if tab == .keyString {
            await store.send(.selectTab(tab)) {
                $0.detail?.tab = tab
            }
        } else {
            await store.send(.selectTab(tab))
        }
        await store.send(.shareTapped)
        #expect(store.state.detail?.shareRequestID == nil)
        #expect(store.state.detail?.sharePayload == nil)
    }

    @Test
    func revealLoadsTheCapturedKeyAndQRWhileTabChangesPreserveDisclosure() async throws {
        let store = try await makeStore()
        await enterIncomingDetail(store)
        let expectedKey = store.state.session.key(for: .incoming)

        await store.send(.revealTapped) {
            $0.detail?.isRevealed = true
            $0.detail?.key = expectedKey
            $0.detail?.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .success(Self.png))) {
            $0.detail?.qr = Self.png
            $0.detail?.qrRequestID = nil
        }
        #expect(store.state.isPayloadVisible)
        await store.send(.selectTab(.keyString)) {
            $0.detail?.tab = .keyString
        }
        #expect(store.state.detail?.isRevealed == true)
        await store.send(.displayKeyString)
        #expect(store.state.detail?.isRevealed == true)
    }

    @Test(arguments: ViewingKeyTab.allCases)
    func bothTabsShareTheExactKeyAndPNGAtomically(_ tab: ViewingKeyTab) async throws {
        let encodedMaterials = SignalledRecords<ViewingKeyMaterial>()
        let png = Self.png
        let store = try await makeStore(png: { material in
            encodedMaterials.record(material)
            return png
        })
        await enterIncomingDetail(store)
        let expectedKey = store.state.session.key(for: .incoming)
        if tab == .keyString {
            await store.send(.selectTab(tab)) {
                $0.detail?.tab = tab
            }
        } else {
            await store.send(.selectTab(tab))
        }
        await store.send(.revealTapped) {
            $0.detail?.isRevealed = true
            $0.detail?.key = expectedKey
            $0.detail?.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .success(png))) {
            $0.detail?.qr = png
            $0.detail?.qrRequestID = nil
        }
        await store.send(.shareTapped) {
            $0.detail?.shareRequestID = UUID(1)
        }
        let key = try #require(store.state.detail?.key)
        let expectedPayload = ViewingKeySharePayload(id: UUID(1), key: key, png: png)
        await store.receive(.shareReady(UUID(1), .success(expectedPayload))) {
            $0.detail?.shareRequestID = nil
            $0.detail?.sharePayload = expectedPayload
        }
        let payload = try #require(store.state.detail?.sharePayload)
        let encoded = encodedMaterials.values
        let encodedTwice = encoded.count == 2
        let revealEncodedCapturedKey = encoded.first?.rawValue == key.rawValue
        let shareEncodedCapturedKey = encoded.last?.rawValue == key.rawValue
        let keyMatches = payload.key.rawValue == key.rawValue
        let pngMatches = payload.png == png
        #expect(encodedTwice)
        #expect(revealEncodedCapturedKey)
        #expect(shareEncodedCapturedKey)
        #expect(keyMatches)
        #expect(pngMatches)
    }

    @Test
    func hideClearsFlowOwnedDisclosureButRetainsTheSelectedTab() async throws {
        let store = try await makeStore()
        await enterIncomingDetail(store)
        let expectedKey = store.state.session.key(for: .incoming)
        await store.send(.selectTab(.keyString)) {
            $0.detail?.tab = .keyString
        }
        await store.send(.revealTapped) {
            $0.detail?.isRevealed = true
            $0.detail?.key = expectedKey
            $0.detail?.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .success(Self.png))) {
            $0.detail?.qr = Self.png
            $0.detail?.qrRequestID = nil
        }

        await store.send(.hideTapped) {
            $0.detail?.isRevealed = false
            $0.detail?.key = nil
            $0.detail?.qr = nil
            $0.detail?.qrFailed = false
            $0.detail?.qrRequestID = nil
            $0.detail?.shareRequestID = nil
            $0.detail?.sharePayload = nil
        }
        #expect(store.state.detail?.tab == .keyString)
    }

    @Test
    func backRetainsChooserSelectionAndReentryStartsHiddenOnQR() async throws {
        let store = try await makeStore()
        await enterIncomingDetail(store)
        await store.send(.selectTab(.keyString)) {
            $0.detail?.tab = .keyString
        }
        await store.send(.backTapped) {
            $0.detail = nil
        }
        #expect(store.state.selectedKind == .incoming)
        await store.send(.continueTapped) {
            $0.detail = ExportViewingKeys.State.Detail(kind: .incoming)
        }
        #expect(store.state.detail?.tab == .qrCode)
        #expect(store.state.detail?.isRevealed == false)
    }

    @Test
    func qrFailureLeavesTheRevealedStringUsable() async throws {
        let store = try await makeStore(png: { _ in
            throw ViewingKeyQRCodeError.generationFailed
        })
        await enterIncomingDetail(store)
        let key = store.state.session.key(for: .incoming)

        await store.send(.revealTapped) {
            $0.detail?.isRevealed = true
            $0.detail?.key = key
            $0.detail?.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .failure(.generationFailed))) {
            $0.detail?.qrFailed = true
            $0.detail?.qrRequestID = nil
        }
        #expect(store.state.detail?.key != nil)
        #expect(store.state.isPayloadVisible)
    }

    @Test
    func sharingPNGFailureShowsOnlyTheGenericErrorAndCreatesNoPayload() async throws {
        let calls = LockIsolated(0)
        let png = Self.png
        let store = try await makeStore(png: { _ in
            let ordinal = calls.withValue { value in
                value += 1
                return value
            }
            guard ordinal == 1 else {
                throw ViewingKeyQRCodeError.generationFailed
            }
            return png
        })
        await enterIncomingDetail(store)
        let key = store.state.session.key(for: .incoming)
        await store.send(.revealTapped) {
            $0.detail?.isRevealed = true
            $0.detail?.key = key
            $0.detail?.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .success(png))) {
            $0.detail?.qr = png
            $0.detail?.qrRequestID = nil
        }

        await store.send(.shareTapped) {
            $0.detail?.shareRequestID = UUID(1)
        }
        await store.receive(.shareReady(UUID(1), .failure(.generationFailed))) {
            $0.detail?.shareRequestID = nil
            $0.sharingError = true
        }
        #expect(store.state.detail?.sharePayload == nil)
        await store.send(.dismissError) {
            $0.sharingError = false
        }
    }

    private func enterIncomingDetail(_ store: TestStoreOf<ExportViewingKeys>) async {
        await store.send(.selectKind(.incoming)) {
            $0.selectedKind = .incoming
        }
        await store.send(.continueTapped) {
            $0.detail = ExportViewingKeys.State.Detail(kind: .incoming)
        }
    }

    private func makeStore(
        keysAvailable: Bool = true,
        png: (@Sendable (ViewingKeyMaterial) async throws -> ViewingKeyPNG)? = nil
    ) async throws -> TestStoreOf<ExportViewingKeys> {
        let account = if keysAvailable {
            try await ViewingKeyExportFixtures.account(vendor: .zcash)
        } else {
            try await ViewingKeyExportFixtures.accountWithoutViewingKeys(vendor: .zcash)
        }
        let state = ExportViewingKeys.State(
            session: ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        )
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        let fallbackPNG = Self.png
        let pngProducer = png ?? { _ in fallbackPNG }
        return TestStore(initialState: state) {
            ExportViewingKeys()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.viewingKeyQRCode = ViewingKeyQRCodeClient(png: pngProducer)
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
        }
    }
}
