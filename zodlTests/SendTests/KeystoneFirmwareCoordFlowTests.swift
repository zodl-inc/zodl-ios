//
//  KeystoneFirmwareCoordFlowTests.swift
//  zodlTests
//
//  MOB-1510 — coordinator-level regressions in the Keystone minimum-firmware gate, found by code
//  review. `KeystoneFirmwareTests.swift` only drives the `SendConfirmation` store in isolation;
//  the push (`.keystoneFirmwareUpdateRequired`) and close (`.keystoneFirmwareUpdateCloseTapped`)
//  handling actually lives in four coordinators (SendCoordFlow, ScanCoordFlow, SwapAndPayCoordFlow,
//  SignWithKeystoneCoordFlow), which is what these tests exercise.
//
//  CoordFlow `State` is not `Equatable`, so these tests drive a plain `Store` (not `TestStore`) and
//  poll for the expected outcome with a private `waitFor…` helper (same approach as
//  `ScanCoordFlowZip321Tests`). Each test binds a fresh in-memory store via
//  `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage() }` so parallel suites cannot
//  clobber process-global `@Shared` state.
//
//  The close-action fix intentionally has the coordinator pop the `.keystoneFirmwareUpdate` path
//  element as part of the very reduce cycle that handles the action addressed to it. TCA's own
//  `.forEach` machinery independently (and redundantly) rechecks that same id afterward, finds it
//  already gone, and reports a "missing element" runtime issue — a harmless, unavoidable artifact
//  of that ordering (it fires even against the pre-fix code) and not something these tests are
//  checking, so it's silenced locally via `withIssueReporters([])` around just the `send` call.

