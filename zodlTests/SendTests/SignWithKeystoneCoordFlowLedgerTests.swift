//
//  SignWithKeystoneCoordFlowLedgerTests.swift
//  zodlTests
//
//  MOB-2020 Phase 3.3: coordinator-level Ledger coverage for `SignWithKeystoneCoordFlow` — the
//  flow the Balances-sheet shielding offer drives (Features/CoordFlows/SignWithKeystoneCoordFlowStore.swift).
//  Unlike SendCoordFlow/ScanCoordFlow/SwapAndPayCoordFlow, this coordinator has no
//  `.confirmWithLedger`/`.confirmWithKeystone` path element — the confirm screen is the flow's
//  root `sendConfirmationState` for every vendor, so routing is keyed on
//  `.sendConfirmation(...)` directly rather than a wrapped `.path(.element(...))` action.
//  Mirrors `SendCoordFlowLedgerRoutingTests.swift`'s and `KeystoneFirmwareCoordFlowTests.swift`'s
//  pattern: CoordFlow `State` is not `Equatable`, so these tests drive a plain `Store` and poll
//  for the expected outcome, each isolated via `withDependencies { $0.defaultInMemoryStorage =
//  InMemoryStorage() }` since `SendConfirmation.State.selectedWalletAccount` is process-global
//  `@Shared` storage.
//

import Foundation
import Testing
import ComposableArchitecture
@testable @preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SignWithKeystoneCoordFlowLedgerTests {
    private static func ledgerAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0x0E, count: 16)),
                name: "Ledger",
                keySource: "ledger",
                seedFingerprint: nil,
                hdAccountIndex: nil,
                ufvk: nil,
                uivk: nil
            )
        )
    }

    private static func keystoneAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 0x0F, count: 16)),
                name: "Keystone",
                keySource: "keystone",
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// The Ledger counterpart of this coordinator's existing `.scan(.foundPCZT)` handling: once
    /// the embedded `LedgerSigning` sub-machine reports `.signed`, the root confirmation state
    /// (already carrying the signed PCZT) is pushed onto `.sending` with no action forwarded any
    /// further — the child `SendConfirmation` reducer's own `.ledgerSigning(.signed)` arm already
    /// started the submit.
    @Test func aLedgerSignedPcztPushesSending() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = Store(initialState: SignWithKeystoneCoordFlow.State()) {
                SignWithKeystoneCoordFlow()
            }

            store.send(.sendConfirmation(.ledgerSigning(.signed(Pczt([0xAB])))))

            await waitForCoordFlowStore {
                store.state.path.count == 1
            }

            #expect(store.state.path.count == 1)
            #expect(store.state.path.last?.is(\.sending) == true)
        }
    }

    /// A successful shield resets the reminder keyed by the ACTING account's own vendor name, not
    /// a hard-coded Keystone constant — a Ledger account must reset its own "ledger" reminder.
    @Test func aSuccessfulLedgerShieldResetsTheLedgerReminder() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SignWithKeystoneCoordFlow.State()
            initialState.sendConfirmationState.isShielding = true
            initialState.sendConfirmationState.$selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            let resetVendorName = LockIsolated<String?>(nil)
            let store = Store(initialState: initialState) {
                SignWithKeystoneCoordFlow()
            } withDependencies: {
                $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
                $0.walletStorage = .noOp
                $0.walletStorage.resetShieldingReminder = { vendorName in
                    resetVendorName.setValue(vendorName)
                }
            }

            store.send(.sendConfirmation(.updateResult(.success)))

            await waitForCoordFlowStore {
                resetVendorName.value != nil
            }

            #expect(resetVendorName.value == WalletAccount.Vendor.ledger.name())
            #expect(store.state.path.last?.is(\.sendResultSuccess) == true)
        }
    }

    /// Regression guard for the guarded fallback added alongside the Ledger case: a Keystone
    /// shield must keep resetting the Keystone reminder exactly as it did before this slice.
    @Test func aSuccessfulKeystoneShieldStillResetsTheKeystoneReminder() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            var initialState = SignWithKeystoneCoordFlow.State()
            initialState.sendConfirmationState.isShielding = true
            initialState.sendConfirmationState.$selectedWalletAccount.withLock { $0 = Self.keystoneAccount() }

            let resetVendorName = LockIsolated<String?>(nil)
            let store = Store(initialState: initialState) {
                SignWithKeystoneCoordFlow()
            } withDependencies: {
                $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
                $0.walletStorage = .noOp
                $0.walletStorage.resetShieldingReminder = { vendorName in
                    resetVendorName.setValue(vendorName)
                }
            }

            store.send(.sendConfirmation(.updateResult(.success)))

            await waitForCoordFlowStore {
                resetVendorName.value != nil
            }

            #expect(resetVendorName.value == WalletAccount.Vendor.keystone.name())
            #expect(store.state.path.last?.is(\.sendResultSuccess) == true)
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
