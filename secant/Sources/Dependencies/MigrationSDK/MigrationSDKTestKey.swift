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

    /// A client backed by an in-memory **dummy** engine — handy for previews/tests that DO want
    /// deterministic simulated behaviour without touching disk or the real SDK.
    static func ephemeral() -> MigrationSDKClient {
        Self.dummy(store: .ephemeral())
    }
}
