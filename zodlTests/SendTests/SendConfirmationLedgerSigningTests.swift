//
//  SendConfirmationLedgerSigningTests.swift
//  zodlTests
//
//  MOB-2020 Phase 3.2: covers `SendConfirmation`'s Ledger-specific arms -- `pcztResolved`
//  branching on vendor, `ledgerSignRequest` reading the stored binding, and how the embedded
//  `LedgerSigning` child reducer's `signed`/`signingFailed` route back into the shared PCZT
//  machine (Features/SendConfirmation/SendConfirmationStore.swift). Mirrors
//  `SendConfirmationLedgerGuardTests.swift`'s isolation idiom: `SendConfirmation.State` carries
//  `@Shared(.inMemory(...))` process-global storage, so every test binds a fresh in-memory store
//  via `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage() }`.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct SendConfirmationLedgerSigningTests {
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

    /// A validated `LedgerDeviceIdentity`: `tpk0-` plus 64 lowercase hex digits, the same
    /// well-formed, non-secret placeholder `WalletStorageLedgerBindingTests.swift` uses.
    private static func ledgerAccountBinding() throws -> LedgerAccountBinding {
        LedgerAccountBinding(
            deviceIdentity: try LedgerDeviceIdentity(encoding: "tpk0-" + String(repeating: "a", count: 64)),
            zip32AccountIndex: Zip32AccountIndex(0)
        )
    }

    private func makeState(account: WalletAccount) -> SendConfirmation.State {
        var state = SendConfirmation.State.initial
        state.$selectedWalletAccount.withLock { $0 = account }
        return state
    }

    @Test func pcztResolvedForALedgerAccountProvesAndRequestsTheSignature() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let pczt = Pczt([0x01])
            let pcztWithProofs = Pczt([0x02])
            let binding = try Self.ledgerAccountBinding()
            let account = Self.ledgerAccount()

            let store = TestStore(initialState: makeState(account: account)) {
                SendConfirmation()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.walletStorage = .noOp
                $0.walletStorage.exportLedgerBinding = { _ in binding }
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.addProofsToPCZT = { _ in pcztWithProofs }
            }
            store.exhaustivity = .off

            await store.send(.pcztResolved(pczt))
            await store.finish()
            await store.skipReceivedActions(strict: false)

            // Both effects ran: the proofs branch (Keystone shares this one) ...
            #expect(store.state.pczt == pczt)
            #expect(store.state.pcztWithProofs == pcztWithProofs)
            // ... and the Ledger-only branch, with no QR redaction step.
            #expect(store.state.redactedPcztForSigner == nil)
            // The binding `exportLedgerBinding` returned reached the child reducer's request.
            #expect(
                store.state.ledgerSigning.request
                == LedgerSigning.State.SignRequest(pczt: pczt, accountUUID: account.id, binding: binding)
            )
        }
    }

    @Test func pcztResolvedForAKeystoneAccountStillRedacts() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let pczt = Pczt([0x01])
            let redactedPczt = Pczt([0x02])
            let pcztWithProofs = Pczt([0x03])

            let store = TestStore(initialState: makeState(account: Self.keystoneAccount())) {
                SendConfirmation()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.redactPCZTForSigner = { _ in redactedPczt }
                $0.sdkSynchronizer.addProofsToPCZT = { _ in pcztWithProofs }
            }
            store.exhaustivity = .off

            await store.send(.pcztResolved(pczt))
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.redactedPcztForSigner == redactedPczt)
            #expect(store.state.pcztForUI == redactedPczt)
            #expect(store.state.pcztWithProofs == pcztWithProofs)
            // Nothing routed into the Ledger sub-machine for a Keystone account.
            #expect(store.state.ledgerSigning.request == nil)
        }
    }

    @Test func aMissingBindingFailsBeforeSigning() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            struct BindingMissing: Error {}
            let pczt = Pczt([0x01])

            var initialState = makeState(account: Self.ledgerAccount())
            initialState.pczt = pczt

            let store = TestStore(initialState: initialState) {
                SendConfirmation()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.walletStorage = .noOp
                $0.walletStorage.exportLedgerBinding = { _ in throw BindingMissing() }
            }

            await store.send(.ledgerSignRequest)
            await store.receive(\.updateFailedData) {
                $0.failedCode = -795
                $0.failedDescription = "ledgerSignRequest failed: no binding"
                // `updateFailedData`'s third argument (`""`) lands here under `#if DEBUG`.
                $0.failedPcztMsg = ""
            }
            // `isSending` is already `false` (the initial default) -- `pcztSendFailed` sets it
            // to the same value, so this receive has no observable state change of its own.
            await store.receive(\.pcztSendFailed)
            await store.finish()

            #expect(store.state.ledgerSigning.request == nil)
        }
    }

    @Test func aLedgerSignedPcztSkipsTheFirmwareGateAndCreatesTheTransactionOnceProofsExist() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let pcztWithProofs = Pczt([0x02])
            let pcztWithSigs = Pczt([0xAB])
            let txId = Data([0xAA]).toHexStringTxId()

            var initialState = makeState(account: Self.ledgerAccount())
            initialState.pcztWithProofs = pcztWithProofs

            let store = TestStore(initialState: initialState) {
                SendConfirmation()
            } withDependencies: {
                $0.audioServices = AudioServicesClient(systemSoundVibrate: { })
                $0.mainQueue = .immediate
                $0.zcashSDKEnvironment = .testnet
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.createAndSubmitTransactionFromPCZT = { proofs, sigs in
                    #expect(proofs == pcztWithProofs)
                    #expect(sigs == pcztWithSigs)
                    return .success(txIds: [txId])
                }
            }
            store.exhaustivity = .off

            // No `keystoneFirmwareUpdateRequired`/`keystoneFirmwareAccepted` in this path at
            // all -- a Ledger-signed PCZT carries no Keystone stamp to gate on.
            await store.send(.ledgerSigning(.signed(pcztWithSigs)))
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.detectedKeystoneFirmware == nil)
            #expect(store.state.isKeystoneCodeFound == false)
            #expect(store.state.result == .success)
            #expect(store.state.txIdToExpand == txId)
        }
    }

    @Test func aNonRestartableSigningFailureRoutesToPcztSendFailed() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = TestStore(initialState: makeState(account: Self.ledgerAccount())) {
                SendConfirmation()
            } withDependencies: {
                $0.mainQueue = .immediate
            }
            store.exhaustivity = .off

            // The `Scope`'d `LedgerSigning` child reducer sees this action too (it runs before
            // the parent's own `Reduce`), so the send itself already moves the sub-machine to
            // `.failed` -- independently of the parent's `updateFailedData`/`pcztSendFailed`
            // cascade asserted below via final state (mirrors `MultiServerSubmitPCZTRoutingTests`'
            // `.off` + final-assertions idiom used elsewhere in this file).
            await store.send(
                .ledgerSigning(
                    .signingFailed(
                        message: String(localizable: .ledgerErrorNotSignable),
                        restartable: false,
                        connectionLost: false
                    )
                )
            )
            await store.finish()
            await store.skipReceivedActions(strict: false)

            #expect(store.state.ledgerSigning.phase == .failed)
            #expect(store.state.failedCode == -794)
            #expect(store.state.failedDescription == String(localizable: .ledgerErrorNotSignable))
            #expect(store.state.isSending == false)
        }
    }

    @Test func rejectResetsTheLedgerSigningState() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let account = Self.ledgerAccount()
            var initialState = makeState(account: account)
            initialState.pczt = Pczt([0x01])
            initialState.rejectSendRequest = true
            initialState.ledgerSigning.phase = .signing(.awaitingReviewOnDevice)
            initialState.ledgerSigning.devices = [
                LedgerBluetoothDevice(id: UUID(), name: "Nano X", model: .nanoX, rssi: -40)
            ]
            initialState.ledgerSigning.request = LedgerSigning.State.SignRequest(
                pczt: Pczt([0x01]),
                accountUUID: account.id,
                binding: try Self.ledgerAccountBinding()
            )

            let store = TestStore(initialState: initialState) {
                SendConfirmation()
            } withDependencies: {
                $0.mainQueue = .immediate
            }

            await store.send(.rejectTapped) {
                $0.rejectSendRequest = false
            }
            await store.receive(\.resetPCZTs) {
                $0.pczt = nil
                $0.ledgerSigning = LedgerSigning.State()
            }
            await store.finish()
        }
    }
}
