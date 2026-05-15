//
//  RequestZecCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2023-03-17.
//

import SwiftUI
import ComposableArchitecture

struct RequestZecCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<RequestZecCoordFlow>
    let tokenName: String

    init(store: StoreOf<RequestZecCoordFlow>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                ZecKeyboardView(
                    store:
                        store.scope(
                            state: \.zecKeyboardState,
                            action: \.zecKeyboard
                        ),
                    tokenName: tokenName
                )
                .navigationBarHidden(true)
            } destination: { store in
                switch store.case {
                case let .requestZec(store):
                    RequestZecView(store: store, tokenName: tokenName)
                case let .requestZecSummary(store):
                    RequestZecSummaryView(store: store, tokenName: tokenName)
                }
            }
            .navigationBarHidden(!store.path.isEmpty)
        }
        .padding(.horizontal, 4)
        .applyScreenBackground()
        .zashiBack()
        .screenTitle(String(localizable: .generalRequest))
    }
}

#Preview {
    NavigationView {
        RequestZecCoordFlowView(store: RequestZecCoordFlow.placeholder, tokenName: "ZEC")
    }
}

// MARK: - Placeholders

extension RequestZecCoordFlow.State {
    static let initial = RequestZecCoordFlow.State()
}

extension RequestZecCoordFlow {
    static let placeholder = StoreOf<RequestZecCoordFlow>(
        initialState: .initial
    ) {
        RequestZecCoordFlow()
    }
}
