//
//  URL+Suffix.swift
//  zodlTests
//
//  General-purpose path helper, extracted from the delegation-recovery
//  fixture. Nothing here is specific to that fixture or to voting.
//

import Foundation

extension URL {
    /// Appends a SUFFIX to the last path component, as distinct from
    /// appending a path EXTENSION.
    ///
    /// SQLite names its sidecars this way — `voting.sqlite3-wal`, not
    /// `voting.sqlite3.wal` — and `appendingPathExtension` would produce the
    /// wrong name for every one of them.
    func appendingSuffix(_ suffix: String) -> URL {
        deletingLastPathComponent().appendingPathComponent(lastPathComponent + suffix)
    }
}
