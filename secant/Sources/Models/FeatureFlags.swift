//
//  FeatureFlags.swift
//  Zashi
//
//  Created by Lukáš Korba on 10-15-2024.
//

struct FeatureFlags: Equatable {
    let addUAtoMemo: Bool
    let appLaunchBiometric: Bool
    let flexa: Bool
    /// Orchard -> Ironwood migration. Deliberately a compile-time, per-flavor flag rather than a
    /// runtime-togglable `WalletConfig` one: the SDK's migration sync gate is flag-independent, so a
    /// user able to switch migration off mid-run could leave overdue transfers blocking sync with no
    /// UI left to resolve them. Only a new build can change it. iPhone-only for v1 (macOS/iPad park).
    let migration: Bool
    let selectText: Bool

    init(
        addUAtoMemo: Bool = false,
        appLaunchBiometric: Bool = true,
        flexa: Bool = true,
        migration: Bool = false,
        selectText: Bool = true
    ) {
        self.addUAtoMemo = addUAtoMemo
        self.appLaunchBiometric = appLaunchBiometric
        self.flexa = flexa
        self.migration = migration
        self.selectText = selectText
    }
}

extension FeatureFlags {
    static let initial = FeatureFlags()
}
