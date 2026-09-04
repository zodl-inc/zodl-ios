#if RECOVERY_VOTING_ENABLED
import Foundation

/// Finds delegation bundles that match a VAN commitment already accepted by
/// the voting chain.
///
/// Recovery is deliberately target-bound. WAL position, database free-space
/// ordering, and the presence of multiple random values are forensic hints,
/// not proof that a candidate is the delegation that landed. An exact
/// `gov_comm == vanCmx` match is required before any bundle is returned.
///
/// The source files are read as bytes and are never opened through SQLite.
enum VotingDatabaseRecovery {
    enum BundleColumn: Int, CaseIterable {
        case roundId = 0
        case walletId = 1
        case bundleIndex = 2
        case notePositions = 3
        case noteIdentityHashes = 4
        case vanCommRand = 5
        case dummyNullifiers = 6
        case rhoSigned = 7
        case paddedNoteData = 8
        case nfSigned = 9
        case cmxNew = 10
        case alpha = 11
        case rseedSigned = 12
        case rseedOutput = 13
        case govComm = 14
        case totalNoteValue = 15
        case addressIndex = 16
        case vanLeafPosition = 17
        case rk = 18
        case govNullifiers = 19
        case paddedNoteSecrets = 20
        case pcztSighash = 21
        case tx1Effects = 22
        case delegationTxHash = 23
    }

    static let bundleColumnCount = BundleColumn.allCases.count
    static let walMagic: Set<UInt32> = [0x377F_0682, 0x377F_0683]

    static let maxMoneyZatoshi: Int64 = 2_100_000_000_000_000

    /// Pallas base-field modulus, encoded big-endian for lexical comparison.
    static let pallasModulus =
        "40000000000000000000000000000000224698fc094cf91b992d30ed00000001"

    enum RecoveryError: Error, Equatable {
        case invalidVanCmxLength(Int)
        case invalidRoundId
    }

    /// Physical provenance for a recovered row.
    enum Source: Equatable, Hashable, Sendable {
        /// A live row in the preserved main database.
        case databaseLive(page: Int)
        /// A record decoded or reconstructed from raw main-database bytes.
        case databaseCarved(page: Int, offset: Int)
        /// A live row in a checksum-valid committed WAL state.
        case walCommit(frame: Int)
        /// A record decoded or reconstructed directly from one WAL page image.
        case walCarved(frame: Int, currentGeneration: Bool, offset: Int)

        /// How much a copy from this place is trusted, highest first. The
        /// same order `deduplicated` uses to keep one row per key.
        var rank: Int {
            switch self {
            case .walCommit: return 4
            case .databaseLive: return 3
            case let .walCarved(_, current, _): return current ? 2 : 1
            case .databaseCarved: return 0
            }
        }

        /// Stable label for logs and the escrow. Never carries row content.
        var label: String {
            switch self {
            case let .databaseLive(page): return "live row on page \(page)"
            case let .databaseCarved(page, offset): return "released bytes on page \(page) at \(offset)"
            case let .walCommit(frame): return "committed log state at frame \(frame)"
            case let .walCarved(frame, current, offset):
                return "log frame \(frame)\(current ? "" : " (stale)") at \(offset)"
            }
        }
    }

    /// One schema-consistent bundle whose stored commitment exactly matches the
    /// requested on-chain VAN.
    struct RecoveredBundle: Equatable, Sendable {
        let roundId: String
        let walletId: String
        let bundleIndex: UInt32
        let notePositionsBlob: Data?
        let noteIdentityHashesBlob: Data?
        let vanCommRand: Data
        let dummyNullifiers: Data?
        let rhoSigned: Data?
        let paddedNoteData: Data?
        let nfSigned: Data?
        let cmxNew: Data?
        let alpha: Data?
        let rseedSigned: Data?
        let rseedOutput: Data?
        let vanCmx: Data
        let totalNoteValue: UInt64
        let addressIndex: UInt32?
        let vanLeafPosition: UInt32?
        let rk: Data?
        let govNullifiersBlob: Data?
        let paddedNoteSecrets: Data?
        let pcztSighash: Data?
        let tx1Effects: Data?
        let delegationTxHash: String?
        let source: Source
    }

