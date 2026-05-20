//
//  MnemonicLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import ComposableArchitecture
@preconcurrency import MnemonicSwift

extension MnemonicClient: DependencyKey {
    static let liveValue = Self.live()

    static func live() -> Self {
        Self(
            randomMnemonic: {
                try Mnemonic.generateMnemonic(strength: 256)
            },
            randomMnemonicWords: {
                try Mnemonic.generateMnemonic(strength: 256).components(separatedBy: " ")
            },
            toSeed: { mnemonic in
                let data = try Mnemonic.deterministicSeedBytes(from: mnemonic)

                return [UInt8](data)
            },
            asWords: { mnemonic in
                mnemonic.components(separatedBy: " ")
            },
            isValid: { mnemonic in
                try Mnemonic.validate(mnemonic: mnemonic)
            },
            suggestWords: { prefix in
                MnemonicLanguageType.english.words().filter { $0.hasPrefix(prefix) }
            }
        )
    }
}
