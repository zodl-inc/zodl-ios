//
//  AddressBookInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-27-2024.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var addressBook: AddressBookClient {
        get { self[AddressBookClient.self] }
        set { self[AddressBookClient.self] = newValue }
    }
}

@DependencyClient
struct AddressBookClient {
    var resetAccount: @Sendable (Account) throws -> Void
    var allLocalContacts: @Sendable (Account) throws -> (contacts: AddressBookContacts, remoteStoreResult: RemoteStoreResult)
    var syncContacts: @Sendable (Account, AddressBookContacts?) throws -> (contacts: AddressBookContacts, remoteStoreResult: RemoteStoreResult)
    var storeContact: @Sendable (Account, Contact) throws -> (contacts: AddressBookContacts, remoteStoreResult: RemoteStoreResult)
    var deleteContact: @Sendable (Account, Contact) throws -> (contacts: AddressBookContacts, remoteStoreResult: RemoteStoreResult)
}
