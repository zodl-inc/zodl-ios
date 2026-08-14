//
//  KeystoneDisplayFirmwareVersion.swift
//  Zashi
//
//  MOB-1510: device firmware stamps `global.proprietary["keystone:fw_version"]` (3 raw bytes)
//  into every signed PCZT; KeystoneSDK 0.8.6 exposes no firmware API of its own.
//
//  Two numberings are in play and must never be mixed — hence two types. `KeystoneFirmwareStamp`
//  is what the wire carries, `KeystoneDisplayFirmwareVersion` is what the device screen shows and what
//  the minimum is written in. `fromStamp` is the only bridge between them.
//

import Foundation

/// The three bytes exactly as the device wrote them, before any normalization.
///
/// This is the firmware's *internal* major, which is not what the device displays — see
/// `KeystoneDisplayFirmwareVersion.stampedMajorOffset`. Kept distinct from `KeystoneDisplayFirmwareVersion` so
/// a raw triple can never be compared against the minimum by accident.
struct KeystoneFirmwareStamp: Equatable, Sendable {
    let major: Int
    let minor: Int
    let build: Int

    var rawString: String {
        "\(major).\(minor).\(build)"
    }
}

struct KeystoneDisplayFirmwareVersion: Equatable, Comparable, Sendable {
    /// Keystone's `src/config/version.h` carries `SOFTWARE_VERSION_MAJOR` as the displayed major
    /// plus `SOFTWARE_VERSION_MAJOR_OFFSET` (10, unchanged across every firmware tag from 2.2.8
    /// through 3.0.0), and `src/config/version.c` renders `MAJOR - OFFSET` on the device. The
    /// stamp is generated straight from the raw macro, so a Keystone whose screen reads 3.0.1
    /// stamps `[13, 0, 1]`. Confirmed on a physical device.
    ///
    /// Keystone treats this as the contract rather than an oversight: their SDK specifies the
    /// equivalent field on the batch-signing envelope as the raw triple and documents that
    /// display offsets are deliberately not applied to it.
    static let stampedMajorOffset = 10

    /// Minimum Keystone firmware this app will accept a signature from — set by product
    /// (MOB-1510), in the numbering the device displays. Single point of change if the minimum is
    /// ever raised. Always enforced — there is no "0.0.0 disables the check" escape hatch.
    static let minimumSupported = KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 1)

    let major: Int
    let minor: Int
    let build: Int

    var versionString: String {
        "\(major).\(minor).\(build)"
    }

    /// The only initializer, and it names its numbering. Declaring it suppresses the synthesized
    /// memberwise `init(major:minor:build:)`, so a raw stamp cannot become a version without
    /// going through `fromStamp` and having the offset applied.
    init(displayMajor: Int, minor: Int, build: Int) {
        self.major = displayMajor
        self.minor = minor
        self.build = build
    }
}

extension KeystoneDisplayFirmwareVersion {
    /// Normalizes a raw device stamp into the displayed numbering.
    ///
    /// A raw major below `stampedMajorOffset` is taken as already normalized. That arm exists so
    /// that if Keystone ever starts applying the offset firmware-side, this gate degrades to
    /// correct rather than rejecting every device — a corrected stamp of 3 would otherwise read
    /// as -7. It is ambiguous only for a device whose *displayed* major reaches 10.
    static func fromStamp(_ stamp: KeystoneFirmwareStamp) -> KeystoneDisplayFirmwareVersion {
        KeystoneDisplayFirmwareVersion(
            displayMajor: stamp.major >= stampedMajorOffset ? stamp.major - stampedMajorOffset : stamp.major,
            minor: stamp.minor,
            build: stamp.build
        )
    }

    static func < (lhs: KeystoneDisplayFirmwareVersion, rhs: KeystoneDisplayFirmwareVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.build) < (rhs.major, rhs.minor, rhs.build)
    }
}

extension Data {
    /// Byte-scans a signed PCZT for the key `keystone:fw_version`, postcard's length-prefix byte
    /// for a 3-byte value (`0x03`), and the 3 version bytes that follow (MOB-1510) — interim until
    /// a proper FFI reader exists over the PCZT's parsed proprietary fields. Occurrences are
    /// scanned in order; a truncated or wrong-length-prefix one is skipped, not fatal. `nil` when
    /// no valid occurrence exists.
    ///
    /// Returns the bytes as written. Use `KeystoneDisplayFirmwareVersion.fromStamp` to compare the
    /// result against anything.
    func keystoneFirmwareStamp() -> KeystoneFirmwareStamp? {
        let key = Data("keystone:fw_version".utf8)
        var searchRange = startIndex..<endIndex

        while let keyRange = range(of: key, in: searchRange) {
            let lengthPrefixIndex = keyRange.upperBound
            let versionStart = lengthPrefixIndex + 1
            let versionEnd = versionStart + 3
            if versionEnd <= endIndex, self[lengthPrefixIndex] == 0x03 {
                return KeystoneFirmwareStamp(
                    major: Int(self[versionStart]),
                    minor: Int(self[versionStart + 1]),
                    build: Int(self[versionStart + 2])
                )
            }
            searchRange = keyRange.upperBound..<endIndex
        }
        return nil
    }
}
