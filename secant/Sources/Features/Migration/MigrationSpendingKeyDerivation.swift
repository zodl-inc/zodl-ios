//
//  MigrationSpendingKeyDerivation.swift
//  zodl
//
//  Shared USK-derivation helper for the migration flow's software-signing paths (MOB-1496):
//  `MigrationNoteSplitStore`, `MigrationTransferPlanStore`, `MigrationReviewTransferStore`, and
//  `MigrationSendingStore`'s dust sweep all need the selected account's `UnifiedSpendingKey` to
//  sign a migration operation locally. Mirrors the send flow's inline derivation pattern (e.g.
//  `ShieldingProcessorLiveKey.swift`'s `shieldFunds()`: seed export -> `mnemonic.toSeed` ->
//  `derivationTool.deriveSpendingKey`) — factored into one place instead of re-inlining it at each
//  migration call site. Keystone accounts never reach this: the coordinator's existing routing
//  sends them to the PCZT lane before any of these call sites would derive a USK.
//

import Foundation
@preconcurrency import ZcashLightClientKit

enum MigrationSpendingKeyDerivation {
    /// Derives a software account's `UnifiedSpendingKey` from the wallet's stored seed phrase.
    /// Callers must not invoke this for a Keystone-vendor account (it has no locally-held seed
    /// phrase of its own to derive from) — check `WalletAccount.vendor != .keystone` first.
    static func deriveUSK(
        zip32AccountIndex: Zip32AccountIndex,
        walletStorage: WalletStorageClient,
        mnemonic: MnemonicClient,
        derivationTool: DerivationToolClient,
        networkType: NetworkType
    ) async throws -> UnifiedSpendingKey {
        let storedWallet = try await walletStorage.exportWallet(nil)
        let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
        return try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, networkType)
    }
}
