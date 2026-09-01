#if VOTING_ENABLED
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

    /// Every copy worth carving, best first.
    ///
    /// 1. The preserved set under `voting_recovery/`. Copied before anything
    ///    opened the database, so its write-ahead log is the only place a
    ///    freshly cleared round survives whole.
    /// 2. Any further `*.sqlite3` preserved alongside it. Only one set is kept
    ///    today, but a build that ever keeps more should not need a change
    ///    here to have them read.
    /// 3. The live `Documents/voting.sqlite3`. Its log has almost certainly
    ///    been checkpointed away by now, but a checkpoint does not zero the
    ///    cells it releases: this build of SQLite is not compiled with
    ///    `SQLITE_SECURE_DELETE`, so deleted rows survive in freed pages, in
    ///    freeblocks, and in the unallocated gap.
    ///
    /// A database restored from an iCloud or device backup needs no case of
    /// its own: both the preserved set and the live database are deliberately
    /// left backup-eligible, so a migrated device presents them at exactly
    /// these paths.
    static func sources(includingAbsent: Bool) -> [Source] {
        var sources: [Source] = []
        let fileManager = FileManager.default

        if let root = try? VotingDatabaseSnapshot.recoveryDirectory() {
            let preserved = root
                .appendingPathComponent(VotingDatabaseSnapshot.databaseName)
            sources.append(Source(name: "preserved", databaseURL: preserved))

            // Sorted so a run is reproducible, and so the report's counts do
            // not depend on directory enumeration order.
            let siblings = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )) ?? []
            for url in siblings.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension == "sqlite3" && url != preserved {
                sources.append(
                    Source(name: "preserved/\(url.lastPathComponent)", databaseURL: url)
                )
            }
        }

        if let documents = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first {
            sources.append(
                Source(
                    name: "live",
                    databaseURL: documents.appendingPathComponent("voting.sqlite3")
                )
            )
        }

        return sources
    }

    /// Copies that actually hold data. `run` uses this; the diagnostics screen
    /// asks for the unfiltered list so it can show what is missing too.
    static func sources() -> [Source] {
        sources(includingAbsent: true)
            .filter { VotingDatabaseSnapshot.holdsData(at: $0.databaseURL) }
    }



    /// Every line this subsystem emits carries the same prefix, so the whole
    /// run can be isolated in the Xcode console by filtering on "poll-recovery".
    ///
    /// Values are logged ELIDED, exactly as they are shown on screen. These
    /// logs reach os_log and the app's own log export, and `van_comm_rand` is
    /// the one secret in the system that cannot be regenerated, so it must not
    /// be written out in full.
    static func log(_ message: String) {
        LoggerProxy.info("[poll-recovery] \(message)")
    }

    /// Keeps both ends of a hex value and drops the middle.
    ///
    /// Not only for brevity: the two generations in the test fixtures differ
    /// in the LAST byte, so an elision that kept only a prefix would render
    /// them identical and make the screen useless for the thing it exists to
    /// show.
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
                log("RUN over \(sources.count) copy/copies: \(sources.map(\.name).joined(separator: ", "))")

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
                            log("    take \(key) from \(describe(original.origin))")
                        } else {
                            log("    skip \(key), a more trusted copy already supplied it")
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
                    log("    ESCROWED \(key) = \(elide(original.vanCommRand))")

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
                    "RUN finished over \(scanned) source(s): outcome=\(report.outcome), "
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
