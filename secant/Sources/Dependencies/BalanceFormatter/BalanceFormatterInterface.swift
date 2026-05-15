//
//  BalanceFormatterInterface.swift
//  Zashi
//
//  Created by Lukáš Korba on 12.11.2022.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension DependencyValues {
    var balanceFormatter: BalanceFormatterClient {
        get { self[BalanceFormatterClient.self] }
        set { self[BalanceFormatterClient.self] = newValue }
    }
}

@DependencyClient
struct BalanceFormatterClient {
    var convert: @Sendable (
        Zatoshi,
        ZatoshiStringRepresentation.PrefixSymbol,
        ZatoshiStringRepresentation.Format
    ) -> ZatoshiStringRepresentation = { _, _, _ in ZatoshiStringRepresentation(Zatoshi(0)) }
}
