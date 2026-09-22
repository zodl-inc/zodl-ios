import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ViewingKeyDetailTests {
    private static let png = ViewingKeyPNG(data: Data([0x89, 0x50, 0x4e, 0x47]))

    @Test(arguments: ViewingKeyTab.allCases)
    func hiddenShareIsRejectedOnEveryTab(_ tab: ViewingKeyTab) async throws {
        let store = try await makeDetailStore()

        if tab == .keyString {
            await store.send(.selectTab(tab)) {
                $0.detail.tab = tab
            }
        } else {
            await store.send(.selectTab(tab))
        }
        await store.send(.shareTapped)
        #expect(store.state.detail.shareRequestID == nil)
        #expect(store.state.detail.sharePayload == nil)
    }

    @Test
    func revealLoadsTheCapturedKeyAndQRWhileTabChangesPreserveDisclosure() async throws {
        let store = try await makeDetailStore()
        let expectedKey = store.state.session.key(for: .incoming)

        await store.send(.revealTapped) {
            $0.detail.isRevealed = true
            $0.detail.key = expectedKey
            $0.detail.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .success(Self.png))) {
            $0.detail.qr = Self.png
            $0.detail.qrRequestID = nil
        }
        #expect(store.state.isPayloadVisible)
        await store.send(.selectTab(.keyString)) {
            $0.detail.tab = .keyString
        }
        #expect(store.state.detail.isRevealed == true)
        await store.send(.displayKeyString)
        #expect(store.state.detail.isRevealed == true)
    }

    @Test(arguments: ViewingKeyTab.allCases)
    func bothTabsShareTheExactKeyAndPNGAtomically(_ tab: ViewingKeyTab) async throws {
        let encodedMaterials = SignalledRecords<ViewingKeyMaterial>()
        let png = Self.png
        let store = try await makeDetailStore(png: { material in
            encodedMaterials.record(material)
            return png
        })
        let expectedKey = store.state.session.key(for: .incoming)
        if tab == .keyString {
            await store.send(.selectTab(tab)) {
                $0.detail.tab = tab
            }
        } else {
            await store.send(.selectTab(tab))
        }
        await store.send(.revealTapped) {
            $0.detail.isRevealed = true
            $0.detail.key = expectedKey
            $0.detail.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .success(png))) {
            $0.detail.qr = png
            $0.detail.qrRequestID = nil
        }
        await store.send(.shareTapped) {
            $0.detail.shareRequestID = UUID(1)
        }
        let key = try #require(store.state.detail.key)
        let expectedPayload = ViewingKeySharePayload(id: UUID(1), key: key, png: png)
        await store.receive(.shareReady(UUID(1), .success(expectedPayload))) {
            $0.detail.shareRequestID = nil
            $0.detail.sharePayload = expectedPayload
            $0.detail.shareOwnership = ViewingKeyShareOwnership(payloadID: expectedPayload.id)
        }
        let payload = try #require(store.state.detail.sharePayload)
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
        let store = try await makeDetailStore()
        let expectedKey = store.state.session.key(for: .incoming)
        await store.send(.selectTab(.keyString)) {
            $0.detail.tab = .keyString
        }
        await store.send(.revealTapped) {
            $0.detail.isRevealed = true
            $0.detail.key = expectedKey
            $0.detail.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .success(Self.png))) {
            $0.detail.qr = Self.png
            $0.detail.qrRequestID = nil
        }

        await store.send(.hideTapped) {
            $0.detail.isRevealed = false
            $0.detail.key = nil
            $0.detail.qr = nil
            $0.detail.qrFailed = false
            $0.detail.qrRequestID = nil
            $0.detail.shareRequestID = nil
            $0.detail.sharePayload = nil
        }
        #expect(store.state.detail.tab == .keyString)
    }

    @Test
    func qrFailureLeavesTheRevealedStringUsable() async throws {
        let store = try await makeDetailStore(png: { _ in
            throw ViewingKeyQRCodeError.generationFailed
        })
        let key = store.state.session.key(for: .incoming)

        await store.send(.revealTapped) {
            $0.detail.isRevealed = true
            $0.detail.key = key
            $0.detail.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .failure(.generationFailed))) {
            $0.detail.qrFailed = true
            $0.detail.qrRequestID = nil
        }
        #expect(store.state.detail.key != nil)
        #expect(store.state.isPayloadVisible)
    }

    @Test
    func sharingPNGFailureShowsOnlyTheGenericErrorAndCreatesNoPayload() async throws {
        let calls = LockIsolated(0)
        let png = Self.png
        let store = try await makeDetailStore(png: { _ in
            let ordinal = calls.withValue { value in
                value += 1
                return value
            }
            guard ordinal == 1 else {
                throw ViewingKeyQRCodeError.generationFailed
            }
            return png
        })
        let key = store.state.session.key(for: .incoming)
        await store.send(.revealTapped) {
            $0.detail.isRevealed = true
            $0.detail.key = key
            $0.detail.qrRequestID = UUID(0)
        }
        await store.receive(.qrReady(UUID(0), .success(png))) {
            $0.detail.qr = png
            $0.detail.qrRequestID = nil
        }

        await store.send(.shareTapped) {
            $0.detail.shareRequestID = UUID(1)
        }
        await store.receive(.shareReady(UUID(1), .failure(.generationFailed))) {
            $0.detail.shareRequestID = nil
            $0.sharingError = true
        }
        #expect(store.state.detail.sharePayload == nil)
        await store.send(.dismissError) {
            $0.sharingError = false
        }
    }

    private func makeDetailStore(
        png: (@Sendable (ViewingKeyMaterial) async throws -> ViewingKeyPNG)? = nil
    ) async throws -> TestStoreOf<ViewingKeyDetail> {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let state = ViewingKeyDetail.State(
            session: ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet),
            kind: .incoming
        )
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        let fallbackPNG = Self.png
        let pngProducer = png ?? { _ in fallbackPNG }
        return TestStore(initialState: state) {
            ViewingKeyDetail()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.viewingKeyQRCode = ViewingKeyQRCodeClient(png: pngProducer)
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
        }
    }
}
