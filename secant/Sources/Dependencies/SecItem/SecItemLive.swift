//
//  SecItemLive.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Foundation
import Security

extension SecItemClient {
    static let live = SecItemClient(
        copyMatching: { query, result in
            SecItemCopyMatching(query, &result)
        },
        add: { attributes, result in
            SecItemAdd(attributes, &result)
        },
        update: { query, attributesToUpdate in
            SecItemUpdate(query, attributesToUpdate)
        },
        delete: { query in
            SecItemDelete(query)
        }
    )
}
