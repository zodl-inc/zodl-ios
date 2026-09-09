//
//  URL+Suffix.swift
//  zodlTests
//
//  General-purpose path helper, not tied to any particular suite or feature.
//

import Foundation

extension URL {
    /// Appends a SUFFIX to the last path component, as distinct from
    /// appending a path EXTENSION.
    ///
    /// SQLite names its sidecars this way (`db.sqlite3-wal`, not
    /// `db.sqlite3.wal`), and `appendingPathExtension` would produce the
    /// wrong name for every one of them.
    func appendingSuffix(_ suffix: String) -> URL {
        deletingLastPathComponent().appendingPathComponent(lastPathComponent + suffix)
    }
}
