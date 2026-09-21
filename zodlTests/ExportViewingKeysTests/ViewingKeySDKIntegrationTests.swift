//
//  ViewingKeySDKIntegrationTests.swift
//  zodlTests
//

import CoreImage
import Foundation
import Testing
import UIKit
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized)
@MainActor
struct ViewingKeySDKIntegrationTests {
    @Test
    func softwareCreationAndKeystoneImportExposeCanonicalKeysToExportAndShare() async throws {
        let fixture = try await makeSDKFixture()

        #expect(fixture.software.ufvk != nil)
        #expect(fixture.software.uivk != nil)
        #expect(fixture.software.seedFingerprint != nil)
        #expect(fixture.software.hdAccountIndex == Zip32AccountIndex(0))
        #expect(fixture.keystone.ufvk != nil)
        #expect(fixture.keystone.uivk != nil)
        #expect(fixture.keystone.seedFingerprint != nil)
        #expect(fixture.keystone.hdAccountIndex == Zip32AccountIndex(0))
        #expect(fixture.keystone.keySource == Account.keystoneKeySource)

        let importedUFVKMatches = fixture.keystone.ufvk?.stringEncoded == fixture.software.ufvk?.stringEncoded
        #expect(importedUFVKMatches)

        let keystoneAccount = WalletAccount(fixture.keystone.account)
        let session = ViewingKeyExportSession(
            id: UUID(),
            account: keystoneAccount,
            network: .testnet
        )

        for kind in ViewingKeyKind.allCases {
            let key = try #require(session.key(for: kind))
            let png = try await ViewingKeyQRCodeClient.liveValue.png(key)
            let decoded = try #require(decodedQRCode(png.data))
            let decodedMatches = decoded == key.rawValue
            #expect(decodedMatches)

            let payload = ViewingKeySharePayload(id: UUID(), key: key, png: png)
            let items = ViewingKeyShareItems(payload: payload, title: "Public SDK fixture")
            let sharedString = try #require(items.activityItems.first as? String)
            let sharedPNG = try #require(items.activityItems.last as? ShareablePNG)
            let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)
            let sharedPNGData = try #require(
                sharedPNG.activityViewController(controller, itemForActivityType: nil) as? Data
            )
            let sharedStringMatches = sharedString == key.rawValue
            let sharedPNGMatches = sharedPNGData == png.data
            let sharedPNGDecodesExactly = decodedQRCode(sharedPNGData) == key.rawValue
            #expect(items.activityItems.count == 2)
            #expect(sharedStringMatches)
            #expect(sharedPNGMatches)
            #expect(sharedPNGDecodesExactly)

            let presentation = ViewingKeyPresentation.payload(
                isVisible: true,
                key: key,
                png: png
            )
            let expectedPresentation = ViewingKeyPayloadPresentation.revealed(
                key: key.rawValue,
                png: png.data
            )
            #expect(presentation == expectedPresentation)
        }
    }

    private func decodedQRCode(_ data: Data) -> String? {
        guard let image = UIImage(data: data)?.cgImage,
              let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: CIContext(),
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
              ) else {
            return nil
        }
        let features = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        return features.count == 1 ? features.first?.messageString : nil
    }
}

private struct SDKRuntimeFixture: @unchecked Sendable {
    let software: SDKRuntimeAccount
    let keystone: SDKRuntimeAccount
}

private struct SDKRuntimeAccount: @unchecked Sendable {
    let id: AccountUUID
    let name: String?
    let keySource: String?
    let seedFingerprint: [UInt8]?
    let hdAccountIndex: Zip32AccountIndex?
    let ufvk: UnifiedFullViewingKey?
    let uivk: UnifiedIncomingViewingKey?

    var account: Account {
        Account(
            id: id,
            name: name,
            keySource: keySource,
            seedFingerprint: seedFingerprint,
            hdAccountIndex: hdAccountIndex,
            ufvk: ufvk,
            uivk: uivk
        )
    }

    init(_ account: Account) {
        self.id = account.id
        self.name = account.name
        self.keySource = account.keySource
        self.seedFingerprint = account.seedFingerprint
        self.hdAccountIndex = account.hdAccountIndex
        self.ufvk = account.ufvk
        self.uivk = account.uivk
    }
}

@DBActor
private func makeSDKFixture() async throws -> SDKRuntimeFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MOB-1877-SDK-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let treeState = CheckpointSourceFactory.fromBundle(for: .testnet)
        .latestKnownCheckpoint()
        .treeState()
    let softwareBackend = try makeBackend(rootURL: rootURL.appendingPathComponent("software", isDirectory: true))
    let softwareInitialization = try await softwareBackend.initDataDb(seed: nil)
    guard case .success = softwareInitialization else {
        throw SDKRuntimeFixtureError.databaseInitializationFailed
    }
    _ = try await softwareBackend.createAccount(
        seed: [UInt8](repeating: 7, count: 32),
        treeState: treeState,
        recoverUntil: nil,
        name: "Public fixture",
        keySource: nil
    )
    let softwareAccount = try requireSingleAccount(try await softwareBackend.listAccounts())
    guard let publicUFVK = softwareAccount.ufvk,
          let publicFingerprint = softwareAccount.seedFingerprint else {
        throw SDKRuntimeFixtureError.viewingKeysMissing
    }

    let importBackend = try makeBackend(rootURL: rootURL.appendingPathComponent("keystone", isDirectory: true))
    let importInitialization = try await importBackend.initDataDb(seed: nil)
    guard case .success = importInitialization else {
        throw SDKRuntimeFixtureError.databaseInitializationFailed
    }
    _ = try await importBackend.importAccount(
        ufvk: publicUFVK.stringEncoded,
        seedFingerprint: publicFingerprint,
        zip32AccountIndex: Zip32AccountIndex(0),
        treeState: treeState,
        recoverUntil: nil,
        purpose: .spending,
        name: "Public Keystone fixture",
        keySource: Account.keystoneKeySource
    )
    let keystoneAccount = try requireSingleAccount(try await importBackend.listAccounts())

    return SDKRuntimeFixture(
        software: SDKRuntimeAccount(softwareAccount),
        keystone: SDKRuntimeAccount(keystoneAccount)
    )
}

@DBActor
private func makeBackend(rootURL: URL) throws -> ZcashRustBackend {
    let fsBlockDbRoot = rootURL.appendingPathComponent("fs-blocks", isDirectory: true)
    try FileManager.default.createDirectory(at: fsBlockDbRoot, withIntermediateDirectories: true)
    return ZcashRustBackend(
        dbData: rootURL.appendingPathComponent("wallet.sqlite"),
        fsBlockDbRoot: fsBlockDbRoot,
        spendParamsPath: rootURL.appendingPathComponent("sapling-spend.params"),
        outputParamsPath: rootURL.appendingPathComponent("sapling-output.params"),
        networkType: .testnet,
        logLevel: .off,
        sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
    )
}

private func requireSingleAccount(_ accounts: [Account]) throws -> Account {
    guard accounts.count == 1, let account = accounts.first else {
        throw SDKRuntimeFixtureError.accountMissing
    }
    return account
}

private enum SDKRuntimeFixtureError: Error {
    case accountMissing
    case databaseInitializationFailed
    case viewingKeysMissing
}
