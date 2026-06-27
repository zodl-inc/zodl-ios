//
//  SecureEnclaveLiveKey.swift
//  Zashi
//
//  Live Secure Enclave implementation. See docs/macos/KEYCHAIN_SE_HARDENING.md and
//  SecureEnclaveInterface.swift.
//

import Foundation
import Security
import LocalAuthentication
import CryptoKit
import ComposableArchitecture

/// Application tag identifying the single seed-wrapping key in the keychain.
private let seedWrappingKeyTag = Data("com.zodl.seedWrappingKey".utf8)

/// ECIES: ephemeral ECDH (cofactor) → X9.63 SHA-256 KDF → AES-GCM. Encrypt with the public key,
/// decrypt with the in-enclave private key. Handles the small seed payload directly.
private let seedWrappingAlgorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM

/// A successful Secure-Enclave auth is reused for this many seconds before re-prompting. A single user
/// action can trigger more than one seed decrypt (e.g. a send: the spend, then deriving metadata keys);
/// reusing the auth over a short window collapses that burst into ONE prompt instead of one per decrypt.
/// Short on purpose — a deliberate later action re-authenticates.
private let seedAuthReuseDuration: TimeInterval = 10

/// Holds the single `LAContext` reused across decrypts so the reuse window above actually applies (a
/// fresh context per call would re-prompt every time). `LAContext` isn't `Sendable`, but seed decrypts
/// are serialized by the user's auth prompt, so sharing one is safe — hence `@unchecked Sendable`.
private final class SeedAuthContextHolder: @unchecked Sendable {
    let context: LAContext = {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = seedAuthReuseDuration
        return context
    }()
}
private let seedAuthContextHolder = SeedAuthContextHolder()

extension SecureEnclaveClient: DependencyKey {
    static let liveValue = SecureEnclaveClient(
        isAvailable: { SecureEnclave.isAvailable },
        encryptSeed: { plaintext in
            let privateKey = try getOrCreateSeedWrappingKey()
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw SecureEnclaveError.publicKeyUnavailable
            }
            guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, seedWrappingAlgorithm) else {
                throw SecureEnclaveError.algorithmUnsupported
            }
            var error: Unmanaged<CFError>?
            guard let cipher = SecKeyCreateEncryptedData(publicKey, seedWrappingAlgorithm, plaintext as CFData, &error) else {
                throw SecureEnclaveError.encryptionFailed
            }
            return cipher as Data
        },
        decryptSeed: { ciphertext, reason in
            // `SecKeyCreateDecryptedData` on a `.userPresence` key blocks while the OS presents the
            // auth UI, so run it off the main thread and bridge back to async.
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try decryptWithSeedWrappingKey(ciphertext, reason: reason))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        },
        deleteKey: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: seedWrappingKeyTag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecureEnclaveError.keychain(status)
            }
        }
    )
}

// MARK: - Helpers

/// Loads the seed-wrapping private-key reference (does NOT trigger auth — only *using* it to decrypt
/// does). `authContext` carries the decrypt prompt wording via its `localizedReason`.
private func loadSeedWrappingKey(authContext: LAContext?) throws -> SecKey? {
    var query: [String: Any] = [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: seedWrappingKeyTag,
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecReturnRef as String: true
    ]
    if let authContext {
        query[kSecUseAuthenticationContext as String] = authContext
    }

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecItemNotFound:
        return nil
    case errSecSuccess:
        guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw SecureEnclaveError.keyNotFound
        }
        // swiftlint:disable:next force_cast
        return (item as! SecKey)
    default:
        throw SecureEnclaveError.keychain(status)
    }
}

/// Generates the non-extractable P-256 enclave key, gated by `.userPresence` (biometrics OR the login
/// password — survives Touch ID re-enrolment and works on Touch-ID-less Macs).
private func createSeedWrappingKey() throws -> SecKey {
    var accessError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .userPresence],
        &accessError
    ) else {
        throw SecureEnclaveError.accessControlFailed
    }

    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
        kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        kSecPrivateKeyAttrs as String: [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: seedWrappingKeyTag,
            kSecAttrAccessControl as String: access
        ]
    ]

    var keyError: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &keyError) else {
        throw SecureEnclaveError.keyGenerationFailed
    }
    return key
}

private func getOrCreateSeedWrappingKey() throws -> SecKey {
    if let existing = try loadSeedWrappingKey(authContext: nil) {
        return existing
    }
    return try createSeedWrappingKey()
}

private func decryptWithSeedWrappingKey(_ ciphertext: Data, reason: String) throws -> Data {
    // Reuse the shared context so an auth from a recent decrypt (within `seedAuthReuseDuration`) is
    // honored without re-prompting — one FaceID per burst, not per decrypt.
    let context = seedAuthContextHolder.context
    context.localizedReason = reason
    guard let privateKey = try loadSeedWrappingKey(authContext: context) else {
        throw SecureEnclaveError.keyNotFound
    }
    guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, seedWrappingAlgorithm) else {
        throw SecureEnclaveError.algorithmUnsupported
    }
    var error: Unmanaged<CFError>?
    guard let plaintext = SecKeyCreateDecryptedData(privateKey, seedWrappingAlgorithm, ciphertext as CFData, &error) else {
        throw SecureEnclaveError.decryptionFailed
    }
    return plaintext as Data
}
