//
//  LogsHandlerLive.swift
//  Zashi
//
//  Created by Lukáš Korba on 30.01.2023.
//

import Foundation
import ComposableArchitecture
import OSLog

extension LogsHandlerClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            exportAndStoreLogs: { sdkLogs, tcaLogs, walletLogs in
                // Purge artifacts left behind by previous exports (e.g. when the app
                // was killed while the share sheet was open), then stage this export
                // in a unique, file-protected directory.
                try? FileManager.default.removeItem(at: exportsRootURL())
                try? FileManager.default.removeItem(at: legacyStagingURL())

                let exportDirectory = exportsRootURL().appendingPathComponent(UUID().uuidString, isDirectory: true)
                // The staging directory name defines the folder name inside the produced ZIP.
                let logsURL = exportDirectory.appendingPathComponent("zashiPrivateData", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: logsURL,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete]
                )

                // The plaintext staging files are only needed to build the ZIP.
                defer {
                    try? FileManager.default.removeItem(at: logsURL)
                }

                // export the logs
                async let sdkLogsVerbose = LogsHandlerClient.exportAndStoreLogsFor(
                    key: sdkLogs,
                    atURL: logsURL.appendingPathComponent("sdkLogs_verbose.txt")
                )
                async let sdkLogsSync = LogsHandlerClient.exportAndStoreLogsFor(
                    key: sdkLogs,
                    atURL: logsURL.appendingPathComponent("sdkLogs_sync.txt"),
                    level: .info // The info level represents the sync log in the SDK
                )
                async let tcaLogs = LogsHandlerClient.exportAndStoreLogsFor(
                    key: tcaLogs,
                    atURL: logsURL.appendingPathComponent("tcaLogs.txt")
                )
                async let walletLogs = LogsHandlerClient.exportAndStoreLogsFor(
                    key: walletLogs,
                    atURL: logsURL.appendingPathComponent("walletLogs.txt")
                )

                let logs = try await [sdkLogsVerbose, sdkLogsSync, tcaLogs, walletLogs]

                // store the log files into the logs folder
                try logs.forEach { logsHandler in
                    try Data(logsHandler.result.utf8).write(to: logsHandler.dir, options: [.completeFileProtection])
                }

                // zip the logs folder
                let coordinator = NSFileCoordinator()
                var zipError: NSError?
                var archiveURL: URL?

                archiveURL = await withCheckedContinuation { continuation in
                    coordinator.coordinate(readingItemAt: logsURL, options: [.forUploading], error: &zipError) { zipURL in
                        do {
                            let tmpURL = exportDirectory.appendingPathComponent("zashiPrivateData.zip")
                            try FileManager.default.moveItem(at: zipURL, to: tmpURL)
                            try FileManager.default.setAttributes(
                                [.protectionKey: FileProtectionType.complete],
                                ofItemAtPath: tmpURL.path
                            )
                            continuation.resume(returning: tmpURL)
                        } catch {
                            continuation.resume(returning: nil)
                        }
                    }
                }

                return archiveURL
            },
            cleanupExports: {
                let rootURL = exportsRootURL()

                if FileManager.default.fileExists(atPath: rootURL.path) {
                    try FileManager.default.removeItem(at: rootURL)
                }

                // Staging directory used by previous app versions, purged here so an
                // update cleans leftovers from before this fix.
                let legacyURL = legacyStagingURL()

                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    try FileManager.default.removeItem(at: legacyURL)
                }
            }
        )
    }

    /// All log exports live under this directory so they can be removed wholesale.
    nonisolated private static func exportsRootURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("logs-exports", isDirectory: true)
    }

    /// Staging directory used before exports moved under `logs-exports`.
    nonisolated private static func legacyStagingURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("zashiPrivateData", isDirectory: true)
    }
}

private extension LogsHandlerClient {
    static func exportAndStoreLogsFor(
        key: String,
        atURL: URL,
        level: OSLogEntryLog.Level = .debug
    ) async throws -> (result: String, dir: URL) {
        let logsStr = try await LogStore.exportCategory(
            key,
            level: level,
            fileSize: 2_000_000 // ~ 2MB of data
        )
        
        var result = ""
        logsStr?.forEach({ line in
            result.append(line)
            result.append("\n\n")
        })
        
        return (result: result, dir: atURL)
    }
}
