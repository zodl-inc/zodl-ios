//
//  ConnectHWWalletCoordFlowTests.swift
//  zodlTests
//
//  MOB-2020 UI round 2: the merged `ConnectHWWalletCoordFlow` roots at the vendor chooser
//  (`ChooseHWWallet`) instead of jumping straight into a single vendor's instructions, so Back
//  from either vendor's instructions screen pops to the chooser and the user can pick the other
//  vendor. Covers the coordinator-level navigation ChooseHWWalletTests.swift's own reducer-only
//  tests don't reach: choosing a vendor from the chooser, popping back to it, the shared
//  RestoreInfo -> device-ready unlock hop, and cancelFailureTapped's vendor-instructions target
//  (Features/CoordFlows/ConnectHWWalletCoordFlow*.swift).
//
//  ConnectHWWalletCoordFlow.State is not Equatable (it contains a non-Equatable StackState), so
//  these tests drive a plain Store and read state directly after sending actions -- the same
//  approach ConnectHWWalletCoordFlowKeystoneTests/ConnectHWWalletCoordFlowLedgerTests use.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite(.serialized) @MainActor struct ConnectHWWalletCoordFlowTests {

    // MARK: - Choosing a vendor from the chooser

    @Test func choosingKeystonePushesItsInstructions() async {
        let store = makeStore()

        store.send(.chooseHWWallet(.keystoneTapped))

        #expect(store.state.path.count == 1)
        if case .addKeystoneHWWallet = store.state.path.first {
            // expected
        } else {
            Issue.record("expected .addKeystoneHWWallet to be pushed")
        }
    }

    @Test func choosingLedgerPushesItsInstructions() async {
        let store = makeStore()

        store.send(.chooseHWWallet(.ledgerTapped))

        #expect(store.state.path.count == 1)
        if case .addLedgerHWWallet = store.state.path.first {
            // expected
        } else {
            Issue.record("expected .addLedgerHWWallet to be pushed")
        }
    }

    // MARK: - Popping back to the chooser

    @Test func poppingBackToTheChooserLetsTheOtherVendorBeChosen() async {
        let store = makeStore()

        store.send(.chooseHWWallet(.ledgerTapped))
        let ledgerInstructionsId = store.state.path.ids.first!

        store.send(.path(.popFrom(id: ledgerInstructionsId)))
        store.send(.chooseHWWallet(.keystoneTapped))

        #expect(store.state.path.count == 1)
        if case .addKeystoneHWWallet = store.state.path.first {
            // expected -- the path is exactly [.addKeystoneHWWallet]
        } else {
            Issue.record("expected the path to be exactly [.addKeystoneHWWallet]")
        }
    }

    // MARK: - Shared RestoreInfo -> device-ready unlock

    @Test func gotItUnlocksTheLedgerDeviceReadyScreen() async throws {
        let fixture = try Self.makePairingFixture()
        var deviceReadyState = AddLedgerHWWallet.State.initial
        deviceReadyState.pairing = fixture

        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.ledgerDeviceReady(deviceReadyState))
        initialState.path.append(.restoreInfo(RestoreInfo.State.initial))
        initialState.birthday = 2_000_000

        let uuid = AccountUUID(id: [UInt8](repeating: 0x02, count: 16))
        let store = makeStore(initialState: initialState) {
            $0.sdkSynchronizer = .mocked(
                importAccount: { _, _, _, _, _, _, _ in uuid },
                walletAccounts: { [] }
            )
        }
        let deviceReadyId = store.state.path.ids.first!
        let restoreInfoId = store.state.path.ids.last!

        store.send(.path(.element(id: restoreInfoId, action: .restoreInfo(.gotItTapped))))

        #expect(store.state.path[id: restoreInfoId, case: \.restoreInfo]?.isProcessing == true)
        #expect(store.state.path[id: deviceReadyId, case: \.ledgerDeviceReady]?.isImportingAccount == true)

        // The unlock's `.run` effect chains asynchronously (unlockTapped -> accountImported ->
        // accountImportSucceeded -> the coordinator's push); poll until the success screen lands
        // or we give up, proving the dispatch actually reached AddLedgerHWWallet's reducer.
        for _ in 0..<50 {
            if store.state.path.contains(where: { if case .ledgerConnected = $0 { true } else { false } }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.state.path.contains(where: { if case .ledgerConnected = $0 { true } else { false } }))
    }

    // MARK: - cancelFailureTapped

    @Test func cancelFailureTappedSendsBackToHomeToTheLedgerInstructions() async throws {
        let disconnected = LockIsolated(false)

        var initialState = ConnectHWWalletCoordFlow.State()
        initialState.path.append(.addLedgerHWWallet(AddLedgerHWWallet.State.initial))
        initialState.isFailureSheetPresented = true

        let store = makeStore(initialState: initialState) {
            $0.ledgerClient = .noOp
            $0.ledgerClient.disconnect = { disconnected.setValue(true) }
        }

        store.send(.cancelFailureTapped)

        #expect(store.state.isFailureSheetPresented == false)

        // `.backToHomeTapped` disconnects the Ledger inside AddLedgerHWWallet's own `.run` effect
        // -- poll for the spy rather than asserting synchronously.
        for _ in 0..<50 {
            if disconnected.value { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(disconnected.value)
    }

    // MARK: - Helpers

    private func makeStore(
        initialState: ConnectHWWalletCoordFlow.State = ConnectHWWalletCoordFlow.State(),
        withDependencies extra: (@Sendable (inout DependencyValues) -> Void)? = nil
    ) -> StoreOf<ConnectHWWalletCoordFlow> {
        Store(initialState: initialState) {
            ConnectHWWalletCoordFlow()
        } withDependencies: {
            $0.audioServices.systemSoundVibrate = { }
            $0.walletStorage = .noOp
            // LedgerClient has no test/preview value (Phase 0 only registered `liveValue`), so
            // every path that can reach the element's disconnect-on-exit calls needs an explicit
            // override or it trips "has no test implementation".
            $0.ledgerClient = .noOp
            extra?(&$0)
        }
    }

    /// `LedgerAccountBinding`'s device identity is `tpk0-` plus 64 lowercase hex digits, validated
    /// through the linked FFI -- same fixture shape as LedgerSessionTests/AddLedgerHWWalletTests/
    /// ConnectHWWalletCoordFlowLedgerTests.
    private static func makePairingFixture() throws -> LedgerPairing {
        LedgerPairing(
            ufvk: "utest1fixture",
            binding: LedgerAccountBinding(
                deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
                zip32AccountIndex: Zip32AccountIndex(0)
            ),
            appVersion: "3.9.3"
        )
    }
}
