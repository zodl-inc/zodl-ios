//
//  ServerSetupMigrationWarningTests.swift
//  zodlTests
//
//  Covers `ServerSetup.shouldWarnBeforeManualSwitch(endpoint:activeSnapshots:)` — the manual half of
//  the migration network law (N6). Automatic server selection was already pinned away from a live
//  run's broadcast provider; this predicate is what stops a user hand-picking, in Settings, the very
//  provider their migration broadcasts through — which would hand one operator both sides of the
//  link the migration exists to keep apart.
//
//  The subtle case is the last one: re-choosing the server you ALREADY sync with is the sanctioned
//  same-server mode, not a new correlation, so it must NOT warn even though the broadcast provider
//  matches. That asymmetry is the whole reason this is a table-tested pure static rather than an
//  inline condition.
//

import Foundation
import Testing
import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ServerSetupMigrationWarningTests {
    // MARK: - Fixtures

    private static func endpoint(_ host: String) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: 443, secure: true)
    }

    private static func snapshot(sync: String, broadcast: String) -> MigrationNetworkSnapshot {
        MigrationNetworkSnapshot(
            useTor: true,
            syncEndpoint: MigrationNetworkSnapshot.Endpoint(host: sync, port: 443, secure: true),
            broadcastEndpoint: MigrationNetworkSnapshot.Endpoint(host: broadcast, port: 443, secure: true),
            takenAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func shouldWarn(
        picking host: String,
        sync: String,
        broadcast: String
    ) -> Bool {
        ServerSetup.shouldWarnBeforeManualSwitch(
            endpoint: endpoint(host),
            activeSnapshots: [snapshot(sync: sync, broadcast: broadcast)]
        )
    }

    // MARK: - No active migration

    @Test func noSnapshotsNeverWarns() {
        #expect(
            !ServerSetup.shouldWarnBeforeManualSwitch(
                endpoint: Self.endpoint("eu.zec.rocks"),
                activeSnapshots: []
            )
        )
    }

    // MARK: - The host the run broadcasts through

    @Test func exactBroadcastHostWarns() {
        #expect(Self.shouldWarn(picking: "us.zec.stardust.rest", sync: "eu.zec.rocks", broadcast: "us.zec.stardust.rest"))
    }

    /// Provider-level, not host-level: a sibling pool of the broadcast provider is the SAME operator,
    /// so it correlates just as well as the exact host.
    @Test func siblingHostOfBroadcastProviderWarns() {
        #expect(Self.shouldWarn(picking: "eu.zec.stardust.rest", sync: "eu.zec.rocks", broadcast: "us.zec.stardust.rest"))
    }

    @Test func hostCasingIsIgnored() {
        #expect(Self.shouldWarn(picking: "US.ZEC.STARDUST.REST", sync: "eu.zec.rocks", broadcast: "us.zec.stardust.rest"))
    }

    // MARK: - Everything else

    @Test func unrelatedProviderDoesNotWarn() {
        #expect(!Self.shouldWarn(picking: "na.zec.rocks", sync: "eu.zec.rocks", broadcast: "us.zec.stardust.rest"))
    }

    @Test func customServerUnrelatedToTheRunDoesNotWarn() {
        #expect(!Self.shouldWarn(picking: "lwd.example.com", sync: "eu.zec.rocks", broadcast: "us.zec.stardust.rest"))
    }

    /// THE asymmetry: the run already syncs and broadcasts through one provider (same-server mode).
    /// Re-picking it introduces no new link, so warning here would be noise on a state the user is
    /// already in.
    @Test func reChoosingTheServerAlreadySyncedWithDoesNotWarn() {
        #expect(!Self.shouldWarn(picking: "eu.zec.rocks", sync: "eu.zec.rocks", broadcast: "eu.zec.rocks"))
    }

    /// A20, RULED QUIET. Sync and broadcast are already sibling pools of ONE operator, so that
    /// operator already sees both sides of this run; picking a third pool of the same operator
    /// changes the linkability by exactly nothing.
    ///
    /// This flipped from warning to quiet deliberately. A warning that fires when nothing changed
    /// is noise, and noise is what teaches people to dismiss the warnings that do matter — so the
    /// truthful-but-useless reading ("your migration broadcasts through zec.rocks too") loses to
    /// the one that keeps the alert meaningful.
    @Test func siblingOfARunAlreadyOnOneProviderStaysQuiet() {
        #expect(!Self.shouldWarn(picking: "na.zec.rocks", sync: "eu.zec.rocks", broadcast: "sa.zec.rocks"))
    }

    /// The case the exemption must NOT swallow: the run's two sides are with DIFFERENT operators,
    /// and this pick is what would put them together. Same provider family as the previous test —
    /// only the run's own shape differs.
    @Test func siblingOfBroadcastWarnsWhenSyncIsElsewhere() {
        #expect(Self.shouldWarn(picking: "na.zec.rocks", sync: "us.zec.stardust.rest", broadcast: "sa.zec.rocks"))
    }

    // MARK: - Several accounts migrating at once

    /// Zodl and Keystone accounts run independent plans, so the predicate takes a LIST: a pick that
    /// is safe for one run and unsafe for another must warn.
    @Test func warnsWhenAnyAccountsRunIsCompromised() {
        let snapshots = [
            Self.snapshot(sync: "eu.zec.rocks", broadcast: "eu.zec.rocks"),
            Self.snapshot(sync: "na.zec.rocks", broadcast: "us.zec.stardust.rest")
        ]
        #expect(
            ServerSetup.shouldWarnBeforeManualSwitch(
                endpoint: Self.endpoint("us.zec.stardust.rest"),
                activeSnapshots: snapshots
            )
        )
    }

    @Test func doesNotWarnWhenEveryAccountsRunIsUnaffected() {
        let snapshots = [
            Self.snapshot(sync: "eu.zec.rocks", broadcast: "eu.zec.rocks"),
            Self.snapshot(sync: "na.zec.rocks", broadcast: "sa.zec.rocks")
        ]
        #expect(
            !ServerSetup.shouldWarnBeforeManualSwitch(
                endpoint: Self.endpoint("lwd.example.com"),
                activeSnapshots: snapshots
            )
        )
    }
}
