//
//  StoredVotingHotkey.swift
//  Zashi
//

import Foundation

struct StoredVotingHotkey: Codable, Equatable {
    let storedSecret: VotingHotkeySecret
    let version: Int

    init(storedSecret: VotingHotkeySecret, version: Int) {
        self.storedSecret = storedSecret
        self.version = version
    }
}

/// Read-only redacted holder for a voting hotkey's stored secret.
///
/// Key material — same handling as `SeedPhrase` (`CHP_DESIGN.md` §0.5): never logged, never
/// printed via reflection. Mirrors `SeedPhrase`'s exact pattern (`Sources/Utils/
/// SensitiveData.swift`) rather than storing bare `Data` on `StoredVotingHotkey`.
struct VotingHotkeySecret: Codable, Equatable, Redactable {
    private let secret: Data

    init(_ secret: Data) {
        self.secret = secret
    }

    /// Returns the raw secret bytes with no `Redactable` protection. Use it only to hand the
    /// bytes to `VotingCryptoClient`/`VotingRustBackend`; never log or print the result.
    func value() -> Data {
        secret
    }
}
