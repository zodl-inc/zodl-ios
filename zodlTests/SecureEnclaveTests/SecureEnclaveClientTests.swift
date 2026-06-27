//
//  SecureEnclaveClientTests.swift
//  zodlTests
//
//  Contract tests for SecureEnclaveClient via the in-memory software fake (no real enclave, no
//  biometric prompt — CI-safe). The live Secure-Enclave round-trip is verified manually on macOS.
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct SecureEnclaveClientTests {
    /// Encrypt then decrypt returns the original bytes, and the ciphertext is not the plaintext.
    @Test func roundTripsSeed() async throws {
        let client = SecureEnclaveClient.inMemory()
        let seed = Data("abandon abandon abandon … art".utf8)

        let cipher = try client.encryptSeed(seed)
        #expect(cipher != seed)

        let recovered = try await client.decryptSeed(cipher, "test")
        #expect(recovered == seed)
    }

    /// Deleting the key makes previously-produced ciphertext unrecoverable (models the enclave key
    /// becoming non-extractable / gone after `resetZashi`).
    @Test func deleteKeyMakesPriorCiphertextUnrecoverable() async throws {
        let client = SecureEnclaveClient.inMemory()
        let cipher = try client.encryptSeed(Data("hello seed".utf8))

        try client.deleteKey()

        await #expect(throws: (any Error).self) {
            _ = try await client.decryptSeed(cipher, "test")
        }
    }

    @Test func inMemoryReportsAvailable() {
        #expect(SecureEnclaveClient.inMemory().isAvailable() == true)
    }
}
