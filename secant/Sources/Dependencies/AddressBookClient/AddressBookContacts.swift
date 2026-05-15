//
//  AddressBookContacts.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-30-2024.
//

import Foundation
import ComposableArchitecture

struct AddressBookContacts: Equatable, Codable {
    enum Constants {
        static let version = 2
    }
    
    let lastUpdated: Date
    let version: Int
    var contacts: IdentifiedArrayOf<Contact>
    
    init(lastUpdated: Date, version: Int, contacts: IdentifiedArrayOf<Contact>) {
        self.lastUpdated = lastUpdated
        self.version = version
        self.contacts = contacts
    }
}

extension AddressBookContacts {
    static let empty = AddressBookContacts(lastUpdated: .distantPast, version: Constants.version, contacts: [])
}
