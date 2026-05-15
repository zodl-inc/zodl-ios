//
//  LogStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 23.01.2023.
//

import Foundation
import OSLog

enum LogStore {
    static func exportCategory(
        _ category: String,
        level: OSLogEntryLog.Level = .debug,
        hoursToThePast: TimeInterval = 168,
        fileSize: Int = 1_000_000
    ) async throws -> [String]? {
        guard let bundle = Bundle.main.bundleIdentifier else { return nil }
        
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let date = Date.now.addingTimeInterval(-hoursToThePast * 3600)
        let position = store.position(date: date)
        var res: [String] = []
        var size = 0
        
        let entries = try store.getEntries(at: position)
        for entry in entries {
            guard let logEntry = entry as? OSLogEntryLog else {
                continue
            }
            
            guard logEntry.subsystem == bundle
                    && logEntry.category == category
                    && level.rawValue <= logEntry.level.rawValue else {
                continue
            }
            
            guard size < fileSize else {
                break
            }
            
            size += logEntry.composedMessage.utf8.count
            res.append("[\(logEntry.date.timestamp())] \(logEntry.composedMessage)")
        }
        
        return res
    }
}
