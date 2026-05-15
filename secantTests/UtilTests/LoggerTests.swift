//
//  LoggerTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 24.01.2023.
//

import XCTest
import OSLog
@preconcurrency import ZcashLightClientKit
@testable import secant_testnet

class LoggerTests: XCTestCase {
    let timeToPast: TimeInterval = 0.1
    
    func testOSLogger_loggingAndExport() throws {
        let category = "testOSLogger_loggingAndExport"
        let osLogger = OSLogger(logLevel: .debug, category: category)
        let testMessage = "test message"
        
        osLogger.debug(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)
        
        XCTAssertNotNil(logs)
        
        guard let logs else { return }
        
        XCTAssertEqual(logs.count, 1)
        
        let loggedMessage = logs[0].osLoggedMessage()
        
        XCTAssertEqual(testMessage, loggedMessage)
    }
    
    func testOSLogger_DebugLevel_DebugLog() throws {
        let category = "testOSLogger_DebugLevel_DebugLog"
        let osLogger = OSLogger(logLevel: .debug, category: category)
        let testMessage = "debug message"
        
        osLogger.debug(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)
        
        XCTAssertNotNil(logs)
        
        guard let logs else { return }
        
        XCTAssertEqual(logs.count, 1)
        
        let loggedMessage = logs[0].osLoggedMessage()
        
        XCTAssertEqual(testMessage, loggedMessage)
    }
    
    func testOSLogger_ErrorLevel_ErrorLog() throws {
        let category = "testOSLogger_ErrorLevel_ErrorLog"
        let osLogger = OSLogger(logLevel: .debug, category: category)
        let testMessage = "error message"
        
        osLogger.error(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)
        
        XCTAssertNotNil(logs)
        
        guard let logs else { return }
        
        XCTAssertEqual(logs.count, 1)
        
        let loggedMessage = logs[0].osLoggedMessage()
        
        XCTAssertEqual(testMessage, loggedMessage)
    }
    
    func testOSLogger_WarningLevel_WarningLog() throws {
        let category = "testOSLogger_WarningLevel_WarningLog"
        let osLogger = OSLogger(logLevel: .warning, category: category)
        let testMessage = "warning message"
        
        osLogger.warn(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)
        
        XCTAssertNotNil(logs)
        
        guard let logs else { return }
        
        XCTAssertEqual(logs.count, 1)
        
        let loggedMessage = logs[0].osLoggedMessage()
        
        XCTAssertEqual(testMessage, loggedMessage)
    }
    
    func testOSLogger_EventLevel_EventLog() throws {
        let category = "testOSLogger_EventLevel_EventLog"
        let osLogger = OSLogger(logLevel: .event, category: category)
        let testMessage = "event message"
        
        osLogger.event(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)
        
        XCTAssertNotNil(logs)
        
        guard let logs else { return }
        
        XCTAssertEqual(logs.count, 1)
        
        let loggedMessage = logs[0].osLoggedMessage()
        
        XCTAssertEqual(testMessage, loggedMessage)
    }
    
    func testOSLogger_InfoLevel_InfoLog() throws {
        let category = "testOSLogger_InfoLevel_InfoLog"
        let osLogger = OSLogger(logLevel: .info, category: category)
        let testMessage = "info message"
        
        osLogger.info(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)
        
        XCTAssertNotNil(logs)
        
        guard let logs else { return }
        
        XCTAssertEqual(logs.count, 1)
        
        let loggedMessage = logs[0].osLoggedMessage()
        
        XCTAssertEqual(testMessage, loggedMessage)
    }
    
    func testOSLogger_DebugLevel_OtherLogs() throws {
        let category = "testOSLogger_DebugLevel_OtherLogs"
        let osLogger = OSLogger(logLevel: .debug, category: category)
        let testMessage = "debug message"
        
        osLogger.debug(testMessage)
        osLogger.error(testMessage)
        osLogger.warn(testMessage)
        osLogger.event(testMessage)
        osLogger.info(testMessage)
        
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)
        
        guard let logs else { return }
        
        XCTAssertEqual(logs.count, 5)
    }
    
    func testOSLogger_ErrorLevel_OtherLogs() throws {
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
        
        XCTAssertEqual(logs.count, 1)
    }
    
    func testOSLogger_WarningLevel_OtherLogs() throws {
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

        XCTAssertEqual(logs.count, 2)
    }
    
    func testOSLogger_EventLevel_OtherLogs() throws {
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

        XCTAssertEqual(logs.count, 3)
    }
    
    func testOSLogger_InfoLevel_OtherLogs() throws {
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

        XCTAssertEqual(logs.count, 4)
    }
    
    func testWalletLogger() throws {
        let category = "testWalletLogger"
        walletLogger = OSLogger(logLevel: .info, category: category)
        let testMessage = "wallet test message"
        
        LoggerProxy.info(testMessage)
        let logs = TestLogStore.exportCategory(category, hoursToThePast: timeToPast)
        
        XCTAssertNotNil(logs)
        
        guard let logs else { return }
        
        XCTAssertEqual(logs.count, 1)
        
        let loggedMessage = logs[0].osLoggedMessage()
        
        XCTAssertEqual(testMessage, loggedMessage)
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
