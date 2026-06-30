//
//  LoggerTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 24.01.2023.
//

import Testing
import OSLog
@preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// Logs are written to and read back from the process-global OSLog store, so the
// suite is serialized to avoid concurrent writers/readers racing the shared store.
@Suite(.serialized) struct LoggerTests {
    let timeToPast: TimeInterval = 0.1

    // NOTE: Tests that exercise `.debug` log-level entries are intentionally
    // omitted. On a fresh CI simulator without an active OSLog subsystem
    // profile, `.debug` entries are not retained by `OSLogStore`, which makes
    // those tests flaky (pass after Xcode's auto-retry, fail on first attempt).
    // The remaining tests cover `.error / .warning / .event / .info`, which
    // are all persisted by default and run reliably in any environment.

    @Test func osLogger_ErrorLevel_ErrorLog() throws {
        let category = "testOSLogger_ErrorLevel_ErrorLog"
        let osLogger = OSLogger(logLevel: .debug, category: category)
        let testMessage = "error message"

        osLogger.error(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        #expect(logs != nil)

        guard let logs else { return }

        #expect(logs.contains { $0.osLoggedMessage() == testMessage })
    }

    @Test func osLogger_WarningLevel_WarningLog() throws {
        let category = "testOSLogger_WarningLevel_WarningLog"
        let osLogger = OSLogger(logLevel: .warning, category: category)
        let testMessage = "warning message"

        osLogger.warn(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        #expect(logs != nil)

        guard let logs else { return }

        #expect(logs.contains { $0.osLoggedMessage() == testMessage })
    }

    @Test func osLogger_EventLevel_EventLog() throws {
        let category = "testOSLogger_EventLevel_EventLog"
        let osLogger = OSLogger(logLevel: .event, category: category)
        let testMessage = "event message"

        osLogger.event(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        #expect(logs != nil)

        guard let logs else { return }

        #expect(logs.contains { $0.osLoggedMessage() == testMessage })
    }

    @Test func osLogger_InfoLevel_InfoLog() throws {
        let category = "testOSLogger_InfoLevel_InfoLog"
        let osLogger = OSLogger(logLevel: .info, category: category)
        let testMessage = "info message"

        osLogger.info(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        #expect(logs != nil)

        guard let logs else { return }

        #expect(logs.contains { $0.osLoggedMessage() == testMessage })
    }

    @Test func osLogger_ErrorLevel_OtherLogs() throws {
        let category = "testOSLogger_ErrorLevel_OtherLogs"
        let osLogger = OSLogger(logLevel: .error, category: category)
        let testMessage = "debug message"

        osLogger.debug(testMessage)
        osLogger.error(testMessage)
        osLogger.warn(testMessage)
        osLogger.event(testMessage)
        osLogger.info(testMessage)

        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        guard let logs else { return }

        #expect(logs.count == 1)
    }

    @Test func osLogger_WarningLevel_OtherLogs() throws {
        let category = "testOSLogger_WarningLevel_OtherLogs"
        let osLogger = OSLogger(logLevel: .warning, category: category)
        let testMessage = "debug message"

        osLogger.debug(testMessage)
        osLogger.error(testMessage)
        osLogger.warn(testMessage)
        osLogger.event(testMessage)
        osLogger.info(testMessage)

        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        guard let logs else { return }

        #expect(logs.count == 2)
    }

    @Test func osLogger_EventLevel_OtherLogs() throws {
        let category = "testOSLogger_EventLevel_OtherLogs"
        let osLogger = OSLogger(logLevel: .event, category: category)
        let testMessage = "debug message"

        osLogger.debug(testMessage)
        osLogger.error(testMessage)
        osLogger.warn(testMessage)
        osLogger.event(testMessage)
        osLogger.info(testMessage)

        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        guard let logs else { return }

        #expect(logs.count == 3)
    }

    @Test func osLogger_InfoLevel_OtherLogs() throws {
        let category = "testOSLogger_InfoLevel_OtherLogs"
        let osLogger = OSLogger(logLevel: .info, category: category)
        let testMessage = "debug message"

        osLogger.debug(testMessage)
        osLogger.error(testMessage)
        osLogger.warn(testMessage)
        osLogger.event(testMessage)
        osLogger.info(testMessage)

        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        guard let logs else { return }

        #expect(logs.count == 4)
    }

    @Test func walletLoggerLogsViaProxy() throws {
        let category = "testWalletLogger"
        walletLogger = OSLogger(logLevel: .info, category: category)
        // Restore the process-global so other suites' LoggerProxy
        // calls don't keep landing in this test's category.
        defer { walletLogger = nil }
        let testMessage = "wallet test message"

        LoggerProxy.info(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)

        #expect(logs != nil)

        guard let logs else { return }

        // walletLogger is process-global. While this test holds it set
        // to "testWalletLogger", any *parallel* suite that calls
        // LoggerProxy.info (ServerHealthTracker, VotingAPIClient, the
        // background-task client, etc.) will race-write into the same
        // OSLog category. @Suite(.serialized) only serializes within
        // this suite, not across the bundle — observed on CI as
        // logs.count == 7 instead of 1.
        //
        // Assert the proxy delivered OUR message instead of demanding
        // exclusive bucket ownership we can't enforce.
        #expect(logs.count >= 1)
        #expect(logs.contains { $0.osLoggedMessage() == testMessage })
    }
}

extension String {
    func osLoggedMessage() -> String? {
        let split = components(separatedBy: "-> ")

        if split.count == 2 {
            return split[1]
        }

        return nil
    }
}

enum TestLogStore {
    static func exportCategory(_ category: String, hoursToThePast: TimeInterval = 24) -> [String]? {
        guard let bundle = Bundle.main.bundleIdentifier else { return nil }

        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let date = Date.now.addingTimeInterval(-hoursToThePast * 3600)
            let position = store.position(date: date)
            var entries: [String] = []

            entries = try store
                .getEntries(at: position)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == bundle && $0.category == category }
                .map { "[\($0.date.formatted())] \($0.composedMessage)" }

            return entries
        } catch {
            return nil
        }
    }
}
