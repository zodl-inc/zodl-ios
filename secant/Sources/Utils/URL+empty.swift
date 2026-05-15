//
//  URL+empty.swift
//  
//
//  Created by Lukáš Korba on 29.05.2023.
//

import Foundation

extension URL {
    /// The `DatabaseFilesClient` API returns an instance of the URL or throws an error.
    /// In order to use placeholders for the URL we need a URL instance, hence `emptyURL` and force unwrapp.
    static let emptyURL = URL(string: "http://empty.url")!// swiftlint:disable:this force_unwrapping
}
