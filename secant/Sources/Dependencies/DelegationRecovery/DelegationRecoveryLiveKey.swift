#if RECOVERY_VOTING_ENABLED
import ComposableArchitecture
import Foundation

extension DelegationRecoveryClient: DependencyKey {
    /// One place a recoverable copy of the voting database can be found.
    ///
    /// Ordered by trust, highest first. Trust here means "how likely is this
    /// copy to still hold the pre-wipe page images", which is decided by how
    /// much SQLite has been allowed to do to it since the incident.
    struct Source: Equatable, Sendable {
        /// Short label for the log line. Never shown to the user.
        let name: String
        let databaseURL: URL
        let walURL: URL

        init(name: String, databaseURL: URL) {
            self.name = name
            self.databaseURL = databaseURL
            // SQLite names its sidecars by path suffix, not path extension.
            self.walURL = databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent(databaseURL.lastPathComponent + "-wal")
        }
    }

    /// Every copy of the voting database on the device, best first.
    ///
    /// Copies are discovered under Documents rather than listed, so a `.bak`
    /// beside the live file or a set kept under another name is carved too.
    ///
    /// The order is trust: how likely the copy still holds the superseded
    /// page images, which is decided by how much SQLite has done to it since.
    ///
    /// 1. `voting_recovery/`, copied before anything opened the database.
    /// 2. Any other copy under Documents. Older than the live file, and
    ///    unopened since it was made.
    /// 3. The live `Documents/voting.sqlite3` last. Its log has almost
    ///    certainly been checkpointed, but this SQLite is not built with
    ///    `SQLITE_SECURE_DELETE`, so deleted rows survive in freed pages,
    ///    freeblocks and the unallocated gap.
    ///
    /// A database restored from a backup needs no case of its own: the
    /// preserved set and the live database are both backup-eligible, so a
    /// migrated device presents them at these same paths.
    static func sources(includingAbsent: Bool) -> [Source] {
        let fileManager = FileManager.default
        guard let documents = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
        else {
            return []
        }

        let preservedRoot = try? VotingDatabaseSnapshot.recoveryDirectory()
        let live = documents.appendingPathComponent(VotingDatabaseSnapshot.databaseName)

        var seen: Set<String> = []
        var sources: [Source] = []

        func add(_ url: URL, name: String) {
            // Two paths can name one file, so compare resolved paths.
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            sources.append(Source(name: name, databaseURL: url))
        }

        // 1. The preserved set, canonical name first.
        if let preservedRoot {
            add(
                preservedRoot.appendingPathComponent(VotingDatabaseSnapshot.databaseName),
                name: "preserved"
            )
        }

        // 2. Everything else that looks like a voting database, anywhere under
        //    Documents. Sorted so a run is reproducible and the log reads the
        //    same twice.
        for url in votingDatabases(under: documents).sorted(by: {
            $0.standardizedFileURL.path < $1.standardizedFileURL.path
        }) where url.standardizedFileURL.path != live.standardizedFileURL.path {
            add(url, name: label(for: url, relativeTo: documents))
        }

        // 3. The live database last.
        add(live, name: "live")

        return sources
    }

