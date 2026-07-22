//
//  KeystoneFirmwareVersion.swift
//  Zashi
//
//  MOB-1510: Keystone hardware-wallet firmware version, read off a signed PCZT's proprietary
//  fields. KeystoneSDK 0.8.6 exposes no firmware API of its own — device firmware
//  (KeystoneHQ/keystone3-firmware#2134, shipped in releases >= 2.4.6) stamps
//  `global.proprietary["keystone:fw_version"]` (3 raw bytes: major, minor, build) into every Zcash
//  PCZT it signs, so the app reads the version back out of the raw signed bytes instead of calling
//  into the vendor SDK.
//

import Foundation

struct KeystoneFirmwareVersion: Equatable, Comparable, Sendable {
    let major: Int
    let minor: Int
    let build: Int

    /// Minimum Keystone firmware this app will accept a signature from — set by product
    /// (MOB-1510). Single point of change if the minimum is ever raised. Always enforced — there
    /// is no "0.0.0 disables the check" escape hatch.
    static let minimumSupported = KeystoneFirmwareVersion(major: 3, minor: 0, build: 0)

    var versionString: String {
        "\(major).\(minor).\(build)"
    }

    static func < (lhs: KeystoneFirmwareVersion, rhs: KeystoneFirmwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.build) < (rhs.major, rhs.minor, rhs.build)
    }
}

extension Data {
    /// Interim mechanism for reading the Keystone firmware version stamped into a signed PCZT
    /// (MOB-1510) — KeystoneSDK 0.8.6 exposes no firmware API, so this byte-scans the raw signed
    /// PCZT `Data` for the ASCII proprietary-field key `keystone:fw_version`, postcard's
    /// length-prefix byte for a 3-byte value (`0x03`), and the 3 version bytes that follow.
    /// Every occurrence of the key is scanned in order; a truncated or wrong-length-prefix
    /// occurrence is skipped (not treated as fatal) rather than short-circuiting the scan, since a
    /// later occurrence may still be well-formed. Returns `nil` when no valid occurrence exists at
    /// all — either the firmware predates the stamping feature, or the scan is malformed.
    ///
    /// A proper FFI reader over the PCZT's own parsed proprietary fields is a possible future
    /// improvement, once the vendor SDK or the local PCZT fork exposes one.
    func keystoneFirmwareVersion() -> KeystoneFirmwareVersion? {
        let key = Array("keystone:fw_version".utf8)
        let bytes = [UInt8](self)
        guard bytes.count >= key.count else { return nil }

        let lastPossibleKeyStart = bytes.count - key.count
        var searchIndex = 0
        while searchIndex <= lastPossibleKeyStart {
            guard Array(bytes[searchIndex..<(searchIndex + key.count)]) == key else {
                searchIndex += 1
                continue
            }

            let lengthPrefixIndex = searchIndex + key.count
            let versionStart = lengthPrefixIndex + 1
            let versionEnd = versionStart + 3
            if lengthPrefixIndex < bytes.count, bytes[lengthPrefixIndex] == 0x03, versionEnd <= bytes.count {
                return KeystoneFirmwareVersion(
                    major: Int(bytes[versionStart]),
                    minor: Int(bytes[versionStart + 1]),
                    build: Int(bytes[versionStart + 2])
                )
            }
            searchIndex += 1
        }
        return nil
    }
}
