//
//  ExportViewingKeysLifecycleTests.swift
//  zodlTests
//

import ComposableArchitecture
import Foundation
import Testing
import UIKit
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct ExportViewingKeysLifecycleTests {
    @Test
    func hidingCancelsSuspendedQRAndLateCompletionCannotRevealData() async throws {
        let entered = SignalledRecords<Void>()
        let gate = ResumableGate()
        let png = ViewingKeyPNG(data: Data([0x01]))
        let store = try await makeStore(png: { _ in
            entered.recordCall()
            await gate.wait()
            return png
        })
        await enterAndReveal(store)
        await entered.countReached(1)

        await store.send(.hideTapped) {
            $0.detail?.isRevealed = false
            $0.detail?.key = nil
            $0.detail?.qrRequestID = nil
        }
        gate.open()
        await store.finish()
        #expect(store.state.detail?.key == nil)
        #expect(store.state.detail?.qr == nil)
    }

    @Test
    func backCancelsSuspendedQRAndReturnsToTheRetainedChooser() async throws {
        let entered = SignalledRecords<Void>()
        let gate = ResumableGate()
        let png = ViewingKeyPNG(data: Data([0x03]))
        let store = try await makeStore(png: { _ in
            entered.recordCall()
            await gate.wait()
            return png
        })
        await enterAndReveal(store)
        await entered.countReached(1)

        await store.send(.backTapped) {
            $0.detail = nil
        }
        gate.open()
        await store.finish()
        #expect(store.state.selectedKind == .incoming)
    }

    @Test
    func accountRemovalDuringSuspendedQRInvalidatesAndRejectsTheLateResult() async throws {
        let entered = SignalledRecords<Void>()
        let gate = ResumableGate()
        let png = ViewingKeyPNG(data: Data([0x04]))
        let store = try await makeStore(png: { _ in
            entered.recordCall()
            await gate.wait()
            return png
        })
        await enterAndReveal(store)
        await entered.countReached(1)
        store.state.$walletAccounts.withLock { $0 = [] }

        await store.send(.validateSession) {
            $0.isInvalidated = true
            $0.detail?.isRevealed = false
            $0.detail?.key = nil
            $0.detail?.qrRequestID = nil
        }
        await store.receive(.delegate(.finished))
        gate.open()
        await store.finish()
        #expect(store.state.detail?.qr == nil)
    }

    @Test
    func hideCancelsOneSuspendedShareAndRepeatedTapStartsNoSecondRequest() async throws {
        let ordinals = SignalledRecords<Int>()
        let gate = ResumableGate()
        let count = LockIsolated(0)
        let png = defaultPNG
        let store = try await makeStore(png: { _ in
            let ordinal = count.withValue { value in
                value += 1
                return value
            }
            ordinals.record(ordinal)
            if ordinal == 2 {
                await gate.wait()
            }
            return png
        })
        await enterAndReveal(store, receiveQR: true)
        await store.send(.shareTapped) {
            $0.detail?.shareRequestID = UUID(1)
        }
        await ordinals.recorded { $0.contains(2) }
        await store.send(.shareTapped)
        #expect(ordinals.values == [1, 2])

        await store.send(.hideTapped) {
            $0.detail?.isRevealed = false
            $0.detail?.key = nil
            $0.detail?.qr = nil
            $0.detail?.shareRequestID = nil
        }
        gate.open()
        await store.finish()
        #expect(store.state.detail?.sharePayload == nil)
    }

    @Test
    func staleQRAndShareResultsAreRejectedIndependentlyOfCancellation() async throws {
        let store = try await makeStore()
        await enterAndReveal(store, receiveQR: true)
        let key = try #require(store.state.detail?.key)
        let staleID = UUID()
        let stalePNG = ViewingKeyPNG(data: Data([0x44]))
        let stalePayload = ViewingKeySharePayload(id: staleID, key: key, png: stalePNG)

        await store.send(.qrReady(staleID, .success(stalePNG)))
        await store.send(.shareReady(staleID, .success(stalePayload)))
        #expect(store.state.detail?.qr != stalePNG)
        #expect(store.state.detail?.sharePayload == nil)
    }

    @Test
    func accountRemovalInvalidatesEvenWhenSelectionStillMatches() async throws {
        let store = try await makeStore()
        store.state.$walletAccounts.withLock { $0 = [] }

        await store.send(.validateSession) {
            $0.isInvalidated = true
        }
        await store.receive(.delegate(.finished))
        #expect(!store.state.isSessionValid)
    }

    @Test
    func sameIDReplacementWithDifferentVendorInvalidatesTheSession() async throws {
        let store = try await makeStore()
        let replacement = try await ViewingKeyExportFixtures.account(vendor: .keystone)
        store.state.$walletAccounts.withLock { $0 = [replacement] }

        await store.send(.validateSession) {
            $0.isInvalidated = true
        }
        await store.receive(.delegate(.finished))
    }

    @Test
    func selectedAccountChangeInvalidatesEvenWhenCapturedMemberRemains() async throws {
        let store = try await makeStore()
        let replacement = ViewingKeyExportFixtures.replacingID(
            in: try #require(store.state.selectedWalletAccount),
            byte: 0x7f
        )
        store.state.$selectedWalletAccount.withLock { $0 = replacement }

        await store.send(.validateSession) {
            $0.isInvalidated = true
        }
        await store.receive(.delegate(.finished))
    }

    @Test
    func everyActionRefreshesTheLiveNetworkBeforeHandlingIt() async throws {
        let network = LockIsolated(NetworkType.mainnet)
        let store = try await makeStore(network: network)
        network.setValue(.testnet)

        await store.send(.selectTab(.keyString)) {
            $0.currentNetwork = .testnet
            $0.isInvalidated = true
        }
        await store.receive(.delegate(.finished))
    }

    @Test
    func invalidationIsMonotonicWhenTheOriginalAccountReturns() async throws {
        let store = try await makeStore()
        let original = try #require(store.state.selectedWalletAccount)
        store.state.$selectedWalletAccount.withLock { $0 = nil }
        await store.send(.validateSession) {
            $0.isInvalidated = true
        }
        await store.receive(.delegate(.finished))

        store.state.$selectedWalletAccount.withLock { $0 = original }
        store.state.$walletAccounts.withLock { $0 = [original] }
        await store.send(.validateSession)
        #expect(!store.state.isSessionValid)
    }

    @Test
    func receiveAddressStashRefreshKeepsTheSessionValid() async throws {
        let store = try await makeStore()
        var refreshed = try #require(store.state.selectedWalletAccount)
        let fullViewingKey = try #require(refreshed.account.ufvk)
        refreshed.nextPrivateUA = try DerivationTool(networkType: .mainnet)
            .deriveUnifiedAddressFrom(ufvk: fullViewingKey.stringEncoded)
        store.state.$selectedWalletAccount.withLock { $0 = refreshed }
        store.state.$walletAccounts.withLock { $0 = [refreshed] }

        await store.send(.validateSession)
        #expect(store.state.isSessionValid)
    }

    @Test
    func activeRestartsInterruptedRevealedQRWithAFreshRequest() async throws {
        let entered = SignalledRecords<Int>()
        let firstGate = ResumableGate()
        let secondGate = ResumableGate()
        let callCount = LockIsolated(0)
        let firstPNG = ViewingKeyPNG(data: Data([0x01]))
        let secondPNG = ViewingKeyPNG(data: Data([0x02]))
        let store = try await makeStore(png: { _ in
            let ordinal = callCount.withValue { value in
                value += 1
                return value
            }
            entered.record(ordinal)
            if ordinal == 1 {
                await firstGate.wait()
                return firstPNG
            }
            await secondGate.wait()
            return secondPNG
        })
        await store.send(.selectKind(.incoming)) {
            $0.selectedKind = .incoming
        }
        await store.send(.continueTapped) {
            $0.detail = ExportViewingKeys.State.Detail(kind: .incoming)
        }
        await store.send(.selectTab(.keyString)) {
            $0.detail?.tab = .keyString
        }
        let key = store.state.session.key(for: .incoming)
        await store.send(.revealTapped) {
            $0.detail?.isRevealed = true
            $0.detail?.key = key
            $0.detail?.qrRequestID = UUID(0)
        }
        await entered.recorded { $0.contains(1) }

        await store.send(.becameInactive) {
            $0.isInactive = true
            $0.detail?.qrRequestID = nil
        }
        #expect(!store.state.isPayloadVisible)
        await store.send(.becameActive) {
            $0.isInactive = false
            $0.detail?.qrRequestID = UUID(1)
        }
        guard store.state.detail?.qrRequestID == UUID(1) else {
            firstGate.open()
            secondGate.open()
            await store.finish()
            return
        }
        await entered.recorded { $0.contains(2) }
        #expect(store.state.detail?.tab == .keyString)
        #expect(store.state.detail?.isRevealed == true)

        await store.send(.qrReady(UUID(0), .success(firstPNG)))
        #expect(store.state.detail?.qr == nil)
        secondGate.open()
        await store.receive(.qrReady(UUID(1), .success(secondPNG))) {
            $0.detail?.qr = secondPNG
            $0.detail?.qrRequestID = nil
        }
        firstGate.open()
        await store.finish()
    }

    @Test
    func activeReusesCompletedQRWithoutRestartingCancelledShare() async throws {
        let entered = SignalledRecords<Int>()
        let shareGate = ResumableGate()
        let callCount = LockIsolated(0)
        let png = defaultPNG
        let store = try await makeStore(png: { _ in
            let ordinal = callCount.withValue { value in
                value += 1
                return value
            }
            entered.record(ordinal)
            if ordinal == 2 {
                await shareGate.wait()
            }
            return png
        })
        await enterAndReveal(store, receiveQR: true)
        await store.send(.shareTapped) {
            $0.detail?.shareRequestID = UUID(1)
        }
        await entered.recorded { $0.contains(2) }

        await store.send(.becameInactive) {
            $0.isInactive = true
            $0.detail?.shareRequestID = nil
        }
        await store.send(.becameActive) {
            $0.isInactive = false
        }
        shareGate.open()
        await store.finish()

        #expect(entered.values == [1, 2])
        #expect(store.state.detail?.qr == png)
        #expect(store.state.detail?.qrRequestID == nil)
        #expect(store.state.detail?.shareRequestID == nil)
        #expect(store.state.detail?.sharePayload == nil)
    }

    @Test
    func presentedNativeShareRetainsOwnershipAcrossInactiveAndActive() async throws {
        let store = try await makeStore()
        await enterAndReveal(store, receiveQR: true)
        await store.send(.shareTapped) {
            $0.detail?.shareRequestID = UUID(1)
        }
        let key = try #require(store.state.detail?.key)
        let payload = ViewingKeySharePayload(id: UUID(1), key: key, png: defaultPNG)
        await store.receive(.shareReady(UUID(1), .success(payload))) {
            $0.detail?.shareRequestID = nil
            $0.detail?.sharePayload = payload
            $0.detail?.shareOwnership = ViewingKeyShareOwnership(payloadID: payload.id)
        }
        let ownership = try #require(store.state.detail?.shareOwnership)
        #expect(ownership.claimNativeOwnership())
        await store.send(.sharePresented) {
            $0.detail?.isSharePresented = true
        }
        await store.send(.becameInactive) {
            $0.isInactive = true
        }
        #expect(store.state.detail?.sharePayload != nil)
        await store.send(.becameActive) {
            $0.isInactive = false
        }
        await store.send(.shareDismissed) {
            $0.detail?.sharePayload = nil
            $0.detail?.shareOwnership = nil
            $0.detail?.isSharePresented = false
        }
        #expect(ownership.isFinished)
    }

    @Test
    func controllerConstructionRetainsNativePayloadBeforeAppearance() async throws {
        let store = try await makeStore()
        await enterAndReveal(store, receiveQR: true)
        await store.send(.shareTapped) {
            $0.detail?.shareRequestID = UUID(1)
        }
        let key = try #require(store.state.detail?.key)
        let payload = ViewingKeySharePayload(id: UUID(1), key: key, png: defaultPNG)
        await store.receive(.shareReady(UUID(1), .success(payload))) {
            $0.detail?.shareRequestID = nil
            $0.detail?.sharePayload = payload
            $0.detail?.shareOwnership = ViewingKeyShareOwnership(payloadID: payload.id)
        }
        let ownership = try #require(store.state.detail?.shareOwnership)
        var presentationCount = 0
        let controller = ViewingKeyActivityView.makeController(
            activityItems: ["public fixture"],
            ownership: ownership,
            onPresented: { presentationCount += 1 },
            onCompletion: {}
        )
        #expect(controller.didTransferPayload)
        #expect(ownership.hasNativeOwnership)

        await store.send(.becameInactive) {
            $0.isInactive = true
        }
        #expect(store.state.detail?.sharePayload != nil)

        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        #expect(presentationCount == 1)
        await store.send(.sharePresented) {
            $0.detail?.isSharePresented = true
        }
        await store.send(.shareDismissed) {
            $0.detail?.sharePayload = nil
            $0.detail?.shareOwnership = nil
            $0.detail?.isSharePresented = false
        }
        #expect(ownership.isFinished)
    }

    @Test
    func inactivityBeforeControllerConstructionCancelsWithoutTransferringPayload() async throws {
        let store = try await makeStore()
        await enterAndReveal(store, receiveQR: true)
        await store.send(.shareTapped) {
            $0.detail?.shareRequestID = UUID(1)
        }
        let key = try #require(store.state.detail?.key)
        let payload = ViewingKeySharePayload(id: UUID(1), key: key, png: defaultPNG)
        await store.receive(.shareReady(UUID(1), .success(payload))) {
            $0.detail?.shareRequestID = nil
            $0.detail?.sharePayload = payload
            $0.detail?.shareOwnership = ViewingKeyShareOwnership(payloadID: payload.id)
        }
        let ownership = try #require(store.state.detail?.shareOwnership)

        await store.send(.becameInactive) {
            $0.isInactive = true
            $0.detail?.sharePayload = nil
            $0.detail?.shareOwnership = nil
        }
        #expect(ownership.wasCancelledBeforeHandoff)

        var presentationCount = 0
        let controller = ViewingKeyActivityView.makeController(
            activityItems: ["public fixture"],
            ownership: ownership,
            onPresented: { presentationCount += 1 },
            onCompletion: {}
        )
        #expect(!controller.didTransferPayload)
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        #expect(presentationCount == 0)
    }

    @Test
    func backgroundInvalidatesAndFinishesWhileClearingDisclosure() async throws {
        let store = try await makeStore()
        await enterAndReveal(store, receiveQR: true)

        await store.send(.enteredBackground) {
            $0.isInvalidated = true
            $0.detail?.isRevealed = false
            $0.detail?.key = nil
            $0.detail?.qr = nil
        }
        await store.receive(.delegate(.finished))
    }

    @Test
    func detailBackCancelsPreparedNativeOwnershipBeforeControllerConstruction() async throws {
        let store = try await makeStore()
        await enterAndReveal(store, receiveQR: true)
        await store.send(.shareTapped) {
            $0.detail?.shareRequestID = UUID(1)
        }
        let key = try #require(store.state.detail?.key)
        let payload = ViewingKeySharePayload(id: UUID(1), key: key, png: defaultPNG)
        await store.receive(.shareReady(UUID(1), .success(payload))) {
            $0.detail?.shareRequestID = nil
            $0.detail?.sharePayload = payload
            $0.detail?.shareOwnership = ViewingKeyShareOwnership(payloadID: payload.id)
        }
        let ownership = try #require(store.state.detail?.shareOwnership)
        await store.send(.backTapped) {
            $0.detail = nil
        }
        #expect(ownership.wasCancelledBeforeHandoff)
        let controller = ViewingKeyActivityView.makeController(
            activityItems: ["public fixture"],
            ownership: ownership,
            onPresented: {},
            onCompletion: {}
        )
        #expect(!controller.didTransferPayload)
        #expect(store.state.selectedKind == .incoming)
    }

    private var defaultPNG: ViewingKeyPNG {
        ViewingKeyPNG(data: Data([0x89, 0x50, 0x4e, 0x47]))
    }

    private func makeStore(
        network: LockIsolated<NetworkType> = LockIsolated(.mainnet),
        png: (@Sendable (ViewingKeyMaterial) async throws -> ViewingKeyPNG)? = nil
    ) async throws -> TestStoreOf<ExportViewingKeys> {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let state = ExportViewingKeys.State(
            session: ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        )
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        let fallbackPNG = defaultPNG
        let pngProducer = png ?? { _ in fallbackPNG }
        return TestStore(initialState: state) {
            ExportViewingKeys()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.viewingKeyQRCode = ViewingKeyQRCodeClient(png: pngProducer)
            $0.zcashSDKEnvironment.network = {
                ZcashNetworkBuilder.network(for: network.value)
            }
        }
    }

    private func enterAndReveal(
        _ store: TestStoreOf<ExportViewingKeys>,
        receiveQR: Bool = false
    ) async {
        await store.send(.selectKind(.incoming)) {
            $0.selectedKind = .incoming
        }
        await store.send(.continueTapped) {
            $0.detail = ExportViewingKeys.State.Detail(kind: .incoming)
        }
        let expectedKey = store.state.session.key(for: .incoming)
        await store.send(.revealTapped) {
            $0.detail?.isRevealed = true
            $0.detail?.key = expectedKey
            $0.detail?.qrRequestID = UUID(0)
        }
        if receiveQR {
            let png = defaultPNG
            await store.receive(.qrReady(UUID(0), .success(png))) {
                $0.detail?.qr = png
                $0.detail?.qrRequestID = nil
            }
        }
    }
}
