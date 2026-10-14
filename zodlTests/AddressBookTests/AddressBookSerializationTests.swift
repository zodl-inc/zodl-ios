//
//  AddressBookSerializationTests.swift
//  zodlTests
//
//  Batch 2 — persistence/crypto. Covers AddressBookClient binary (de)serialization, v1->v2
//  migration, and the encrypt/decrypt round-trip (Dependencies/AddressBookClient/AddressBookEncryption.swift).
//

import Testing
import Foundation
import CryptoKit
import ComposableArchitecture
@testable import zodl_internal
@testable @preconcurrency import ZODLSwiftWalletSDK

@Suite struct AddressBookSerializationTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Primitives

    @Test func intToBytesRoundTripsAndGuardsLength() {
        for value in [0, 1, -1, 256, 123_456_789, Int.max, Int.min] {
            #expect(AddressBookClient.bytesToInt(AddressBookClient.intToBytes(value)) == value)
        }
        #expect(AddressBookClient.bytesToInt([0, 0, 0]) == nil)
        #expect(AddressBookClient.bytesToInt([]) == nil)
    }

    @Test func dateSerializationRoundTripsToWholeSeconds() throws {
        var offset = 0
        let recovered = try AddressBookClient.deserializeDate(from: Data(AddressBookClient.serializeDate(fixedDate)), at: &offset)
        #expect(recovered == fixedDate)
        #expect(offset == 8)
    }

    @Test func readStringReadsLengthPrefixedUTF8() throws {
        let bytes = AddressBookClient.stringToBytes("hello")
        var data = Data()
        data.append(contentsOf: AddressBookClient.intToBytes(bytes.count))
        data.append(contentsOf: bytes)
        var offset = 0
        #expect(try AddressBookClient.readString(from: data, at: &offset) == "hello")
        #expect(offset == 8 + bytes.count)
    }

    @Test func readStringReturnsNilForZeroLength() throws {
        var data = Data()
        data.append(contentsOf: AddressBookClient.intToBytes(0))
        var offset = 0
        #expect(try AddressBookClient.readString(from: data, at: &offset) == nil)
    }

    @Test func readStringThrowsWhenTruncated() {
        var data = Data()
        data.append(contentsOf: AddressBookClient.intToBytes(10)) // claims 10 bytes...
        data.append(contentsOf: AddressBookClient.stringToBytes("ab")) // ...but only 2 are present
        var offset = 0
        #expect(throws: (any Error).self) {
            _ = try AddressBookClient.readString(from: data, at: &offset)
        }
    }

    @Test func subdataReturnsRangeAndThrowsWhenOutOfBounds() throws {
        let data = Data([1, 2, 3, 4])
        #expect(try AddressBookClient.subdata(of: data, in: 0..<2) == Data([1, 2]))
        #expect(throws: (any Error).self) {
            _ = try AddressBookClient.subdata(of: data, in: 0..<5)
        }
    }

    // MARK: - Contacts round-trip / migration

    @Test func serializeAndDeserializeRoundTrip() throws {
        let contacts = sampleContacts()
        let data = AddressBookClient.serializeContacts(contacts)
        let (result, migrated) = try AddressBookClient.contactsFrom(plainData: data)
        #expect(!migrated)
        #expect(result.version == 2)
        #expect(result.contacts == contacts.contacts)
    }

    @Test func unknownVersionReturnsEmptyNotMigrated() throws {
        var data = Data()
        data.append(contentsOf: AddressBookClient.intToBytes(99))
        let (result, migrated) = try AddressBookClient.contactsFrom(plainData: data)
        #expect(result == AddressBookContacts.empty)
        #expect(!migrated)
    }

    @Test func migratesVersion1BlobToLatestWithNilChainId() throws {
        let blob = v1Blob(contacts: [(address: "addr1", name: "Alice"), (address: "addr2", name: "Bob")])
        let (result, migrated) = try AddressBookClient.contactsFrom(plainData: blob)
        #expect(migrated)
        #expect(result.version == 2)
        #expect(result.contacts.count == 2)
        #expect(result.contacts.map(\.address) == ["addr1", "addr2"])
        #expect(result.contacts.allSatisfy { $0.chainId == nil })
        #expect(result.contacts.first?.lastUpdated == fixedDate)
    }

    // MARK: - Encrypt / decrypt round-trip (resolves coverage-uplift-plan.md §6.7)

    @Test func encryptDecryptRoundTrip() throws {
        let contacts = sampleContacts()
        let testAccount = account()
        let keys = AddressBookEncryptionKeys(keys: [0: try addressBookKey(byte: 0x42)])

        try withDependencies {
            $0.walletStorage.exportAddressBookEncryptionKeys = { keys }
        } operation: {
            let encrypted = try AddressBookClient.encryptContacts(contacts, account: testAccount)
            let (decrypted, migrated) = try AddressBookClient.contactsFrom(encryptedData: encrypted, account: testAccount)
            #expect(!migrated)
            #expect(decrypted.contacts == contacts.contacts)
        }
    }

    // MARK: - Helpers

    private func sampleContacts() -> AddressBookContacts {
        AddressBookContacts(
            lastUpdated: fixedDate,
            version: 2,
            contacts: [
                Contact(address: "addr1", name: "Alice", lastUpdated: fixedDate, chainId: nil),
                Contact(address: "addr2", name: "Bob", lastUpdated: fixedDate, chainId: "eth")
            ]
        )
    }

    private func v1Blob(contacts: [(address: String, name: String)]) -> Data {
        var data = Data()
        data.append(contentsOf: AddressBookClient.intToBytes(1)) // version 1
        data.append(contentsOf: AddressBookClient.serializeDate(fixedDate))
        data.append(contentsOf: AddressBookClient.intToBytes(contacts.count))
        for contact in contacts {
            data.append(contentsOf: AddressBookClient.serializeDate(fixedDate))
            let address = AddressBookClient.stringToBytes(contact.address)
            data.append(contentsOf: AddressBookClient.intToBytes(address.count))
            data.append(contentsOf: address)
            let name = AddressBookClient.stringToBytes(contact.name)
            data.append(contentsOf: AddressBookClient.intToBytes(name.count))
            data.append(contentsOf: name)
        }
        return data
    }

    private func addressBookKey(byte: UInt8) throws -> AddressBookKey {
        let encoded = try JSONEncoder().encode(Data(repeating: byte, count: 32))
        return try JSONDecoder().decode(AddressBookKey.self, from: encoded)
    }

    private func account() -> Account {
        Account(
            id: AccountUUID(id: [UInt8](repeating: 0x01, count: 16)),
            name: "test",
            keySource: "test",
            seedFingerprint: [UInt8](repeating: 0x02, count: 32),
            hdAccountIndex: Zip32AccountIndex(0),
            ufvk: nil,
            uivk: nil
        )
    }
}
