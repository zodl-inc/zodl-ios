//
//  MigrationSDKTestKey.swift
//  zodl
//
//  Test/preview helpers. The `@DependencyClient` macro already synthesizes `testValue` (every
//  endpoint unimplemented). `noOp` is a convenience for previews and for features that don't drive
//  the SDK — all endpoints return their harmless defaults.
//

import ComposableArchitecture

extension MigrationSDKClient {
    static let noOp = MigrationSDKClient()

    /// A client backed by an in-memory engine — handy for previews/tests that DO want real behaviour
    /// without touching disk.
    static func ephemeral() -> MigrationSDKClient {
        Self.live(store: .ephemeral())
    }
}
