//
//  MigrationModelsTests.swift
//  zodlTests
//
//  Covers Codable round-trips and basic invariants for the Orchard -> Ironwood migration
//  value models (Models/Migration/MigrationModels.swift). MOB-1496: most of the pre-real-SDK
//  shadow types this file used to cover (`MigrationState`, `AttentionReason`/`MigrationAttentionReason`,
//  `TransferResult`/`MigrationTransferResult`, `NetworkPrivacyOptions`/`MigrationNetworkPrivacyOptions`)
//  are now real SDK types the app no longer owns — and, per the SDK's ground truth
//  (`Model/MigrationModels.swift`, `Migration/OrchardMigration.swift`), none of them are `Codable`
//  (`Equatable, Sendable` only; `MigrationNetworkPrivacyOptions` is `Equatable` only, carrying a
//  non-`Sendable` `LightWalletEndpoint`) — so their round-trip coverage is simply gone, not
//  replaceable. `MigrationSchedule`/`MigrationTransferProposal` ARE still `Codable` (real SDK types,
//  kept for local persistence) — their coverage is retargeted, not dropped. What remains app-owned
//  in `MigrationModels.swift` (`MigrationSummary`, `MigrationTransferRow`, `MigrationMode`) is
//  unaffected. No shared/global state -> no `.serialized`.
//

