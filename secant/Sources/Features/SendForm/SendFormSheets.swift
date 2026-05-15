//
//  BalancesSheet.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-26-2025.
//

import SwiftUI
import ComposableArchitecture

extension SendFormView {
    @ViewBuilder func balancesContent() -> some View {
        WithPerceptionTracking {
            BalancesView(
                store:
                    store.scope(
                        state: \.balancesState,
                        action: \.balances
                    ),
                tokenName: tokenName
            )
        }
    }
}
