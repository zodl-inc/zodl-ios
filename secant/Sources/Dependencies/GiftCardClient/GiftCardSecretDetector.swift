//
//  GiftCardSecretDetector.swift
//  Zodl
//
//  Created by Zodl on 2026-10-06.
//

import Foundation

/// The last line of defence that keeps gift card secrets away from places that send or store an
/// address: swap and pay requests, and contacts.
///
/// `GiftCardLink.isCandidate` routes text that starts with a gift card link to the redeem flow.
/// This check is wider: it looks anywhere in the text and sees through the ways a link can be
/// disguised on its way in: text around it (a whole pasted message), invisible or format
/// characters (zero-width spaces, a byte order mark, bidi controls, soft hyphens), whitespace
/// inside it, compatibility forms such as full-width letters, another scheme or no scheme at all,
/// and percent-encoding, even repeated.
///
/// False positives are acceptable: no real swap or Zcash address contains a gift card host or a
/// gift card key's human-readable part, so text that does is refused rather than risk sending a
/// spending secret off the device. Nothing here logs or keeps the text.
enum GiftCardSecretDetector {
    /// What any gift card link or key contains, compared ignoring case.
    static let markers = [
        "gift.zodl.com",
        "link.vizor.cash/payment-links",
        "zgift1",
        "zgifttest1"
    ]

    /// How many rounds of percent-decoding are undone at most.
    static let maxDecodeRounds = 5

    /// Whether `text` contains, or may contain, a gift card link or a gift card key anywhere in it.
    static func mayContainGiftCardSecret(_ text: String) -> Bool {
        var current = canonical(text)
        for _ in 0...maxDecodeRounds {
            if markers.contains(where: { current.contains($0) }) {
                return true
            }
            let decoded = canonical(percentDecoded(current))
            guard decoded != current else {
                return false
            }
            current = decoded
        }
        return false
    }

    /// The text in compatibility-normalized form (NFKC, which folds e.g. full-width letters into
    /// ASCII), lowercased, without format characters (Unicode category Cf: zero-width spaces and
    /// joiners, the byte order mark, bidi controls, soft hyphens, word joiners and invisible
    /// operators) and without whitespace.
    static func canonical(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars
        where scalar.properties.generalCategory != .format && !scalar.properties.isWhitespace {
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
    }

    /// One round of percent-decoding as UTF-8. A `%` not followed by two hex digits is kept as it
    /// is, and bytes that are not valid UTF-8 decode to the replacement character, so malformed
    /// input never fails.
    static func percentDecoded(_ text: String) -> String {
        guard text.contains("%") else {
            return text
        }
        let bytes = Array(text.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(bytes[index])
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
