//
//  SecureEnclaveInterface.swift
//  Zashi
//
//  macOS keychain hardening — step 1. See docs/macos/KEYCHAIN_SE_HARDENING.md.
//
//  A small dependency that wraps a non-extractable Secure Enclave key and uses it to encrypt /
//  decrypt the wallet seed. Encryption uses the enclave key's PUBLIC half (no prompt); decryption
//  uses the in-enclave private key, gated by `.userPresence` access control, which triggers an
//  OS biometric / password prompt. The private key never leaves the enclave — so a stolen keychain
//  ciphertext is useless off the machine, even to root + SIP-bypass.
//
//  Cross-platform by construction (the Security / LocalAuthentication / CryptoKit APIs all exist on
//  iOS too), but for now only the macOS storage path wires it in — iOS keeps today's storage.
//

import Foundation
import CryptoKit
import ComposableArchitecture

extension DependencyValues {
    var secureEnclave: SecureEnclaveClient {
        get { self[SecureEnclaveClient.self] }
        set { self[SecureEnclaveClient.self] = newValue }
    }
}

@DependencyClient
struct SecureEnclaveClient {
    /// Whether this machine has a usable Secure Enclave (false on VMs / CI / old Intel Macs).
    var isAvailable: @Sendable () -> Bool = { false }

    /// Encrypt `plaintext` (the seed bytes) with the enclave key's PUBLIC half via ECIES. No prompt.
    /// Lazily generates the non-extractable enclave key on first use.
    var encryptSeed: @Sendable (_ plaintext: Data) throws -> Data

    /// Decrypt `ciphertext` using the in-enclave private key. Triggers the OS auth prompt
    /// (`.userPresence`); `reason` is the wording shown to the user. Async because the prompt is.
    var decryptSeed: @Sendable (_ ciphertext: Data, _ reason: String) async throws -> Data

    /// Delete the enclave key (used by `resetZashi`). Afterwards, existing ciphertext is unrecoverable.
    var deleteKey: @Sendable () throws -> Void
}

enum SecureEnclaveError: Error, Equatable {
    case unavailable
    case accessControlFailed
    case keyGenerationFailed
    case keyNotFound
    case publicKeyUnavailable
    case algorithmUnsupported
    case encryptionFailed
    case decryptionFailed
    case keychain(OSStatus)
}

#if DEBUG
extension SecureEnclaveClient {
    /// In-memory software fake (AES-GCM, NOT Secure-Enclave-backed) for tests and previews. Models the
    /// encrypt → decrypt contract — and that decrypt is async — without an enclave or a biometric prompt.
    /// `deleteKey` rotates the key, so ciphertext produced before it can no longer be opened.
    static func inMemory() -> SecureEnclaveClient {
        let key = LockIsolated(SymmetricKey(size: .bits256))
        return SecureEnclaveClient(
            isAvailable: { true },
            encryptSeed: { plaintext in
                guard let combined = try AES.GCM.seal(plaintext, using: key.value).combined else {
                    throw SecureEnclaveError.encryptionFailed
                }
                return combined
            },
            decryptSeed: { ciphertext, _ in
                do {
                    return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key.value)
                } catch {
                    throw SecureEnclaveError.decryptionFailed
                }
            },
            deleteKey: { key.setValue(SymmetricKey(size: .bits256)) }
        )
    }
}
#endif
