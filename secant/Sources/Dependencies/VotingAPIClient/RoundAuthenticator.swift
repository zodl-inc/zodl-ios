import CryptoKit
import Foundation

/// Result of binding a chain round to the wallet's bundled trust anchor.
enum RoundAuthStatus: Equatable, Sendable {
    case authenticated
    /// The chain reported a round id that is absent from the signed dynamic registry.
    case missingRound
    /// The registry entry uses a future auth schema this wallet does not understand.
    case unknownAuthVersion
    /// The entry is malformed or none of its signatures validate against bundled keys.
    case invalidSignatures
    /// The registry signed one EA key, but the chain round returned another.
    case eaPKMismatch
}

enum RoundAuthenticator {
    static let authVersionV1 = 1

    /// Authenticate one chain-sourced round against the dynamic config registry.
    ///
    /// For `auth_version: 1`, the admin signature covers only the raw 32-byte
    /// `ea_pk`. After verifying that signature against a key from the bundled
    /// static config, the wallet still checks that the chain response carries
    /// exactly the same `ea_pk`; this is the chain-binding step that catches a
    /// stale or hostile vote server response.
    static func authenticate(
        chainEaPK: Data,
        roundIdHex: String,
        rounds: [String: VotingServiceConfig.RoundEntry],
        trustedKeys: [StaticVotingConfig.TrustedKey]
    ) -> RoundAuthStatus {
        guard let entry = rounds[roundIdHex] else {
            return .missingRound
        }
        guard entry.authVersion == authVersionV1 else {
            return .unknownAuthVersion
        }
        guard entry.eaPk.count == 32, !entry.signatures.isEmpty, verifyEntrySignatures(entry: entry, trustedKeys: trustedKeys) else {
            return .invalidSignatures
        }
        guard chainEaPK == entry.eaPk else {
            return .eaPKMismatch
        }
        return .authenticated
    }

    /// Return true when at least one entry signature validates.
    ///
    /// The dynamic config names a trusted admin key by `key_id`; it does not
    /// inline public keys. This function resolves `key_id` into the static
    /// config, requires matching algorithms, and verifies the signature over
    /// the v1 payload: `entry.eaPk` bytes exactly as decoded from base64.
    static func verifyEntrySignatures(
        entry: VotingServiceConfig.RoundEntry,
        trustedKeys: [StaticVotingConfig.TrustedKey]
    ) -> Bool {
        guard entry.authVersion == authVersionV1, entry.eaPk.count == 32, !entry.signatures.isEmpty else {
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
                  publicKey.isValidSignature(signature.sig, for: entry.eaPk)
            else {
                continue
            }
            return true
        }
        return false
    }
}
