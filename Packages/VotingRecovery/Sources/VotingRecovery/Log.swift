import Foundation
import ZcashLightClientKit

/// The module's log lines, forwarded to whatever logger the app registered
/// through `VotingRecovery.configure`. Nothing here ever carries a secret:
/// blinding factors are elided before they reach a message.
enum Log {
    static func debug(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        VotingRecovery.logger()?.debug(message, file: file, function: function, line: line)
    }

    static func info(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        VotingRecovery.logger()?.info(message, file: file, function: function, line: line)
    }

    static func warn(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        VotingRecovery.logger()?.warn(message, file: file, function: function, line: line)
    }

    static func error(_ message: String, file: StaticString = #file, function: StaticString = #function, line: Int = #line) {
        VotingRecovery.logger()?.error(message, file: file, function: function, line: line)
    }
}
