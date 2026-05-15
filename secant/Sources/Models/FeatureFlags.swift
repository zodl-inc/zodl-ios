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
    let selectText: Bool

    init(
        addUAtoMemo: Bool = false,
        appLaunchBiometric: Bool = true,
        flexa: Bool = true,
        selectText: Bool = true
    ) {
        self.addUAtoMemo = addUAtoMemo
        self.appLaunchBiometric = appLaunchBiometric
        self.flexa = flexa
        self.selectText = selectText
    }
}

extension FeatureFlags {
    static let initial = FeatureFlags()
}
