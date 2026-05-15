//
//  FileManagerClient.swift
//  Zashi
//
//  Created by Lukáš Korba on 07.04.2022.
//

import Foundation

struct FileManagerClient {
    var url: @Sendable (FileManager.SearchPathDirectory, FileManager.SearchPathDomainMask, URL?, Bool) throws -> URL
    var fileExists: @Sendable (String) -> Bool = { _ in false }
    var removeItem: @Sendable (URL) throws -> Void
}