    /// An exact occurrence of the target commitment in preserved bytes. A hit
    /// is evidence, but is not returned as a bundle unless the surrounding
    /// fields can also be recovered and validated structurally.
    struct RawTargetHit: Equatable, Hashable, Sendable {
        let source: Source
    }

    struct Report: Equatable, Sendable {
        /// The commitment this scan was bound to, or nil for an untargeted scan.
        let vanCmx: Data?
        let candidates: [RecoveredBundle]
        let rawTargetHits: [RawTargetHit]
        let validWalFrameCount: Int
        let committedWalPrefixCount: Int

        var recovered: Bool { !candidates.isEmpty }
    }

    /// Recovers only bundles matching `vanCmx` from preserved database files.
    ///
    /// `roundId` is required because commitment leaves are round-scoped.
    /// `walletId` and `bundleIndex` are optional additional constraints. Pass
    /// `bundleIndex` when available: SQLite stores the common indices zero and
    /// one entirely in the record header, so a header-damaged raw record cannot
    /// prove either value on its own.
    static func recover(
        databaseURL: URL,
        walURL: URL? = nil,
        vanCmx: Data,
        roundId: String,
        walletId: String? = nil,
        bundleIndex: UInt32? = nil
    ) throws -> Report {
        guard vanCmx.count == 32 else {
            throw RecoveryError.invalidVanCmxLength(vanCmx.count)
        }
        guard isCanonicalRoundId(roundId) else {
            throw RecoveryError.invalidRoundId
        }

        let database = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let wal: Data?
        if let walURL, FileManager.default.fileExists(atPath: walURL.path) {
            wal = try Data(contentsOf: walURL, options: .mappedIfSafe)
        } else {
            wal = nil
        }

        return try recover(
            databaseBytes: [UInt8](database),
            walBytes: wal.map { [UInt8]($0) },
            vanCmx: vanCmx,
            roundId: roundId,
            walletId: walletId,
            bundleIndex: bundleIndex
        )
    }

    static func recover(
        databaseBytes: [UInt8],
        walBytes: [UInt8]? = nil,
        vanCmx: Data,
        roundId: String,
        walletId: String? = nil,
        bundleIndex: UInt32? = nil
    ) throws -> Report {
        guard vanCmx.count == 32 else {
            throw RecoveryError.invalidVanCmxLength(vanCmx.count)
        }
        guard isCanonicalRoundId(roundId) else {
            throw RecoveryError.invalidRoundId
        }
        return try scan(
            databaseBytes: databaseBytes,
            walBytes: walBytes,
            target: vanCmx,
            roundId: roundId,
            walletId: walletId,
            bundleIndex: bundleIndex
        )
    }

    /// Every schema-consistent bundle row in the files, with where each was
    /// found. Nothing is elected: a caller that must choose between two
    /// candidates for one bundle does so with evidence this scan cannot
    /// have, such as the chain's own commitment.
    static func recoverAll(
        databaseBytes: [UInt8],
        walBytes: [UInt8]? = nil,
        roundId: String?,
        walletId: String? = nil
    ) throws -> Report {
        if let roundId, !isCanonicalRoundId(roundId) {
            throw RecoveryError.invalidRoundId
        }
        return try scan(
            databaseBytes: databaseBytes,
            walBytes: walBytes,
            target: nil,
            roundId: roundId,
            walletId: walletId,
            bundleIndex: nil
        )
    }

