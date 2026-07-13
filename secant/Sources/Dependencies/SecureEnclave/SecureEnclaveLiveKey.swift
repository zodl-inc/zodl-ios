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
    // Fresh context per decrypt: every seed access authenticates independently (no cross-action reuse
    // window). On macOS the redundant app-level gate before a spend is skipped, so this SE `.userPresence`
    // prompt is the single biometric for that action.
    let context = LAContext()
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
