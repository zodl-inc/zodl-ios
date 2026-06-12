//
//  ProposalsHasher.swift
//  Zashi
//
//  Created by Michal Fousek on 12.06.2026.
//

import CryptoKit
import Foundation

/// Recomputes the ZIP 1244 §"Proposals Hash" over chain-sourced proposal metadata.
///
/// The round's `proposals_hash` is authoritative chain state, while the proposal
/// array itself arrives from a vote server that is only an endpoint-discovery
/// target, not a trust anchor. Recomputing the hash from the parsed proposals and
/// comparing it to `proposals_hash` ensures the wallet displays - and the voter
/// signs a `proposalId`/`choice` derived from - exactly the proposal set the
/// chain committed to.
///
/// Only `id`, `title`, `description` and `options` (`index`, `label`) are part of
/// the canonical form; option descriptions, ZIP numbers and forum links are
/// UI-only metadata outside the hash.
enum ProposalsHasher {
    /// SHA-256 of the canonical JSON serialization of the proposals array.
    static func computeProposalsHash(_ proposals: [VotingProposal]) -> Data {
        Data(SHA256.hash(data: Data(canonicalProposalsJSON(proposals).utf8)))
    }

    /// Canonical JSON form per ZIP 1244: proposals sorted by `id` ascending, options by `index` ascending,
    /// no whitespace, keys in order `id`, `title`, `description`, `options` (and `index`, `label` for each option).
    static func canonicalProposalsJSON(_ proposals: [VotingProposal]) -> String {
        let sortedProposals = proposals.sorted { $0.id < $1.id }
        let parts = sortedProposals.map { proposal -> String in
            let sortedOptions = proposal.options.sorted { $0.index < $1.index }
            let optionParts = sortedOptions.map { option -> String in
                "{\"index\":\(option.index),\"label\":\(jsonEncodedString(option.label))}"
            }
            let fields = [
                "\"id\":\(proposal.id)",
                "\"title\":\(jsonEncodedString(proposal.title))",
                "\"description\":\(jsonEncodedString(proposal.description))",
                "\"options\":[\(optionParts.joined(separator: ","))]"
            ]
            return "{\(fields.joined(separator: ","))}"
        }
        return "[\(parts.joined(separator: ","))]"
    }

    /// JSON-encode a Swift string to match the Rust `serde_json::to_string` byte output.
    /// `JSONEncoder` with `.withoutEscapingSlashes` leaves `/` un-escaped (Swift default: `\/`);
    /// otherwise defaults match serde_json (UTF-8 for non-ASCII, `\uXXXX` for control chars).
    /// The chain computes `proposals_hash` using `serde_json`, so divergence here would
    /// cause a hard-fail hash mismatch any time a proposal title or label contained `/`.
    private static func jsonEncodedString(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(string) else {
            // Encoding a String to JSON cannot fail in practice; an empty string
            // keeps the canonical form valid and simply fails the hash comparison.
            return "\"\""
        }
        return String(decoding: data, as: UTF8.self)
    }
}