import Testing
import Foundation
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationModelsTests {
    @Test func migrationModeCodableRoundTrip() throws {
        for mode in [MigrationMode.immediate, MigrationMode.privateScheduled] {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(MigrationMode.self, from: data) == mode)
        }
    }

    @Test func migrationScheduleCodableRoundTripWithNonTrivialTransferGraph() throws {
        let transfers = [
            MigrationTransferProposal(
                id: "transfer-1",
                amount: Zatoshi(500),
                anchorHeight: 100,
                nextExecutableAfterHeight: 110,
                expiryHeight: 200
            ),
            MigrationTransferProposal(
                id: "transfer-2",
                amount: Zatoshi(1_500),
                anchorHeight: 110,
                nextExecutableAfterHeight: 220,
                expiryHeight: 310
            ),
            MigrationTransferProposal(
                id: "transfer-3",
                amount: Zatoshi(2_500),
                anchorHeight: 220,
                nextExecutableAfterHeight: 330,
                expiryHeight: 420
            )
        ]
        let original = MigrationSchedule(transfers: transfers, estimatedDurationHours: 72)

        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MigrationSchedule.self, from: data) == original)
    }

    @Test func migrationTransferRowCodableRoundTripEachStatus() throws {
        let statuses: [MigrationTransferRow.Status] = [
            MigrationTransferRow.Status.sent,
            MigrationTransferRow.Status.active,
            MigrationTransferRow.Status.overdue,
            MigrationTransferRow.Status.pending,
            MigrationTransferRow.Status.invalid,
            MigrationTransferRow.Status.expired
        ]

        for (index, status) in statuses.enumerated() {
            let original = MigrationTransferRow(
                id: "row-\(index)",
                index: index,
                amount: Zatoshi(Int64(100 * (index + 1))),
                status: status,
                hoursFromNow: index
            )
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(MigrationTransferRow.self, from: data) == original)
        }
    }

    @Test func migrationTransferRowDefaultsToNoMinutesRecencyAndNotBroadcasting() {
        let row = MigrationTransferRow(id: "row-0", index: 0, amount: Zatoshi(100), status: .sent, hoursFromNow: 0)

        #expect(row.sentMinutesAgo == nil)
        #expect(row.isBroadcasting == false)
    }

    @Test func migrationTransferRowCodableRoundTripWithSentMinutesAgo() throws {
        let original = MigrationTransferRow(
            id: "row-0",
            index: 1,
            amount: Zatoshi(287_410_000),
            status: .sent,
            hoursFromNow: 0,
            sentMinutesAgo: 18
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MigrationTransferRow.self, from: data)

        #expect(decoded == original)
        #expect(decoded.sentMinutesAgo == 18)
    }

    @Test func migrationTransferRowCodableRoundTripWithIsBroadcasting() throws {
        let original = MigrationTransferRow(
            id: "row-2",
            index: 2,
            amount: Zatoshi(243_100_000),
            status: .active,
            hoursFromNow: 0,
            isBroadcasting: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MigrationTransferRow.self, from: data)

        #expect(decoded == original)
        #expect(decoded.isBroadcasting == true)
    }

    @Test func migrationSummaryZeroIsAllZero() {
        let zero = MigrationSummary.zero
        #expect(zero.transferred == Zatoshi.zero)
        #expect(zero.dust == Zatoshi.zero)
        #expect(zero.transfersSent == 0)
        #expect(zero.transfersTotal == 0)
        #expect(zero.estimatedDurationHours == 0)
    }

    @Test func transferProposalIdDrivesIdentifiable() {
        let proposal = MigrationTransferProposal(
            id: "transfer-42",
            amount: Zatoshi(999),
            anchorHeight: 10,
            nextExecutableAfterHeight: 20,
            expiryHeight: 30
        )
        #expect(proposal.id == "transfer-42")
    }

    // MARK: - MigrationNetworkSnapshot (MOB-1496 W4)

    @Test func migrationNetworkSnapshotCodableRoundTripIncludingCustomProvider() throws {
        let original = MigrationNetworkSnapshot(
            useTor: true,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "na.zec.rocks", port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "mynode.example.com", port: 9067, secure: false),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MigrationNetworkSnapshot.self, from: data)

        #expect(decoded == original)
        #expect(decoded.syncProvider == ServerProvider.zecRocks)
        #expect(decoded.broadcastProvider == ServerProvider.custom(host: "mynode.example.com"))
    }

    /// R8-T3 (#22): `syncProvider`/`broadcastProvider` used to be STORED (constructor args, present
    /// as their own JSON keys) — a legacy persisted blob from before this change still carries those
    /// two extra keys. `JSONDecoder` ignores unknown keys by default, so decoding must still succeed,
    /// with the (now-computed) provider properties matching a live `ServerProvider.classify(host:)`
    /// of their respective endpoint — never the stale value the legacy blob happened to carry.
    @Test func migrationNetworkSnapshotDecodesLegacyBlobWithStoredProviderKeys() throws {
        struct LegacyMigrationNetworkSnapshot: Codable {
            let useTor: Bool
            let syncEndpoint: MigrationNetworkSnapshot.Endpoint
            let syncProvider: ServerProvider
            let broadcastEndpoint: MigrationNetworkSnapshot.Endpoint
            let broadcastProvider: ServerProvider
            let takenAt: Date
        }

        // Deliberately a STALE/wrong `syncProvider` value versus what `syncEndpoint`'s host would
        // classify to — proving the decoded snapshot re-derives it live rather than ever reading
        // back whatever this legacy blob's own (now-ignored) key happened to carry.
        let legacy = LegacyMigrationNetworkSnapshot(
            useTor: true,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "na.zec.rocks", port: 443, secure: true),
            syncProvider: ServerProvider.custom(host: "stale-value-from-before-the-fix"),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "mynode.example.com", port: 9067, secure: false),
            broadcastProvider: ServerProvider.custom(host: "stale-value-from-before-the-fix"),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let legacyData = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(MigrationNetworkSnapshot.self, from: legacyData)

        #expect(decoded.useTor == true)
        #expect(decoded.syncEndpoint.host == "na.zec.rocks")
        #expect(decoded.broadcastEndpoint.host == "mynode.example.com")
        #expect(decoded.takenAt == legacy.takenAt)
        #expect(decoded.syncProvider == ServerProvider.zecRocks)
        #expect(decoded.broadcastProvider == ServerProvider.custom(host: "mynode.example.com"))
    }

    @Test func migrationNetworkSnapshotEndpointRoundTripsHostPortSecureThroughLightWalletEndpoint() {
        let source = LightWalletEndpoint(address: "eu.zec.stardust.rest", port: 8443, secure: false, streamingCallTimeoutInMillis: 12_345)

        let wrapped = MigrationNetworkSnapshot.Endpoint(source)

        #expect(wrapped.host == "eu.zec.stardust.rest")
        #expect(wrapped.port == 8443)
        #expect(wrapped.secure == false)

        // Reconstruction uses the SAME streaming-timeout constant the built-in endpoint list uses —
        // not whatever the original `LightWalletEndpoint` happened to carry (the wrapper doesn't
        // persist it at all).
        let reconstructed = wrapped.toLightWalletEndpoint()
        #expect(reconstructed.host == "eu.zec.stardust.rest")
        #expect(reconstructed.port == 8443)
        #expect(reconstructed.secure == false)
        #expect(reconstructed.streamingCallTimeoutInMillis == ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis)
    }

    @Test func migrationNetworkSnapshotEndpointMemberwiseInitAlsoRoundTrips() {
        let wrapped = MigrationNetworkSnapshot.Endpoint(host: "zec.rocks", port: 443, secure: true)
        let reconstructed = wrapped.toLightWalletEndpoint()

        #expect(reconstructed.host == "zec.rocks")
        #expect(reconstructed.port == 443)
        #expect(reconstructed.secure == true)
    }

    // MARK: - MigrationNetworkSnapshot.committedAt (MOB-1497)

    @Test func migrationNetworkSnapshotDefaultsToProvisionalWhenCommittedAtOmittedFromInit() {
        let snapshot = MigrationNetworkSnapshot(
            useTor: true,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "na.zec.rocks", port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "us.zec.stardust.rest", port: 443, secure: true),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(snapshot.committedAt == nil)
    }

    @Test func migrationNetworkSnapshotCommittedAtRoundTripsThroughCodableWhenSet() throws {
        let original = MigrationNetworkSnapshot(
            useTor: true,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "na.zec.rocks", port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "us.zec.stardust.rest", port: 443, secure: true),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            committedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MigrationNetworkSnapshot.self, from: data)

        #expect(decoded == original)
        #expect(decoded.committedAt == original.committedAt)
    }

    /// The feature is unreleased (no pre-MOB-1497 payload without `committedAt` exists in the wild),
    /// but Swift's synthesized `Decodable` conformance already treats a missing key on an `Optional`
    /// property as `nil`. Rather than hand-authoring the whole payload (and guessing at
    /// `ServerProvider`'s synthesized JSON shape), this encodes a real committed snapshot and strips
    /// the `committedAt` key back out, standing in for a hypothetical old payload that never had it —
    /// confirming decode comes back PROVISIONAL rather than throwing or defaulting some other way.
    @Test func migrationNetworkSnapshotDecodesAsProvisionalWhenCommittedAtKeyIsMissingFromThePayload() throws {
        let committed = MigrationNetworkSnapshot(
            useTor: true,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: "na.zec.rocks", port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: "us.zec.stardust.rest", port: 443, secure: true),
            takenAt: Date(timeIntervalSince1970: 1_700_000_000),
            committedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let encoded = try JSONEncoder().encode(committed)
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "committedAt")
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(MigrationNetworkSnapshot.self, from: strippedData)

        #expect(decoded.committedAt == nil)
        #expect(decoded.useTor == true)
        #expect(decoded.syncEndpoint.host == "na.zec.rocks")
    }
}
