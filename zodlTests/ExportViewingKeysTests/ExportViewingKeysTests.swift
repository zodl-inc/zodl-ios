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
            await store.send(.consentDismissed) {
                $0.pendingFullExport = false
                $0.consent = []
                $0.pendingOpenDetail = .full
            }
            await store.receive(.delegate(.openDetail(.full)))
        } else {
            await store.send(.exportFullTapped)
            await store.send(.consentDismissed) {
                $0.consent = []
                $0.isConsentPresented = false
            }
            #expect(store.state.pendingOpenDetail == nil)
        }
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
        await store.send(.continueTapped) {
            $0.pendingOpenDetail = .incoming
        }
        await store.receive(.delegate(.openDetail(.incoming)))

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
        #expect(store.state.pendingOpenDetail == nil)
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
