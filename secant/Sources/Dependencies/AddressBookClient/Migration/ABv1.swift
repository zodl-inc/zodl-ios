//
//  ABv1.swift
//  modules
//
//  Created by Lukáš Korba on 30.06.2025.
//

import Foundation
import ComposableArchitecture

extension AddressBookClient {
    static func contactsFromV1(plainData: Data, offset: Int) throws -> AddressBookContacts {
        var offset = offset
        
        // Deserialize `lastUpdated`
        guard let lastUpdated = try AddressBookClient.deserializeDate(from: plainData, at: &offset) else {
            return .empty
        }
        
        // Deserialize `contactsCount`
        let contactsCountBytes = try AddressBookClient.subdata(of: plainData, in: offset..<(offset + Constants.int64Size))
        offset += Constants.int64Size
        
        guard let contactsCount = AddressBookClient.bytesToInt(Array(contactsCountBytes)) else {
            return .empty
        }
        
        var contacts: [Contact] = []
        for _ in 0..<contactsCount {
            if let contact = try AddressBookClient.deserializeV1Contact(from: plainData, at: &offset) {
                contacts.append(contact)
            }
        }
        
        let abContacts = AddressBookContacts(
            lastUpdated: lastUpdated,
            version: AddressBookContacts.Constants.version,
            contacts: IdentifiedArrayOf(uniqueElements: contacts)
        )
        
        return abContacts
    }
    
    static func deserializeV1Contact(from data: Data, at offset: inout Int) throws -> Contact? {
        // Deserialize `lastUpdated`
        guard let lastUpdated = try AddressBookClient.deserializeDate(from: data, at: &offset) else {
            return nil
        }
        
        // Deserialize `address`
        guard let address = try readString(from: data, at: &offset) else {
            return nil
        }
        
        // Deserialize `name`
        guard let name = try readString(from: data, at: &offset) else {
            return nil
        }
        
        return Contact(
            address: address,
            name: name,
            lastUpdated: lastUpdated
        )
    }
}