    static func recoverAll(
        databaseURL: URL,
        walURL: URL? = nil,
        roundId: String?,
        walletId: String? = nil
    ) throws -> Report {
        let database = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let wal: Data? = walURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path)
                ? try? Data(contentsOf: url, options: .mappedIfSafe)
                : nil
        }
        return try recoverAll(
            databaseBytes: [UInt8](database),
            walBytes: wal.map { [UInt8]($0) },
            roundId: roundId,
            walletId: walletId
        )
    }

    /// Shared decoder for both modes. A nil `target` admits every row the
    /// schema accepts; a nil `roundId` drops the round constraint.
    private static func scan(
        databaseBytes: [UInt8],
        walBytes: [UInt8]?,
        target: Data?,
        roundId: String?,
        walletId: String?,
        bundleIndex: UInt32?
    ) throws -> Report {
        let databaseLayout = DatabaseLayout(bytes: databaseBytes)
        let wal = walBytes.flatMap {
            WalFile(bytes: $0, fallbackPageSize: databaseLayout?.pageSize)
        }

        var candidates: [RecoveredBundle] = []
        var templates: [RecordTemplate] = []
        var rawPages: [RawPage] = []

        if let databaseLayout {
            let scan = scanLiveDatabase(
                databaseLayout,
                source: { .databaseLive(page: $0) },
                target: target,
                roundId: roundId,
                walletId: walletId,
                bundleIndex: bundleIndex
            )
            candidates += scan.candidates
            templates += scan.templates

            for page in databaseLayout.pages {
                rawPages.append(
                    RawPage(
                        bytes: page.bytes,
                        headerOffset: page.number == 1 ? 100 : 0,
                        source: { offset in
                            .databaseCarved(page: page.number, offset: offset)
                        }
                    )
                )
            }
        }

        var validWalFrameCount = 0
        var committedWalPrefixCount = 0
        if let wal {
            validWalFrameCount = wal.validFrames.count
            committedWalPrefixCount = wal.validFrames.reduce(into: 0) {
                if $1.databasePageCount > 0 { $0 += 1 }
            }

            for frame in wal.frames {
                rawPages.append(
                    RawPage(
                        bytes: frame.page,
                        headerOffset: 0,
                        source: { offset in
                            .walCarved(
                                frame: frame.index,
                                currentGeneration: frame.isCurrentGeneration,
                                offset: offset
                            )
                        }
                    )
                )
            }

            if let databaseLayout {
                // A WAL can grow the database by at most one page per frame,
                // so any page number past this is not a page this file has.
                let maxPageNumber = databaseLayout.bytes.count / wal.pageSize + wal.frames.count
                var state = databaseLayout.bytes
                for frame in wal.validFrames {
                    guard frame.pageNumber <= maxPageNumber,
                          frame.databasePageCount <= maxPageNumber
                    else { continue }
                    apply(frame: frame, pageSize: wal.pageSize, to: &state)
                    guard frame.databasePageCount > 0 else { continue }

                    resize(
                        database: &state,
                        pageCount: frame.databasePageCount,
                        pageSize: wal.pageSize
                    )
                    guard let committed = DatabaseLayout(bytes: state) else {
                        continue
                    }
                    let scan = scanLiveDatabase(
                        committed,
                        source: { _ in .walCommit(frame: frame.index) },
                        target: target,
                        roundId: roundId,
                        walletId: walletId,
                        bundleIndex: bundleIndex
                    )
                    candidates += scan.candidates
                    templates += scan.templates
                }
            }
        }

        // First collect every decodable schema layout. A damaged record can
        // precede the surviving row that provides its layout template, so
        // anchoring must be a separate pass over the pages.
        for rawPage in rawPages {
            let signatureScan = scanRecordSignatures(
                rawPage,
                target: target,
                roundId: roundId,
                walletId: walletId,
                bundleIndex: bundleIndex
            )
            candidates += signatureScan.candidates
            templates += signatureScan.templates
        }
        templates = Array(Set(templates))

        // Anchoring needs an exact commitment to locate the old body, so it
        // has nothing to do when no target is known.
        var hits: [RawTargetHit] = []
        if let target {
            let needle = [UInt8](target)
            for rawPage in rawPages {
                for offset in offsets(of: needle, in: rawPage.bytes) {
                    let source = rawPage.source(offset)
                    hits.append(RawTargetHit(source: source))
                    candidates += recoverAnchoredRecord(
                        page: rawPage.bytes,
                        targetOffset: offset,
                        templates: templates,
                        source: source,
                        target: target,
                        roundId: roundId,
                        walletId: walletId,
                        bundleIndex: bundleIndex
                    )
                }
            }
        }

        return Report(
            vanCmx: target,
            candidates: deduplicated(candidates),
            rawTargetHits: Array(Set(hits)).sorted(by: rawHitOrder),
            validWalFrameCount: validWalFrameCount,
            committedWalPrefixCount: committedWalPrefixCount
        )
    }
}

// `Data.hexString` is declared once for the voting flavor in
// `VotingCryptoClientLiveKey.swift` and reused here.
#endif
