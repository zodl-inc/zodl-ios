//
//  MnemonicTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 13.11.2022.
//

import ComposableArchitecture
import XCTestDynamicOverlay

extension MnemonicClient {
    static let noOp = Self(
        randomMnemonic: { "" },
        randomMnemonicWords: { [] },
        toSeed: { _ in [] },
        asWords: { _ in [] },
        isValid: { _ in },
        suggestWords: { _ in [] }
    )
}
