//
//  DerivationToolTestKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import ComposableArchitecture
import XCTestDynamicOverlay
@preconcurrency import ZcashLightClientKit

extension DerivationToolClient {
    static let noOp = Self(
        deriveSpendingKey: { _, _, _ in throw "NotImplemented" },
        deriveUnifiedFullViewingKey: { _, _ in throw "NotImplemented" },
        doesAddressSupportMemo: { _, _ in return false },
        isUnifiedAddress: { _, _ in return false },
        isSaplingAddress: { _, _ in return false },
        isTransparentAddress: { _, _ in return false },
        isTexAddress: { _, _ in return false },
        isZcashAddress: { _, _ in return false },
        deriveUnifiedAddressFrom: { _, _ in throw "NotImplemented" },
        deriveArbitraryWalletKey: { _, _ in throw "NotImplemented" },
        deriveArbitraryAccountKey: { _, _, _, _ in throw "NotImplemented" }
    )
}
