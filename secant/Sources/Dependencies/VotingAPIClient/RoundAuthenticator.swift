#if VOTING_ENABLED
import CryptoKit
import Foundation

/// Result of binding a chain round to the wallet's bundled trust anchor.
enum RoundAuthStatus: Equatable, Sendable {
    case authenticated
    /// The chain reported a round id that is absent from the signed dynamic registry.
    case missingRound
    /// The registry entry uses an auth schema this wallet does not accept —
    /// either the retired v1 or a future version.
    case unknownAuthVersion
    /// The entry is malformed or none of its signatures validate against bundled keys.
    case invalidSignatures
    /// The registry signed one EA key, but the chain round returned another.
    case eaPKMismatch
}

enum RoundAuthenticator {
    /// The only accepted dynamic-config round-auth version.
    ///
    /// Policy decision (MOB-1678, `zcash_voting` 3.0 bump): v1 entries — signatures over
    /// the raw 32-byte `ea_pk` only — are rejected outright, matching the crate's verifier
    /// (`config::verify_round_entry` requires `ROUND_AUTH_VERSION_V2`). Accepting v1 would
    /// let us vote on a round whose attestation does not pin the round id or the PIR layout
    /// we will query with. Deliberate and overturnable: if a rollout window ever requires
    /// dual-accept, record the deviation in CHP.md and sunset it.
    static let authVersionV2 = 2

    /// ASCII domain separation tag for the v2 signing payload (33 bytes).
    private static let domainTagV2 = Data("zcash-shielded-vote:round-auth:v2".utf8)

    /// Authenticate one chain-sourced round against the dynamic config registry.
    ///
    /// For `auth_version: 2`, the admin signature covers the fixed-width payload built by
    /// `signingPayloadV2` — domain tag, round id, `ea_pk`, and the config's full PIR
    /// layout. `pirLayout` MUST be the top-level `pir_layout` of the **same** dynamic
    /// config `rounds` came from: the signature binds them, so a config mixing layouts and
    /// rounds from different generations fails here by construction. After verifying the
    /// signature against a key from the bundled static config, the wallet still checks
    /// that the chain response carries exactly the same `ea_pk`; this chain-binding step
    /// catches a stale or hostile vote server response and is not subsumed by v2.
    static func authenticate(
        chainEaPK: Data,
        roundIdHex: String,
        rounds: [String: VotingServiceConfig.RoundEntry],
        trustedKeys: [StaticVotingConfig.TrustedKey],
        pirLayout: VotingServiceConfig.PirLayout
    ) -> RoundAuthStatus {
        guard let entry = rounds[roundIdHex] else {
            return .missingRound
        }
        guard entry.authVersion == authVersionV2 else {
            return .unknownAuthVersion
        }
        guard
            entry.eaPk.count == 32,
            !entry.signatures.isEmpty,
            verifyEntrySignatures(
                entry: entry,
                roundIdHex: roundIdHex,
                pirLayout: pirLayout,
                trustedKeys: trustedKeys
            )
        else {
            return .invalidSignatures
        }
        guard chainEaPK == entry.eaPk else {
            return .eaPKMismatch
        }
        return .authenticated
    }

    /// Return true when at least one entry signature validates over the v2 payload.
    ///
    /// The dynamic config names a trusted admin key by `key_id`; it does not
    /// inline public keys. This function resolves `key_id` into the static
    /// config, requires matching algorithms, and verifies the ed25519 signature
    /// over `signingPayloadV2(roundIdHex:eaPk:pirLayout:)`.
    static func verifyEntrySignatures(
        entry: VotingServiceConfig.RoundEntry,
        roundIdHex: String,
        pirLayout: VotingServiceConfig.PirLayout,
        trustedKeys: [StaticVotingConfig.TrustedKey]
    ) -> Bool {
        guard entry.authVersion == authVersionV2, !entry.signatures.isEmpty else {
            return false
        }
        guard let payload = signingPayloadV2(roundIdHex: roundIdHex, eaPk: entry.eaPk, pirLayout: pirLayout) else {
            return false
        }

        let trustedByKeyId = trustedKeys.reduce(into: [String: StaticVotingConfig.TrustedKey]()) { keys, key in
            keys[key.keyId] = key
        }
        for signature in entry.signatures {
            guard let trustedKey = trustedByKeyId[signature.keyId],
                  trustedKey.alg == StaticVotingConfig.algEd25519,
                  signature.alg == trustedKey.alg,
                  signature.sig.count == 64,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: trustedKey.pubkey),
                  publicKey.isValidSignature(signature.sig, for: payload)
            else {
                continue
            }
            return true
        }
        return false
    }

    /// Canonical round-auth v2 bytes, mirroring `zcash_voting::round_auth::RoundAuthPayloadV2`:
    ///
    /// `"zcash-shielded-vote:round-auth:v2" (33B) || round_id (32B) || ea_pk (32B)
    ///   || pir_depth || tier0_layers || tier1_layers || poly_len` (each u32 little-endian).
    ///
    /// Returns nil — the entry can never authenticate — when the round id does not
    /// strict-hex-decode to exactly 32 bytes (crate parity: an undecodable id is skipped
    /// defensively), when `ea_pk` is not 32 bytes, or when the config predates
    /// `pir_layout.poly_len` (a pre-3.0 config cannot have produced a v2 attestation).
    static func signingPayloadV2(
        roundIdHex: String,
        eaPk: Data,
        pirLayout: VotingServiceConfig.PirLayout
    ) -> Data? {
        guard
            let roundId = strictHexData(roundIdHex),
            roundId.count == 32,
            eaPk.count == 32,
            let polyLen = pirLayout.polyLen
        else {
            return nil
        }

        var payload = domainTagV2
        payload.append(roundId)
        payload.append(eaPk)
        for value in [pirLayout.pirDepth, pirLayout.tier0Layers, pirLayout.tier1Layers, polyLen] {
            withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
        }
        return payload
    }
}
#endif
