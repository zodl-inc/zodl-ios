import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

// Settings has non-Equatable destinations. This test-only comparison covers the export
// boundary; assertions below explicitly inspect route contents and captured provenance.
extension Settings.State: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path.ids == rhs.path.ids
            && lhs.isViewingKeyInactive == rhs.isViewingKeyInactive
            && lhs.pendingViewingKeyAuthentication == rhs.pendingViewingKeyAuthentication
            && lhs.path.compactMap { $0.exportViewingKeys } == rhs.path.compactMap { $0.exportViewingKeys }
    }
}

@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct SettingsViewingKeyExportTests {
    @Test(arguments: [true, false])
    func entryWaitsForAuthenticationAndConsumesTheResultOnce(success: Bool) async throws {
        let gate = ResumableGate()
        let calls = SignalledRecords<Void>()
        let store = try await makeStore(authenticate: {
            calls.recordCall()
            await gate.wait()
            return success
        })
        let advancedID = try #require(store.state.path.ids.last)
        await tapExport(store, id: advancedID)
        await calls.countReached(1)
        let request = try #require(store.state.pendingViewingKeyAuthentication)
        #expect(store.state.path.count == 1)
        await tapExport(store, id: advancedID)
        #expect(calls.values.count == 1)
        gate.open()
        await store.receive(\.viewingKeyAuthenticationFinished)
        #expect(store.state.pendingViewingKeyAuthentication == nil)
        #expect(store.state.path.count == (success ? 2 : 1))
        if success {
            let flow = try #require(store.state.path.last?.exportViewingKeys)
            #expect(flow.session == request.session)
            #expect(flow.selectedKind == nil)
        }
        await store.send(.viewingKeyAuthenticationFinished(request.requestID, true))
        #expect(store.state.path.count == (success ? 2 : 1))
        await store.finish()
    }

    @Test
    func missingAccountAndForgedGrantNeverAuthenticateOrNavigate() async throws {
        let store = try await makeStore()
        store.state.$selectedWalletAccount.withLock { $0 = nil }
        let id = try #require(store.state.path.ids.last)
        await tapExport(store, id: id)
        await store.send(.path(.element(id: id, action: .advancedSettings(.operationAccessGranted(.exportViewingKey)))))
        await store.send(.viewingKeyAuthenticationFinished(UUID(), true))
        #expect(store.state.path.count == 1)
        #expect(store.state.pendingViewingKeyAuthentication == nil)
        await store.finish()
    }

    @Test(arguments: ["nil", "other", "network", "removed", "replaced", "duplicate", "left"])
    func lateAuthenticationCannotEnterAfterProvenanceChanges(change: String) async throws {
        let gate = ResumableGate()
        let calls = SignalledRecords<Void>()
        let network = LockIsolated(NetworkType.mainnet)
        let store = try await makeStore(network: network, authenticate: {
            calls.recordCall()
            await gate.wait()
            return true
        })
        let id = try #require(store.state.path.ids.last)
        await tapExport(store, id: id)
        await calls.countReached(1)
        let original = try #require(store.state.selectedWalletAccount)
        switch change {
        case "nil": store.state.$selectedWalletAccount.withLock { $0 = nil }
        case "other":
            let other = ViewingKeyExportFixtures.replacingID(in: original, byte: 0x7f)
            store.state.$selectedWalletAccount.withLock { $0 = other }
            store.state.$walletAccounts.withLock { $0 = [original, other] }
        case "network": network.setValue(.testnet)
        case "removed": store.state.$walletAccounts.withLock { $0 = [] }
        case "replaced":
            let replacement = try await ViewingKeyExportFixtures.accountWithoutViewingKeys(vendor: .zcash)
            store.state.$walletAccounts.withLock { $0 = [replacement] }
        case "duplicate": store.state.$walletAccounts.withLock { $0 = [original, original] }
        default: await store.send(.aboutTapped)
        }
        // No SwiftUI observation action: the result itself must revalidate live provenance.
        gate.open()
        await store.receive(\.viewingKeyAuthenticationFinished)
        #expect(store.state.path.compactMap { $0.exportViewingKeys }.isEmpty)
        #expect(store.state.pendingViewingKeyAuthentication == nil)
        await store.finish()
    }

    @Test
    func staleTokenDoesNotConsumeTheCurrentRequest() async throws {
        let gate = ResumableGate()
        let calls = SignalledRecords<Void>()
        let store = try await makeStore(authenticate: {
            calls.recordCall()
            await gate.wait()
            return true
        })
        await tapExport(store, id: try #require(store.state.path.ids.last))
        await calls.countReached(1)
        let request = try #require(store.state.pendingViewingKeyAuthentication)
        await store.send(.viewingKeyAuthenticationFinished(UUID(99), true))
        #expect(store.state.pendingViewingKeyAuthentication == request)
        #expect(store.state.path.count == 1)
        gate.open()
        await store.receive(\.viewingKeyAuthenticationFinished)
        #expect(store.state.path.last?.exportViewingKeys != nil)
        await store.finish()
    }

    @Test
    func inactivityDuringAuthenticationKeepsTheRequestAndMasksTheNewFlow() async throws {
        let gate = ResumableGate()
        let calls = SignalledRecords<Void>()
        let store = try await makeStore(authenticate: {
            calls.recordCall()
            await gate.wait()
            return true
        })
        await tapExport(store, id: try #require(store.state.path.ids.last))
        await calls.countReached(1)
        await store.send(.viewingKeyBecameInactive)
        #expect(store.state.pendingViewingKeyAuthentication != nil)
        gate.open()
        await store.receive(\.viewingKeyAuthenticationFinished)
        #expect(store.state.path.last?.exportViewingKeys?.isInactive == true)
        await store.send(.viewingKeyBecameActive)
        await store.receive(\.path)
        #expect(store.state.path.last?.exportViewingKeys?.isInactive == false)
        await store.finish()
    }

    @Test(arguments: ["background", "home", "pop", "disappeared", "invalidate", "provenance"])
    func exitCancelsPendingAuthenticationAndRejectsItsLateResult(exit: String) async throws {
        let gate = ResumableGate()
        let calls = SignalledRecords<Void>()
        let store = try await makeStore(authenticate: {
            calls.recordCall()
            await gate.wait()
            return true
        })
        let id = try #require(store.state.path.ids.last)
        await tapExport(store, id: id)
        await calls.countReached(1)
        let request = try #require(store.state.pendingViewingKeyAuthentication)
        switch exit {
        case "background": await store.send(.viewingKeyEnteredBackground)
        case "home": await store.send(.backToHomeTapped)
        case "pop": await store.send(.path(.popFrom(id: id)))
        case "disappeared": await store.send(.viewingKeySettingsDisappeared)
        case "provenance":
            store.state.$selectedWalletAccount.withLock { $0 = nil }
            await store.send(.validateViewingKeySession)
        default: await store.send(.invalidateViewingKeyExport)
        }
        #expect(store.state.pendingViewingKeyAuthentication == nil)
        gate.open()
        await store.finish()
        await store.send(.viewingKeyAuthenticationFinished(request.requestID, true))
        #expect(store.state.path.compactMap { $0.exportViewingKeys }.isEmpty)
    }

    @Test(arguments: ["background", "home", "pop", "disappeared", "invalidate", "removed", "replaced"])
    func exitInvalidatesPreparedNativeShareBeforeRemovingTheRoute(exit: String) async throws {
        let store = try await makeStoreWithPreparedShare()
        let id = try #require(store.state.path.ids.last)
        let ownership = try #require(store.state.path.last?.exportViewingKeys?.detail?.shareOwnership)
        switch exit {
        case "background": await store.send(.viewingKeyEnteredBackground)
        case "home": await store.send(.backToHomeTapped)
        case "pop": await store.send(.path(.popFrom(id: id)))
        case "disappeared": await store.send(.viewingKeySettingsDisappeared)
        case "removed":
            store.state.$walletAccounts.withLock { $0 = [] }
            await store.send(.validateViewingKeySession)
        case "replaced":
            let replacement = try await ViewingKeyExportFixtures.accountWithoutViewingKeys(vendor: .zcash)
            store.state.$walletAccounts.withLock { $0 = [replacement] }
            await store.send(.validateViewingKeySession)
        default: await store.send(.invalidateViewingKeyExport)
        }
        #expect(store.state.path.count == 1)
        #expect(store.state.path.last?.advancedSettings != nil)
        #expect(ownership.wasCancelledBeforeHandoff)
        #expect(!ownership.claimNativeOwnership())
        await store.finish()
    }

    @Test
    func nativeShareInactivityMasksSynchronouslyAndDismissalPreservesTheRoute() async throws {
        let store = try await makeStoreWithPreparedShare()
        let id = try #require(store.state.path.ids.last)
        let ownership = try #require(store.state.path.last?.exportViewingKeys?.detail?.shareOwnership)
        #expect(ownership.claimNativeOwnership())
        await store.send(.viewingKeyBecameInactive)
        #expect(store.state.path.last?.exportViewingKeys?.isPayloadVisible == false)
        await store.receive(\.path)
        #expect(store.state.path.last?.exportViewingKeys?.detail?.sharePayload != nil)
        await store.send(.path(.element(id: id, action: .exportViewingKeys(.sharePresented))))
        await store.send(.viewingKeyBecameActive)
        await store.receive(\.path)
        #expect(store.state.path.last?.exportViewingKeys?.isPayloadVisible == true)
        await store.send(.path(.element(id: id, action: .exportViewingKeys(.shareDismissed))))
        #expect(store.state.path.count == 2)
        #expect(ownership.isFinished)
        await store.finish()
    }

    @Test
    func backgroundRetainsNativeOwnershipButNextEntryAuthenticatesAgain() async throws {
        let calls = SignalledRecords<Void>()
        let store = try await makeStoreWithPreparedShare(authenticate: {
            calls.recordCall()
            return true
        })
        let ownership = try #require(store.state.path.last?.exportViewingKeys?.detail?.shareOwnership)
        #expect(ownership.claimNativeOwnership())
        await store.send(.viewingKeyEnteredBackground)
        #expect(store.state.path.count == 1)
        #expect(ownership.hasNativeOwnership)
        await store.send(.viewingKeyBecameActive)
        await tapExport(store, id: try #require(store.state.path.ids.last))
        await store.receive(\.viewingKeyAuthenticationFinished)
        #expect(calls.values.count == 1)
        #expect(store.state.path.last?.exportViewingKeys?.detail == nil)
        await store.finish()
    }

    @Test(arguments: ["qr", "share"])
    func asynchronousFlowResultsRevalidateMembershipWithoutAnObserver(result: String) async throws {
        let store = try await makeStoreWithPreparedShare()
        let id = try #require(store.state.path.ids.last)
        let payload = try #require(store.state.path.last?.exportViewingKeys?.detail?.sharePayload)
        let ownership = try #require(store.state.path.last?.exportViewingKeys?.detail?.shareOwnership)
        store.state.$walletAccounts.withLock { $0 = [] }
        if result == "qr" {
            await store.send(.path(.element(id: id, action: .exportViewingKeys(.qrReady(UUID(72), .success(payload.png))))))
        } else {
            await store.send(.path(.element(id: id, action: .exportViewingKeys(.shareReady(UUID(73), .success(payload))))))
        }
        await store.receive(\.path)
        #expect(store.state.path.count == 1)
        #expect(ownership.wasCancelledBeforeHandoff)
        await store.finish()
    }

    @Test(arguments: ["delete", "disconnect-start", "disconnect-finished"])
    func destructiveSettingsActionsClearRetainedExport(action: String) async throws {
        let store = try await makeStoreWithPreparedShare()
        let ownership = try #require(store.state.path.last?.exportViewingKeys?.detail?.shareOwnership)
        let keystone = try await ViewingKeyExportFixtures.account(vendor: .keystone)
        store.state.$walletAccounts.withLock { $0.append(keystone) }
        store.dependencies.sdkSynchronizer.deleteAccount = { accountID in
            #expect(accountID == keystone.id)
            #expect(ownership.wasCancelledBeforeHandoff)
        }
        // Retained state can coexist with another destination during Root-driven transitions.
        let id: StackElementID
        let advancedID = try #require(store.state.path.ids.first)
        if action == "delete" {
            await store.send(.path(.element(id: advancedID, action: .advancedSettings(.operationAccessGranted(.resetZashi)))))
            id = try #require(store.state.path.ids.last)
            await store.send(.path(.element(id: id, action: .resetZashi(.deleteTapped(true)))))
        } else {
            await store.send(.path(.element(id: advancedID, action: .advancedSettings(.operationAccessGranted(.disconnectHWWallet)))))
            id = try #require(store.state.path.ids.last)
            let childAction: DisconnectHWWallet.Action = action == "disconnect-start" ? .disconnectConfirmed : .disconnectFinished
            await store.send(.path(.element(id: id, action: .disconnectHWWallet(childAction))))
            if action == "disconnect-start" {
                await store.receive(\.path)
            }
        }
        #expect(store.state.path.compactMap { $0.exportViewingKeys }.isEmpty)
        #expect(ownership.wasCancelledBeforeHandoff)
        await store.finish()
    }

    @Test
    func rootResetInvalidatesRetainedSettingsBeforeStartingTheWipe() async throws {
        let settingsStore = try await makeStoreWithPreparedShare()
        let ownership = try #require(settingsStore.state.path.last?.exportViewingKeys?.detail?.shareOwnership)
        var state = Root.State(
            destinationState: Root.DestinationState(internalDestination: .home),
            exportLogsState: ExportLogs.State(),
            onboardingState: RestoreWalletCoordFlow.State(),
            phraseDisplayState: RecoveryPhraseDisplay.State(),
            walletConfig: .initial,
            welcomeState: Welcome.State()
        )
        state.settingsState = settingsStore.state
        let store = TestStore(initialState: state) {
            CombineReducers {
                Scope(state: \Root.State.settingsState, action: \Root.Action.Cases.settings) { Settings() }
                Root().initializationReduce()
            }
        } withDependencies: {
            $0.sdkSynchronizer.wipe = {
                #expect(ownership.wasCancelledBeforeHandoff)
                return nil
            }
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        await store.send(.initialization(.resetZashiRequest(true)))
        await store.receive(\.settings)
        #expect(store.state.settingsState.path.compactMap { $0.exportViewingKeys }.isEmpty)
        #expect(ownership.wasCancelledBeforeHandoff)
        await store.receive { action in
            guard case .initialization(.resetZashi) = action else { return false }
            return true
        }
        await store.receive(\.resetZashiSDKFailed)
        await store.finish()
    }

    @Test(arguments: ["qr", "share"], ["pop", "background", "home"])
    func removingTheParentRouteCancelsSuspendedPayloadEffects(payload: String, exit: String) async throws {
        let entered = SignalledRecords<Void>()
        let gate = ResumableGate()
        let store = try await makeStoreWithPreparedShare(png: { _ in
            entered.recordCall()
            await gate.wait()
            return ViewingKeyPNG(data: Data([0x89, 0x50]))
        })
        let id = try #require(store.state.path.ids.last)
        await store.send(.path(.element(id: id, action: .exportViewingKeys(.shareDismissed))))
        if payload == "qr" {
            await store.send(.path(.element(id: id, action: .exportViewingKeys(.hideTapped))))
            await store.send(.path(.element(id: id, action: .exportViewingKeys(.revealTapped))))
        } else {
            await store.send(.path(.element(id: id, action: .exportViewingKeys(.shareTapped))))
        }
        await entered.countReached(1)
        switch exit {
        case "pop": await store.send(.path(.popFrom(id: id)))
        case "background": await store.send(.viewingKeyEnteredBackground)
        default: await store.send(.backToHomeTapped)
        }
        #expect(store.state.path.count == 1)
        gate.open()
        await store.finish()
        #expect(store.state.path.last?.advancedSettings != nil)
    }

    @Test
    func keystoneUsesTheSameAuthenticatedEntry() async throws {
        let store = try await makeStore(authenticate: { true })
        let keystone = try await ViewingKeyExportFixtures.account(vendor: .keystone)
        store.state.$selectedWalletAccount.withLock { $0 = keystone }
        store.state.$walletAccounts.withLock { $0 = [keystone] }
        await tapExport(store, id: try #require(store.state.path.ids.last))
        #expect(store.state.path.count == 1)
        await store.receive(\.viewingKeyAuthenticationFinished)
        #expect(store.state.path.last?.exportViewingKeys?.session.vendor == .keystone)
        await store.finish()
    }

    private func makeStoreWithPreparedShare(
        png pngProducer: (@Sendable (ViewingKeyMaterial) async throws -> ViewingKeyPNG)? = nil,
        authenticate: (@Sendable () async -> Bool)? = nil
    ) async throws -> TestStoreOf<Settings> {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        var state = Settings.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        state.path.append(.advancedSettings(AdvancedSettings.State()))
        var flow = ExportViewingKeys.State(session: ViewingKeyExportSession(id: UUID(70), account: account, network: .mainnet))
        let key = try #require(flow.session.key(for: .incoming))
        let png = ViewingKeyPNG(data: Data([0x89, 0x50]))
        flow.selectedKind = .incoming
        flow.detail = ExportViewingKeys.State.Detail(kind: .incoming)
        flow.detail?.isRevealed = true
        flow.detail?.key = key
        flow.detail?.qr = png
        flow.detail?.sharePayload = ViewingKeySharePayload(id: UUID(71), key: key, png: png)
        flow.detail?.shareOwnership = ViewingKeyShareOwnership(payloadID: UUID(71))
        state.path.append(.exportViewingKeys(flow))
        let store = TestStore(initialState: state) { Settings() } withDependencies: {
            $0.uuid = .incrementing
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: .mainnet) }
            if let pngProducer { $0.viewingKeyQRCode.png = pngProducer }
            if let authenticate { $0.localAuthentication.authenticate = authenticate }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private func makeStore(
        network: LockIsolated<NetworkType> = LockIsolated(.mainnet),
        authenticate: (@Sendable () async -> Bool)? = nil
    ) async throws -> TestStoreOf<Settings> {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        var state = Settings.State()
        state.$selectedWalletAccount.withLock { $0 = account }
        state.$walletAccounts.withLock { $0 = [account] }
        state.path.append(.advancedSettings(AdvancedSettings.State()))
        let store = TestStore(initialState: state) { Settings() } withDependencies: {
            $0.uuid = .incrementing
            $0.zcashSDKEnvironment.network = { ZcashNetworkBuilder.network(for: network.value) }
            if let authenticate { $0.localAuthentication.authenticate = authenticate }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)
        return store
    }

    private func tapExport(_ store: TestStoreOf<Settings>, id: StackElementID) async {
        await store.send(.path(.element(id: id, action: .advancedSettings(.operationAccessCheck(.exportViewingKey)))))
    }
}