import Foundation
import Testing
import ComposableArchitecture
import XCTestDynamicOverlay
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct KeystoneFirmwareCoordFlowTests {
    private var testWalletAccount: WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0, count: 16)),
                name: "Test",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// `stamp` is in the wire's numbering — a device displaying 3.0.1 stamps `[13, 0, 1]`.
    private func signedPczt(stamp: (major: Int, minor: Int, build: Int)) -> Pczt {
        var data = Data()
        data.append(contentsOf: Array("keystone:fw_version".utf8))
        data.append(contentsOf: [0x03, UInt8(stamp.major), UInt8(stamp.minor), UInt8(stamp.build)])
        return Pczt(data)
    }

    // MARK: - Push: `.keystoneFirmwareUpdateRequired`

    /// Review bug: the push handler loops the whole path with no `break`, appending one
    /// `.keystoneFirmwareUpdate` screen per `.confirmWithKeystone` element it finds.
    @Test func pushesExactlyOneUpdateScreenWhenTwoConfirmElementsOnPath() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SendCoordFlow.State()
            initialState.path.append(.confirmWithKeystone(SendConfirmation.State.initial))
            initialState.path.append(.confirmWithKeystone(SendConfirmation.State.initial))
            // The fix's loop always operates on the first (bottommost) `.confirmWithKeystone` it
            // finds, regardless of which id the action is addressed to — so address it there too.
            let triggerId = try #require(initialState.path.ids.first)

            let store = Store(initialState: initialState) {
                SendCoordFlow()
            }

            store.send(.path(.element(id: triggerId, action: .confirmWithKeystone(.keystoneFirmwareUpdateRequired))))

            await waitForCoordFlowStore {
                !store.state.path.filter { $0.is(\.keystoneFirmwareUpdate) }.isEmpty
            }

            #expect(store.state.path.filter { $0.is(\.keystoneFirmwareUpdate) }.count == 1)
        }
    }

    /// Review bug: the push handler appends `.keystoneFirmwareUpdate` on top of the path without
    /// popping the stale `.scan`/`.sending` elements pushed underneath it first.
    @Test func pushDropsStaleScanAndSendingElements() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SendCoordFlow.State()
            initialState.path.append(.confirmWithKeystone(SendConfirmation.State.initial))
            initialState.path.append(.scan(Scan.State.initial))
            initialState.path.append(.sending(SendConfirmation.State.initial))
            let confirmId = try #require(initialState.path.ids.first)

            let store = Store(initialState: initialState) {
                SendCoordFlow()
            }

            store.send(.path(.element(id: confirmId, action: .confirmWithKeystone(.keystoneFirmwareUpdateRequired))))

            await waitForCoordFlowStore {
                !store.state.path.filter { $0.is(\.keystoneFirmwareUpdate) }.isEmpty
            }

            #expect(store.state.path.count == 2)
            #expect(store.state.path.first?.is(\.confirmWithKeystone) == true)
            #expect(store.state.path.last?.is(\.keystoneFirmwareUpdate) == true)
        }
    }

    /// The `SignWithKeystone` variant of the same bug. That flow's `.scan(.foundPCZT)` also pushes
    /// `.sending` before the gate runs, and the confirm screen is the flow root rather than a path
    /// element — so the update screen must replace the whole path, not stack on top of it.
    @Test func pushDropsStaleScanAndSendingElementsInSignWithKeystoneFlow() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SignWithKeystoneCoordFlow.State()
            let rootState = initialState.sendConfirmationState
            initialState.path.append(.scan(Scan.State.initial))
            initialState.path.append(.sending(rootState))

            let store = Store(initialState: initialState) {
                SignWithKeystoneCoordFlow()
            }

            store.send(.sendConfirmation(.keystoneFirmwareUpdateRequired))

            await waitForCoordFlowStore {
                !store.state.path.filter { $0.is(\.keystoneFirmwareUpdate) }.isEmpty
            }

            #expect(store.state.path.count == 1)
            #expect(store.state.path.last?.is(\.keystoneFirmwareUpdate) == true)
        }
    }

    // MARK: - Close: `.keystoneFirmwareUpdateCloseTapped`

    /// Review bug: the coordinator pops the `.keystoneFirmwareUpdate` path element before the child
    /// `SendConfirmation` reducer ever sees the close action, so its reset of
    /// `isKeystoneCodeFound`/`detectedKeystoneFirmware` never runs — and even if it did, it would
    /// reset the wrong (discarded) state, not the surviving `confirmWithKeystone` element.
    @Test func closeResetsTheSurvivingConfirmElement() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var confirmState = SendConfirmation.State.initial
            confirmState.isKeystoneCodeFound = true
            confirmState.detectedKeystoneFirmware = KeystoneDisplayFirmwareVersion(displayMajor: 2, minor: 4, build: 6)

            var initialState = SendCoordFlow.State()
            initialState.path.append(.confirmWithKeystone(confirmState))
            initialState.path.append(.keystoneFirmwareUpdate(confirmState))
            let updateId = try #require(initialState.path.ids.last)

            let store = Store(initialState: initialState) {
                SendCoordFlow()
            } withDependencies: {
                $0.keystoneHandler.resetQRDecoder = { }
            }

            withIssueReporters([]) {
                store.send(.path(.element(id: updateId, action: .keystoneFirmwareUpdate(.keystoneFirmwareUpdateCloseTapped))))
            }

            await waitForCoordFlowStore {
                store.state.path.count == 1
            }

            if case .confirmWithKeystone(let survivor) = store.state.path.last {
                #expect(survivor.isKeystoneCodeFound == false)
                #expect(survivor.detectedKeystoneFirmware == nil)
            } else {
                Issue.record("Expected the surviving path element to be confirmWithKeystone")
            }
        }
    }

    /// Same bug as `closeResetsTheSurvivingConfirmElement`, but for the one coordinator
    /// (`SignWithKeystoneCoordFlow`) where the confirm screen is the flow's root state rather than a
    /// path element.
    @Test func closeResetsRootStateInSignWithKeystoneFlow() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SignWithKeystoneCoordFlow.State()
            initialState.sendConfirmationState.isKeystoneCodeFound = true
            initialState.sendConfirmationState.detectedKeystoneFirmware = KeystoneDisplayFirmwareVersion(displayMajor: 2, minor: 4, build: 6)
            initialState.path.append(.keystoneFirmwareUpdate(initialState.sendConfirmationState))
            let updateId = try #require(initialState.path.ids.last)

            let store = Store(initialState: initialState) {
                SignWithKeystoneCoordFlow()
            } withDependencies: {
                $0.keystoneHandler.resetQRDecoder = { }
            }

            withIssueReporters([]) {
                store.send(.path(.element(id: updateId, action: .keystoneFirmwareUpdate(.keystoneFirmwareUpdateCloseTapped))))
            }

            await waitForCoordFlowStore {
                store.state.path.isEmpty
            }

            #expect(store.state.path.isEmpty)
            #expect(store.state.sendConfirmationState.isKeystoneCodeFound == false)
            #expect(store.state.sendConfirmationState.detectedKeystoneFirmware == nil)
        }
    }

    /// The other symptom of the same bug: because the child reducer's close handler never runs (see
    /// `closeResetsTheSurvivingConfirmElement`), `keystoneHandler.resetQRDecoder()` never fires
    /// either.
    @Test func closeResetsTheQRDecoder() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var confirmState = SendConfirmation.State.initial
            confirmState.isKeystoneCodeFound = true
            confirmState.detectedKeystoneFirmware = KeystoneDisplayFirmwareVersion(displayMajor: 2, minor: 4, build: 6)

            var initialState = SendCoordFlow.State()
            initialState.path.append(.confirmWithKeystone(confirmState))
            initialState.path.append(.keystoneFirmwareUpdate(confirmState))
            let updateId = try #require(initialState.path.ids.last)

            let resetCalls = LockIsolated(0)
            let store = Store(initialState: initialState) {
                SendCoordFlow()
            } withDependencies: {
                $0.keystoneHandler.resetQRDecoder = { resetCalls.withValue { $0 += 1 } }
            }

            withIssueReporters([]) {
                store.send(.path(.element(id: updateId, action: .keystoneFirmwareUpdate(.keystoneFirmwareUpdateCloseTapped))))
            }

            // Short timeout: pre-fix this condition never becomes true, and the usual 60s default
            // would otherwise make this specific RED run needlessly slow.
            await waitForCoordFlowStore(timeoutNanoseconds: 3_000_000_000) {
                resetCalls.value == 1
            }

            #expect(resetCalls.value == 1)
        }
    }

    // MARK: - Swap metadata deferral

    /// Review bug: `SwapAndPayCoordFlowCoordinator` writes the swap metadata (and stores the
    /// account) from `.scan(.foundPCZT)`, strictly before forwarding into `confirmWithKeystone`
    /// where the firmware gate is actually evaluated — so the write happens even when the gate is
    /// about to block the signature. `UserMetadataProviderInterface` has no unmark/remove API, so
    /// this would leave a permanent phantom swap record for a transaction that never happens.
    @Test func blockedSwapWritesNoSwapMetadata() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let markCalls = LockIsolated(0)
            let store = try makeSwapAndPayStore(markCalls: markCalls)

            store.send(.path(.element(id: try #require(store.state.path.ids.last), action: .scan(.foundPCZT(signedPczt(stamp: (12, 4, 6)))))))

            await waitForCoordFlowStore {
                !store.state.path.filter { $0.is(\.keystoneFirmwareUpdate) }.isEmpty
            }

            #expect(markCalls.value == 0)
        }
    }

    /// Regression guard: firmware exactly at the minimum must still record swap metadata once the
    /// gate accepts it — proves the fix defers the write rather than dropping it.
    @Test func acceptedSwapWritesSwapMetadata() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let markCalls = LockIsolated(0)
            let store = try makeSwapAndPayStore(markCalls: markCalls)

            store.send(.path(.element(id: try #require(store.state.path.ids.last), action: .scan(.foundPCZT(signedPczt(stamp: (13, 0, 1)))))))

            await waitForCoordFlowStore {
                markCalls.value == 1
            }

            #expect(markCalls.value == 1)
        }
    }

    private func makeSwapAndPayStore(markCalls: LockIsolated<Int>) -> StoreOf<SwapAndPayCoordFlow> {
        var initialState = SwapAndPayCoordFlow.State()
        initialState.swapAndPayState.address = "utestdepositaddress"
        initialState.swapAndPayState.selectedAsset = SwapAsset(
            provider: "near",
            chain: "eth",
            token: "ETH",
            assetId: "eth-id",
            usdPrice: 1,
            decimals: 18
        )
        initialState.$selectedWalletAccount.withLock { $0 = testWalletAccount }

        var confirmState = SendConfirmation.State.initial
        confirmState.proposal = .testOnlyFakeProposal(totalFee: 10_000)
        initialState.path.append(.confirmWithKeystone(confirmState))
        initialState.path.append(.scan(Scan.State.initial))

        return Store(initialState: initialState) {
            SwapAndPayCoordFlow()
        } withDependencies: {
            $0.mainQueue = .immediate
            $0.userMetadataProvider.markTransactionAsSwapFor = { _, _, _, _, _, _, _, _, _ in
                markCalls.withValue { $0 += 1 }
            }
            $0.userMetadataProvider.store = { _ in }
        }
    }
}

@MainActor
private func waitForCoordFlowStore(
    timeoutNanoseconds: UInt64 = 60_000_000_000,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @escaping @MainActor () -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition(), DispatchTime.now().uptimeNanoseconds < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(condition(), "Timed out waiting for CoordFlow store state", sourceLocation: sourceLocation)
}
