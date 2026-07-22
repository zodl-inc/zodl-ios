//
//  ServerProvider.swift
//  Zashi
//
//  Classifies a lightwalletd host into its operating provider "family" (MOB-1496 W4). The migration
//  network snapshot (`MigrationNetworkSnapshot`) and the auto-selection pinning it drives both need
//  to reason about which servers share an operator, not just which literal host is currently active
//  — a switch from `na.zec.rocks` to `eu.zec.rocks` is still the SAME provider, but a switch to
//  `us.zec.stardust.rest` is not. Generic home (`Models/`) rather than `Dependencies/MigrationManager/`:
//  nothing here is migration-specific, and `ServerSetupStore`'s manual-switch privacy warning (also
//  W4) classifies against it too.
//

import Foundation

enum ServerProvider: Equatable, Sendable, Codable, Hashable {
    case zecRocks
    case stardust
    case custom(host: String)

    /// Case-insensitive host classification (both the comparison AND the `.custom` payload are
    /// normalized to lowercase, so two differently-cased spellings of the same custom host classify
    /// as EQUAL `ServerProvider` values, not merely similar ones):
    /// - `"zec.rocks"` exactly, or any `*.zec.rocks` suffix (covers the regional pools
    ///   `na`/`sa`/`eu`/`ap.zec.rocks` and the testnet default `testnet.zec.rocks`) -> `.zecRocks`.
    /// - Any `*.zec.stardust.rest` suffix (covers `us`/`eu.zec.stardust.rest`) -> `.stardust`.
    /// - Anything else -> `.custom(host:)`, carrying the lowercased host as its own family identity
    ///   (a custom server is a family of exactly one).
    static func classify(host: String) -> ServerProvider {
        let normalized = host.lowercased()

        if normalized == "zec.rocks" || normalized.hasSuffix(".zec.rocks") {
            return .zecRocks
        }
        if normalized.hasSuffix(".zec.stardust.rest") {
            return .stardust
        }
        return .custom(host: normalized)
    }
}
