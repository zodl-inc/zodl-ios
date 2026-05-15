//
//  FileManagerLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.11.2022.
//

import Foundation

extension FileManagerClient {
    static let live = FileManagerClient(
        url: { searchPathDirectory, searchPathDomainMask, appropriateForURL, shouldCreate in
            try FileManager.default.url(for: searchPathDirectory, in: searchPathDomainMask, appropriateFor: appropriateForURL, create: shouldCreate)
        },
        fileExists: { path in
            FileManager.default.fileExists(atPath: path)
        },
        removeItem: { url in
            try FileManager.default.removeItem(at: url)
        }
    )
}
