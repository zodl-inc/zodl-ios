//
//  FeatureFlags.swift
//  Zashi
//
//  Created by Lukáš Korba on 10-15-2024.
//

struct FeatureFlags: Equatable {
    let addUAtoMemo: Bool
    let appLaunchBiometric: Bool
    let coinholderPolling: Bool
    let flexa: Bool
    let selectText: Bool

    init(
        addUAtoMemo: Bool = false,
        appLaunchBiometric: Bool = true,
        coinholderPolling: Bool = false,
        flexa: Bool = true,
        selectText: Bool = true
    ) {
        self.addUAtoMemo = addUAtoMemo
        self.appLaunchBiometric = appLaunchBiometric
        self.coinholderPolling = coinholderPolling
        self.flexa = flexa
        self.selectText = selectText
    }
}

extension FeatureFlags {
    static let initial = FeatureFlags()
}
