//
//  ViewingKeyExportFixtures.swift
//  zodlTests
//

import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

enum ViewingKeyExportFixtures {
    private static let cache = ViewingKeyAccountCache()

    static func account(
        vendor: WalletAccount.Vendor,
        network: NetworkType = .mainnet
    ) async throws -> WalletAccount {
        let sdkAccount = try await cache.account(network: network)
        let account = Account(
            id: sdkAccount.id,
            name: vendor == .keystone ? "Keystone fixture" : "Zodl fixture",
            keySource: vendor == .keystone ? Account.keystoneKeySource : nil,
            seedFingerprint: sdkAccount.seedFingerprint,
            hdAccountIndex: sdkAccount.hdAccountIndex,
            ufvk: sdkAccount.ufvk,
            uivk: sdkAccount.uivk
        )
        return WalletAccount(account)
    }

    static func accountWithoutViewingKeys(
        vendor: WalletAccount.Vendor,
        network: NetworkType = .mainnet
    ) async throws -> WalletAccount {
        let sdkAccount = try await cache.account(network: network)
        let account = Account(
            id: sdkAccount.id,
            name: vendor == .keystone ? "Keystone fixture" : "Zodl fixture",
            keySource: vendor == .keystone ? Account.keystoneKeySource : nil,
            seedFingerprint: sdkAccount.seedFingerprint,
            hdAccountIndex: sdkAccount.hdAccountIndex,
            ufvk: nil,
            uivk: nil
        )
        return WalletAccount(account)
    }

    static func replacingID(in walletAccount: WalletAccount, byte: UInt8) -> WalletAccount {
        let source = walletAccount.account
        return WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: byte, count: 16)),
                name: source.name,
                keySource: source.keySource,
                seedFingerprint: source.seedFingerprint,
                hdAccountIndex: source.hdAccountIndex,
                ufvk: source.ufvk,
                uivk: source.uivk
            )
        )
    }
}

private actor ViewingKeyAccountCache {
    enum FixtureError: Error {
        case accountMissing
        case databaseInitializationFailed
    }

    private var accounts: [NetworkType: TypedAccountPair] = [:]

    func account(network: NetworkType) async throws -> TypedAccountPair {
        if let account = accounts[network] {
            return account
        }

        let account = try await generateAccount(network: network)
        accounts[network] = account
        return account
    }

    @DBActor
    private func generateAccount(network: NetworkType) async throws -> TypedAccountPair {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MOB-1877-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fsBlockDbRoot = rootURL.appendingPathComponent("fs-blocks", isDirectory: true)
        try FileManager.default.createDirectory(at: fsBlockDbRoot, withIntermediateDirectories: true)

        let params = SaplingParamsSourceURL.default
        let backend = ZcashRustBackend(
            dbData: rootURL.appendingPathComponent("wallet.sqlite"),
            fsBlockDbRoot: fsBlockDbRoot,
            spendParamsPath: params.spendParamFileURL,
            outputParamsPath: params.outputParamFileURL,
            networkType: network,
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )
        let initialization = try await backend.initDataDb(seed: nil)
        guard case .success = initialization else {
            throw FixtureError.databaseInitializationFailed
        }

        // Public ZIP-0325 vector seed from zcash-hackworks/zcash-test-vectors, also used by
        // ZcashLightClientKit's Zip325Tests. It is test material and carries no real funds.
        let seed = Array(UInt8(0x00)...UInt8(0x1f))
        let accountIndex = Zip32AccountIndex(0)
        let derivationTool = DerivationTool(networkType: network)
        let spendingKey = try derivationTool.deriveUnifiedSpendingKey(seed: seed, accountIndex: accountIndex)
        let fullViewingKey = try derivationTool.deriveUnifiedFullViewingKey(from: spendingKey)
        let treeState = CheckpointSourceFactory.fromBundle(for: network).latestKnownCheckpoint().treeState()

        _ = try await backend.importAccount(
            ufvk: fullViewingKey.stringEncoded,
            seedFingerprint: [UInt8](repeating: 0xa5, count: 32),
            zip32AccountIndex: accountIndex,
            treeState: treeState,
            recoverUntil: nil,
            purpose: .spending,
            name: "Viewing key fixture",
            keySource: nil
        )

        guard let account = try await backend.listAccounts().first else {
            throw FixtureError.accountMissing
        }
        return TypedAccountPair(account: account)
    }
}

/// The SDK key wrappers and account identifiers are immutable value types but predate Swift's
/// Sendable annotations. This test-only container carries that immutable typed pair across the
/// cache actor boundary without weakening any mutable reference state.
private struct TypedAccountPair: @unchecked Sendable {
    let id: AccountUUID
    let name: String?
    let keySource: String?
    let seedFingerprint: [UInt8]?
    let hdAccountIndex: Zip32AccountIndex?
    let ufvk: UnifiedFullViewingKey?
    let uivk: UnifiedIncomingViewingKey?

    init(account: Account) {
        self.id = account.id
        self.name = account.name
        self.keySource = account.keySource
        self.seedFingerprint = account.seedFingerprint
        self.hdAccountIndex = account.hdAccountIndex
        self.ufvk = account.ufvk
        self.uivk = account.uivk
    }
}
