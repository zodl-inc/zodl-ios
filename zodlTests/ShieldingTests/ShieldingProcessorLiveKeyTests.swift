//
//  ShieldingProcessorLiveKeyTests.swift
//  zodlTests
//

import Foundation
import Testing
import ComposableArchitecture
@preconcurrency import Combine
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Serialized: mutates the process-global `selectedWalletAccount` @Shared state.
@Suite(.serialized) struct ShieldingProcessorLiveKeyTests {
    private static func account() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 9, count: 16)),
                name: "Zodl",
                keySource: nil,
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// A real Ledger account never has a ZIP 32 index, but this test deliberately gives it one
    /// (`Zip32AccountIndex(0)`, like `Self.account()`) to prove the hardware-wallet branch is
    /// chosen by `vendor.isHWWallet()`, not by whether an index happens to be present — a present,
    /// valid index must not accidentally route a Ledger account into the software lane's key
    /// derivation.
    private static func ledgerAccount() -> WalletAccount {
        WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: 10, count: 16)),
                name: "Ledger",
                keySource: "ledger",
                seedFingerprint: nil,
                hdAccountIndex: Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    /// A nil proposal must (a) surface as `.nothingToShield`, (b) reset the subject to `.unknown`
    /// so resubscribers do not replay the terminal state, and (c) never touch key material —
    /// deriving a spending key for a shield that cannot happen is pure waste.
    @Test func nothingToShieldResetsTheSubjectAndSkipsKeyDerivation() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount?
            $selectedWalletAccount.withLock { $0 = Self.account() }

            let states = LockIsolated<[ShieldingProcessorClient.State]>([])
            let didDeriveKey = LockIsolated(false)
            let (client, cancellable) = withDependencies {
                $0.derivationTool = .liveValue
                $0.derivationTool.deriveSpendingKey = { _, _, _ in
                    didDeriveKey.setValue(true)
                    throw "unexpected key derivation".toZcashError()
                }
                $0.mnemonic = .liveValue
                $0.walletStorage = .noOp
                $0.zcashSDKEnvironment = .testnet
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.proposeShielding = { _, _, _, _ in nil }
            } operation: {
                let client = ShieldingProcessorClient.live()
                let cancellable = client.observe().sink { state in
                    states.withValue { $0.append(state) }
                }
                client.shieldFunds()
                return (client, cancellable)
            }

            // Wait until the terminal outcome AND its reset have both landed.
            for _ in 0..<200 {
                let snapshot = states.withValue { $0 }
                if snapshot.contains(.nothingToShield) && snapshot.last == .unknown {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            cancellable.cancel()

            let snapshot = states.withValue { $0 }
            #expect(snapshot.contains(.requested))
            #expect(snapshot.contains(.nothingToShield))
            #expect(snapshot.last == .unknown, "terminal state must be followed by a reset, got \(snapshot)")
            #expect(!didDeriveKey.value, "no spending key may be derived when there is nothing to shield")

            // A fresh subscriber must replay only the reset, never the terminal outcome.
            let replayed = LockIsolated<[ShieldingProcessorClient.State]>([])
            let lateCancellable = client.observe().sink { state in
                replayed.withValue { $0.append(state) }
            }
            #expect(replayed.withValue { $0.first } == .unknown)
            lateCancellable.cancel()
        }
    }

    /// MOB-2020 Phase 3.3: a Ledger account now shields the same way Keystone does — the proposal
    /// is emitted for the signing popover to pick up, and the software lane (wallet export, key
    /// derivation) is never reached.
    @Test func shieldFundsForALedgerAccountEmitsTheProposalWithoutExportingTheWalletOrDerivingAKey() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount?
            $selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            let states = LockIsolated<[ShieldingProcessorClient.State]>([])
            let didDeriveKey = LockIsolated(false)
            let didExportWallet = LockIsolated(false)
            let proposal = Proposal.testOnlyFakeProposal(totalFee: 10_000)
            let (client, cancellable) = withDependencies {
                $0.derivationTool = .liveValue
                $0.derivationTool.deriveSpendingKey = { _, _, _ in
                    didDeriveKey.setValue(true)
                    throw "unexpected key derivation".toZcashError()
                }
                $0.mnemonic = .liveValue
                $0.walletStorage = .noOp
                $0.walletStorage.exportWallet = {
                    didExportWallet.setValue(true)
                    throw "unexpected wallet export".toZcashError()
                }
                $0.zcashSDKEnvironment = .testnet
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.proposeShielding = { _, _, _, _ in proposal }
            } operation: {
                let client = ShieldingProcessorClient.live()
                let cancellable = client.observe().sink { state in
                    states.withValue { $0.append(state) }
                }
                client.shieldFunds()
                return (client, cancellable)
            }

            func isProposal(_ state: ShieldingProcessorClient.State) -> Bool {
                if case .proposal = state { return true }
                return false
            }

            // Wait until the terminal outcome AND its reset have both landed.
            for _ in 0..<200 {
                let snapshot = states.withValue { $0 }
                if snapshot.contains(where: isProposal) && snapshot.last == .unknown {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            cancellable.cancel()

            let snapshot = states.withValue { $0 }
            #expect(snapshot.contains(.requested))
            #expect(snapshot.contains(where: isProposal), "expected a .proposal terminal state, got \(snapshot)")
            #expect(snapshot.last == .unknown, "terminal state must be followed by a reset, got \(snapshot)")
            #expect(!didExportWallet.value, "no wallet export may happen for a Ledger account")
            #expect(!didDeriveKey.value, "no spending key may be derived for a Ledger account")
        }
    }

    /// MOB-2020 Phase 3.3: a nil proposal for a Ledger account reports `.nothingToShield` exactly
    /// like it would for any other vendor — the hardware-wallet branch shares the same nil-proposal
    /// handling as the software lane, it just never risks key material to get there.
    @Test func shieldFundsForALedgerAccountWithNothingToShieldReportsNothingToShield() async throws {
        try await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount?
            $selectedWalletAccount.withLock { $0 = Self.ledgerAccount() }

            let states = LockIsolated<[ShieldingProcessorClient.State]>([])
            let (client, cancellable) = withDependencies {
                $0.derivationTool = .liveValue
                $0.mnemonic = .liveValue
                $0.walletStorage = .noOp
                $0.zcashSDKEnvironment = .testnet
                $0.sdkSynchronizer = .noOp
                $0.sdkSynchronizer.proposeShielding = { _, _, _, _ in nil }
            } operation: {
                let client = ShieldingProcessorClient.live()
                let cancellable = client.observe().sink { state in
                    states.withValue { $0.append(state) }
                }
                client.shieldFunds()
                return (client, cancellable)
            }

            // Wait until the terminal outcome AND its reset have both landed.
            for _ in 0..<200 {
                let snapshot = states.withValue { $0 }
                if snapshot.contains(.nothingToShield) && snapshot.last == .unknown {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            cancellable.cancel()

            let snapshot = states.withValue { $0 }
            #expect(snapshot.contains(.requested))
            #expect(snapshot.contains(.nothingToShield))
            #expect(snapshot.last == .unknown, "terminal state must be followed by a reset, got \(snapshot)")
        }
    }
}
