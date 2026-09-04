#if RECOVERY_VOTING_ENABLED
import Foundation

// MARK: - Raw page carving

extension VotingDatabaseRecovery {
    struct RawPage {
        let bytes: [UInt8]
        let headerOffset: Int
        let source: (Int) -> Source
    }

    static func scanRecordSignatures(
        _ page: RawPage,
        target: Data?,
        roundId: String?,
        walletId: String?,
        bundleIndex: UInt32?
    ) -> ScanResult {
        var result = ScanResult()
        var index = max(1, page.headerOffset)

        while index + 1 < page.bytes.count {
            guard page.bytes[index] == 0x81,
                  page.bytes[index + 1] == 0x0D
            else {
                index += 1
                continue
            }

            let payloadStart = index - 1
            if let record = decodeRecord(
                Array(page.bytes[payloadStart..<page.bytes.count])
            ) {
                append(
                    record: record,
                    source: page.source(payloadStart),
                    target: target,
                    roundId: roundId,
                    walletId: walletId,
                    bundleIndex: bundleIndex,
                    to: &result
                )
            }
            index += 1
        }
        return result
    }

    /// Uses the body layout of a surviving bundle as a template when SQLite has
    /// overwritten the deleted cell header but left its column bytes intact.
    /// The exact target VAN anchors the old body's location.
    static func recoverAnchoredRecord(
        page: [UInt8],
        targetOffset: Int,
        templates: [RecordTemplate],
        source: Source,
        target: Data,
        roundId: String?,
        walletId: String?,
        bundleIndex: UInt32?
    ) -> [RecoveredBundle] {
        var candidates: [RecoveredBundle] = []

        for template in templates {
            let govIndex = BundleColumn.govComm.rawValue
            guard template.spans.indices.contains(govIndex) else { continue }
            let govSpan = template.spans[govIndex]
            guard govSpan.range.count == target.count else { continue }

            let payloadStart = targetOffset - govSpan.range.lowerBound
            guard payloadStart >= 0 else { continue }

            var values: [RecordValue] = []
            for (columnIndex, span) in template.spans.enumerated() {
                if columnIndex == BundleColumn.bundleIndex.rawValue,
                   let bundleIndex {
                    values.append(.integer(Int64(bundleIndex)))
                    continue
                }
                // Serial types 8 and 9 encode integer 0/1 entirely in the
                // destroyed record header. A layout template cannot prove
                // which value the deleted row used.
                if span.range.isEmpty, span.serialType == 8 || span.serialType == 9 {
                    values.append(.unavailable)
                    continue
                }
                let lower = payloadStart + span.range.lowerBound
                let upper = payloadStart + span.range.upperBound
                guard lower >= 0, upper <= page.count else {
                    values.append(.unavailable)
                    continue
                }
                values.append(
                    serialValue(span.serialType, Array(page[lower..<upper]))
                )
            }

            guard let bundle = makeBundle(values: values, source: source),
                  bundle.vanCmx == target,
                  matches(
                      bundle,
                      roundId: roundId,
                      walletId: walletId,
                      bundleIndex: bundleIndex
                  )
            else {
                continue
            }
            candidates.append(bundle)
        }
        return candidates
    }

    static func offsets(of needle: [UInt8], in bytes: [UInt8]) -> [Int] {
        guard !needle.isEmpty, bytes.count >= needle.count else { return [] }
        var matches: [Int] = []
        var offset = 0
        let finalOffset = bytes.count - needle.count

        while offset <= finalOffset {
            if bytes[offset..<(offset + needle.count)].elementsEqual(needle) {
                matches.append(offset)
                offset += needle.count
            } else {
                offset += 1
            }
        }
        return matches
    }
}
#endif
