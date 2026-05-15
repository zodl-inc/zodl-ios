//
//  WalletLogger.swift
//  Zashi
//
//  Created by Lukáš Korba on 23.01.2023.
//

import Foundation
@preconcurrency import ZcashLightClientKit
import os

enum LoggerConstants {
    static let sdkLogs = "sdkLogs_default"
    static let tcaLogs = "tcaLogs"
    static let walletLogs = "walletLogs"
}

var walletLogger: ZcashLightClientKit.Logger?

enum LoggerProxy {
    static func debug(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        walletLogger?.debug(message, file: file, function: function, line: line)
    }
    
    static func info(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        walletLogger?.info(message, file: file, function: function, line: line)
    }
    
    static func event(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        walletLogger?.event(message, file: file, function: function, line: line)
    }
    
    static func warn(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        walletLogger?.warn(message, file: file, function: function, line: line)
    }
    
    static func error(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        walletLogger?.error(message, file: file, function: function, line: line)
    }
}