    /// Files under `root` that really are a voting database.
    ///
    /// Two limits, both learned from a test that carved a file it had just
    /// moved aside:
    ///
    /// - DEPTH. Only the Documents root and one level below it. A voting
    ///   database lives beside the app's own files or in a directory someone
    ///   made to hold a copy; nothing legitimate buries one deeper, and an
    ///   unbounded walk turns every stray file in the container into a
    ///   recovery source.
    /// - CONTENT. The name only selects candidates; the SQLite magic decides.
    ///   Matching on a name alone means anything called `voting-something.db`
    ///   is carved, whatever it actually is.
    ///
    /// `-wal` and `-shm` are excluded so a sidecar is only ever reached
    /// through its own database.
    static func votingDatabases(under root: URL) -> [URL] {
        let fileManager = FileManager.default

        func candidates(in directory: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        var found: [URL] = []
        var toInspect = candidates(in: root)
        for url in candidates(in: root) where isDirectory(url) {
            toInspect += candidates(in: url)
        }

        for url in toInspect {
            let name = url.lastPathComponent.lowercased()
            guard name.contains("voting"),
                  name.contains("sqlite") || name.hasSuffix(".db"),
                  !name.hasSuffix("-wal"),
                  !name.hasSuffix("-shm"),
                  !isDirectory(url),
                  looksLikeSQLite(url)
            else {
                continue
            }
            found.append(url)
        }
        return found
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static let sqliteMagic = Array("SQLite format 3\u{0}".utf8)
    /// A write-ahead log of exactly this size holds no frames.
    private static let walHeaderLength = 32

    /// Reads the 16-byte SQLite magic, and nothing more. A name is a guess; a
    /// header is evidence.
    private static func looksLikeSQLite(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: sqliteMagic.count) else {
            return false
        }
        return Array(head) == sqliteMagic
    }

    /// A short, stable label naming WHICH file a log line is about: the path
    /// relative to Documents, so `voting_recovery/voting.sqlite3.bak` reads as
    /// itself rather than as an anonymous "copy 3".
    static func label(for url: URL, relativeTo documents: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = documents.standardizedFileURL.path
        if full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1))
        }
        return url.lastPathComponent
    }


    /// Every line this subsystem emits carries the same prefix, so the whole
    /// run can be isolated in the Xcode console by filtering on "poll-recovery".
    ///
    /// Values are logged ELIDED. These lines reach os_log and the app's own
    /// log export, and `van_comm_rand` is the one secret in the system that
    /// cannot be regenerated, so it must not be written out in full.
    static func log(_ message: String) {
        LoggerProxy.info("[poll-recovery] \(message)")
    }

    /// Keeps both ends of a hex value and drops the middle.
    ///
    /// Not only for brevity: the two generations in the test fixtures differ
    /// in the LAST byte, so an elision keeping only a prefix would render them
    /// identical and make the log useless for telling them apart.
    static func elide(_ data: Data) -> String {
        let hex = data.hexString
        guard hex.count > 16 else { return hex }
        return "\(hex.prefix(6))...\(hex.suffix(6))"
    }

    /// Byte size, or 0 when the file is not there. For the log only, so a
    /// missing file reads as 0 rather than failing a run.
    static func fileSize(_ url: URL) -> Int {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.intValue
    }

    /// The copies that actually hold data, which is what a run carves.
    /// `sources(includingAbsent:)` keeps the empty ones too, so a caller can
    /// report what is missing rather than silently omitting it.
    static func sources() -> [Source] {
        sources(includingAbsent: true)
            .filter { VotingDatabaseSnapshot.holdsData(at: $0.databaseURL) }
    }

    /// When `VotingDatabaseSnapshot` took the preserved set, read from the
    /// marker it writes beside the copy.
    ///
    /// The capture stores the database under a FIXED name and records the time
    /// in a separate `captured-yyyyMMdd-HHmmss.txt` marker, so the age of the
    /// copy is knowable only from that file. Age is the fact worth having, and
    /// it reads backwards: the copy is taken before anything opens the
    /// database, so an OLD capture is good news, being the one closest to the
    /// incident and least likely to have been checkpointed.
    static func captureTime(inPreservedDirectory root: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        guard let marker = names
            .filter({ $0.hasPrefix("captured-") && $0.hasSuffix(".txt") })
            .sorted()
            .last
        else {
            return nil
        }
        return String(marker.dropFirst("captured-".count).dropLast(".txt".count))
    }

    static var liveValue: Self {
        Self(
            run: {
                @Dependency(\.delegationEscrow) var delegationEscrow

                log("RUN requested")
                let sources = Self.sources()
                guard !sources.isEmpty else {
                    log("RUN aborted: no voting database holds data")
                    return DelegationRecoveryReport(outcome: .noSnapshot)
                }
                log("RUN over \(sources.count) copy/copies, best first:")
                let preservedRoot = try? VotingDatabaseSnapshot.recoveryDirectory()
                for source in sources {
                    let wal = fileSize(source.walURL)
                    // Only a preserved set carries a capture marker, and its
                    // age is the useful fact: the copy is taken before
                    // anything opens the database, so an OLD one is the good
                    // one, closest to the incident.
                    let captured = preservedRoot.flatMap { root -> String? in
                        source.databaseURL.standardizedFileURL.path
                            .hasPrefix(root.standardizedFileURL.path + "/")
                            ? captureTime(inPreservedDirectory: root)
                            : nil
                    }
                    log(
                        "  - \(source.name): db \(fileSize(source.databaseURL))B, wal \(wal)B"
                        + (captured.map { ", captured \($0) UTC" } ?? "")
                        + (wal <= Self.walHeaderLength
                            ? " (log header-only: nothing superseded left in it)"
                            : "")
                    )
                }

                // Every schema-consistent row goes to the escrow with where it
                // was found. Nothing is elected here: which copy is the
                // original is decided at restore time, by the transaction hash
                // and, in the end, by the chain.
                var report = DelegationRecoveryReport(outcome: .recovered)
                var rounds: Set<String> = []
                var bundles: Set<String> = []
                var escrowFailed = false
                var readFailed = false

                for source in sources {
                    let found: VotingDatabaseRecovery.Report
                    do {
                        found = try VotingDatabaseRecovery.recoverAll(
                            databaseURL: source.databaseURL,
                            walURL: source.walURL,
                            roundId: nil,
                            walletId: nil
                        )
                    } catch {
                        // A source that cannot be read is not fatal: another
                        // may still hold the value. The live database in
                        // particular can be mid-write while this runs.
                        LoggerProxy.error(
                            "[poll-recovery] could not read source \(source.name): \(error)"
                        )
                        readFailed = true
                        continue
                    }
                    report.sourcesScanned += 1
                    log(
                        "  [\(source.name)] \(found.candidates.count) candidate(s), \(found.validWalFrameCount) valid log frame(s)"
                    )

                    for candidate in found.candidates {
                        let key = "\(candidate.roundId)/\(candidate.bundleIndex)"
                        do {
                            try await delegationEscrow.record(
                                DelegationEscrowEntry(
                                    roundId: candidate.roundId,
                                    bundleIndex: candidate.bundleIndex,
                                    vanCommRand: candidate.vanCommRand,
                                    van: candidate.vanCmx,
                                    totalNoteValue: candidate.totalNoteValue,
                                    delegationTxHash: candidate.delegationTxHash,
                                    source: .recovered,
                                    createdAt: Date(),
                                    walletId: candidate.walletId,
                                    addressIndex: candidate.addressIndex ?? 0,
                                    vanLeafPosition: candidate.vanLeafPosition,
                                    provenance: "\(source.name): \(candidate.source.label)",
                                    provenanceRank: candidate.source.rank
                                )
                            )
                        } catch {
                            // Keep going. Every one of these is irreplaceable, so
                            // one unwritable entry must not abandon the rest.
                            LoggerProxy.error(
                                "[poll-recovery] could not escrow \(key): \(error)"
                            )
                            escrowFailed = true
                            continue
                        }
                        report.candidatesEscrowed += 1
                        rounds.insert(candidate.roundId)
                        bundles.insert(key)
                        // The hash decides whether this candidate is a complete
                        // capability record, so a support log that omits it
                        // cannot answer the first question anyone asks.
                        let tx = candidate.delegationTxHash.map { "tx \($0.prefix(8))" }
                            ?? "no tx hash"
                        let provenance = "[\(source.name)] \(candidate.source.label)"
                        log("    ESCROWED \(key) = \(elide(candidate.vanCommRand)) from \(provenance), \(tx)")
                    }
                }

                report.rounds = rounds.count
                report.bundles = bundles.count
                if escrowFailed || (readFailed && report.sourcesScanned == 0) {
                    report.outcome = .failed
                } else if report.candidatesEscrowed == 0 {
                    report.outcome = .nothingToRecover
                }

                let summary = "candidates=\(report.candidatesEscrowed) across \(report.bundles) bundle(s) in \(report.rounds) round(s)"
                log("RUN finished over \(report.sourcesScanned) source(s): outcome=\(report.outcome), \(summary)")
                return report
            }
        )
    }
}
#endif
