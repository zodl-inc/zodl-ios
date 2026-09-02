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

    /// Reads the 16-byte SQLite magic, and nothing more. A name is a guess; a
    /// header is evidence.
    private static func looksLikeSQLite(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: DelegationWalRecovery.Format.magic.count)
        else {
            return false
        }
        return Array(head) == DelegationWalRecovery.Format.magic
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

    static func describe(_ origin: DelegationWalRecovery.Origin) -> String {
        switch origin {
        case .databaseFreeSpace: return "released space"
        case .databaseLive: return "live row"
        case let .walFrame(index): return "log frame \(index)"
        }
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
                        + (wal <= DelegationWalRecovery.Format.walHeaderLength
                            ? " (log header-only: nothing superseded left in it)"
                            : "")
                    )
                }

                // The cheap early-out. A wallet that never opened a poll has no
                // round, so nothing can have been lost and there is no reason to
                // carve anything. Presence is NOT health: a wiped round was
                // rebuilt, so it is present too. This only decides whether it is
                // worth looking; `plan` decides what was found.
                let holdsRoundData = sources.contains { source in
                    (try? DelegationWalRecovery.holdsRoundData(
                        databaseURL: source.databaseURL,
                        walURL: source.walURL
                    )) == true
                }
                guard holdsRoundData else {
                    log("RUN skipped: no voting round on this device, nothing can have been lost")
                    return DelegationRecoveryReport(outcome: .nothingToRecover)
                }
                log("round data present, carving")

                // Keyed by bundle, holding the oldest surviving copy found in
                // the most trusted source that had one.
                //
                // Each source is planned INDEPENDENTLY and only the results are
                // merged. `Origin` orders copies within ONE file: released
                // space precedes live rows, which precede log frames, because
                // the file holds the last checkpointed state. Across files that
                // order means nothing, so pooling raw rows would rank a
                // preserved log frame above the live database's current row and
                // invert original and replacement.
                var originals: [String: DelegationWalRecovery.RecoveredBundle] = [:]
                var scanned = 0
                var readFailed = false

                for source in sources {
                    let plan: DelegationWalRecovery.Plan
                    do {
                        plan = try DelegationWalRecovery.plan(
                            databaseURL: source.databaseURL,
                            walURL: source.walURL
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

                    scanned += 1
                    guard plan.needsRecovery else {
                        log("  [\(source.name)] nothing to restore")
                        continue
                    }
                    log("  [\(source.name)] proposes \(plan.replacements.count) replacement(s)")

                    for replacement in plan.replacements {
                        let original = replacement.original
                        let key = "\(original.roundId)/\(original.bundleIndex)"
                        // First writer wins: sources are in descending trust.
                        if originals[key] == nil {
                            originals[key] = original
                            log(
                                "    take \(key) from [\(source.name)] "
                                + describe(original.origin)
                            )
                        } else {
                            log(
                                "    skip \(key) in [\(source.name)], "
                                + "a more trusted copy already supplied it"
                            )
                        }
                    }
                }

                var report = DelegationRecoveryReport(outcome: .recovered)
                report.sourcesScanned = scanned
                var rounds: Set<String> = []
                var escrowFailed = false

                for key in originals.keys.sorted() {
                    guard let original = originals[key] else { continue }

                    // The carver matches on record shape, so a byte pattern in
                    // released space can decode into a plausible-looking row. A
                    // real blinding factor is a canonical Pallas base field
                    // element; anything else never was one and must not enter
                    // the escrow dressed as one.
                    guard DelegationWalRecovery
                        .isCanonicalPallasElement(original.vanCommRand) else {
                        report.bundlesRejected += 1
                        log("    REJECT \(key): not a canonical Pallas element")
                        continue
                    }

                    do {
                        try await delegationEscrow.record(
                            DelegationEscrowEntry(
                                roundId: original.roundId,
                                bundleIndex: original.bundleIndex,
                                vanCommRand: original.vanCommRand,
                                van: original.van,
                                totalNoteValue: original.totalNoteValue,
                                delegationTxHash: original.delegationTxHash,
                                source: .recovered,
                                createdAt: Date()
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
                    // The hash decides whether this entry is a complete
                    // capability record, so a support log that omits it
                    // cannot answer the first question anyone asks.
                    let tx = original.delegationTxHash.map { "tx \($0.prefix(8))" }
                        ?? "no tx hash"
                    log("    ESCROWED \(key) = \(elide(original.vanCommRand)), \(tx)")

                    report.bundlesEscrowed += 1
                    if original.van.isEmpty {
                        report.bundlesWithoutVan += 1
                    }
                    rounds.insert(original.roundId)
                }

                report.rounds = rounds.count

                if escrowFailed || (readFailed && report.bundlesEscrowed == 0 && scanned == 0) {
                    report.outcome = .failed
                } else if report.bundlesEscrowed == 0 {
                    // Either no source proposed anything, or every candidate
                    // failed admission. Nothing was recovered either way.
                    report.outcome = .nothingToRecover
                }

                log(
                    "RUN finished over \(report.sourcesScanned) source(s): outcome=\(report.outcome), "
                    + "escrowed=\(report.bundlesEscrowed) across \(report.rounds) round(s), "
                    + "rejected=\(report.bundlesRejected), "
                    + "withoutCommitment=\(report.bundlesWithoutVan)"
                )
                return report
            }
        )
    }
}
#endif
