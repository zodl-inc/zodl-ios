//
//  ViewingKeyExportModelTests.swift
//  zodlTests
//

import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

@Suite(.serialized)
struct ViewingKeyExportModelTests {
    @Test
    func incomingAndFullUseTheirTypedSDKKeys() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)

        let incomingMatches = session.key(for: .incoming)?.rawValue == account.account.uivk?.stringEncoded
        let fullMatches = session.key(for: .full)?.rawValue == account.account.ufvk?.stringEncoded

        #expect(incomingMatches)
        #expect(fullMatches)
    }

    @Test
    func matchingRequiresTheCapturedAccountAndNetwork() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let otherAccount = ViewingKeyExportFixtures.replacingID(in: account, byte: 0x7f)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)

        #expect(session.matches(account: account, network: .mainnet))
        #expect(!session.matches(account: nil, network: .mainnet))
        #expect(!session.matches(account: account, network: .testnet))
        #expect(!session.matches(account: otherAccount, network: .mainnet))
    }

    @Test
    func matchingRejectsAnotherVendorWithTheSameTypedKeys() async throws {
        let zodlAccount = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let keystoneAccount = try await ViewingKeyExportFixtures.account(vendor: .keystone)
        let session = ViewingKeyExportSession(id: UUID(), account: zodlAccount, network: .mainnet)

        #expect(!session.matches(account: keystoneAccount, network: .mainnet))
    }

    @Test
    func matchingIgnoresReceiveAddressStashChanges() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        var changedStash = account
        let fullViewingKey = try #require(account.account.ufvk)
        changedStash.nextPrivateUA = try DerivationTool(networkType: .mainnet)
            .deriveUnifiedAddressFrom(ufvk: fullViewingKey.stringEncoded)
        let sessionID = UUID()
        let original = ViewingKeyExportSession(id: sessionID, account: account, network: .mainnet)
        let changed = ViewingKeyExportSession(id: sessionID, account: changedStash, network: .mainnet)

        #expect(original.matches(account: changedStash, network: .mainnet))
        #expect(original == changed)
    }

    @Test
    func unavailableTypedKeysStayUnavailable() async throws {
        let account = try await ViewingKeyExportFixtures.accountWithoutViewingKeys(vendor: .keystone)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)

        #expect(session.key(for: .incoming) == nil)
        #expect(session.key(for: .full) == nil)
        #expect(session.matches(account: account, network: .mainnet))
    }

    @Test
    func keyDiagnosticsAreAlwaysRedacted() {
        let key = ViewingKeyMaterial("public-test-value-that-must-not-be-dumped")

        #expect(!String(describing: key).contains(key.rawValue))
        #expect(!String(reflecting: key).contains(key.rawValue))
        #expect(Mirror(reflecting: key).children.isEmpty)
    }

    @Test
    func sessionDiagnosticsAreAlwaysRedacted() async throws {
        let account = try await ViewingKeyExportFixtures.account(vendor: .zcash)
        let session = ViewingKeyExportSession(id: UUID(), account: account, network: .mainnet)
        let incoming = try #require(account.account.uivk?.stringEncoded)
        let full = try #require(account.account.ufvk?.stringEncoded)

        #expect(!String(describing: session).contains(incoming))
        #expect(!String(reflecting: session).contains(full))
        #expect(Mirror(reflecting: session).children.isEmpty)
    }

    @Test
    func pngDiagnosticsAreAlwaysRedacted() {
        let png = ViewingKeyPNG(data: Data("private-png-payload".utf8))

        #expect(!String(describing: png).contains("private-png-payload"))
        #expect(!String(reflecting: png).contains("private-png-payload"))
        #expect(Mirror(reflecting: png).children.isEmpty)
    }
}
