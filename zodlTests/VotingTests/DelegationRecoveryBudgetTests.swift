import Foundation
import Testing
@testable import zodl_internal
@testable import VotingRecovery

/// A launch-time run reads each copy in full, so a copy past the budget is
/// left unread rather than risking the process.
@Suite struct DelegationRecoveryBudgetTests {
    private func temporaryCopy(databaseBytes: Int, walBytes: Int) throws -> DelegationRecoveryClient.Source {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = DelegationRecoveryClient.Source(
            name: "temporary",
            databaseURL: directory.appendingPathComponent("voting.sqlite3")
        )
        for (url, bytes) in [(source.databaseURL, databaseBytes), (source.walURL, walBytes)] {
            // A sparse file has the size without the bytes, which is all the
            // budget looks at.
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        }
        return source
    }

    @Test func aSmallCopyIsWithinBudget() throws {
        let source = try temporaryCopy(databaseBytes: 4096, walBytes: 32)
        #expect(DelegationRecoveryClient.withinBudget(source))
    }

    @Test func aCopyAtTheBudgetIsStillRead() throws {
        let source = try temporaryCopy(databaseBytes: DelegationRecoveryClient.sourceByteBudget, walBytes: 0)
        #expect(DelegationRecoveryClient.withinBudget(source))
    }

    @Test func aCopyOverTheBudgetIsSkipped() throws {
        let source = try temporaryCopy(databaseBytes: DelegationRecoveryClient.sourceByteBudget, walBytes: 1)
        #expect(DelegationRecoveryClient.withinBudget(source) == false)
    }

    @Test func aMissingLogCountsAsEmpty() throws {
        let source = try temporaryCopy(databaseBytes: 4096, walBytes: 0)
        try FileManager.default.removeItem(at: source.walURL)
        #expect(DelegationRecoveryClient.withinBudget(source))
    }
}
