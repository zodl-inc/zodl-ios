//
//  Welcome.swift
//  Zashi
//
//  Created by Lukáš Korba on 04.04.2022.
//

import Foundation
import Combine
import ComposableArchitecture

@Reducer
struct Welcome {
    @ObservableState
    struct State: Equatable { }
    
    enum Action: Equatable { }
    
    init() {}
    
    var body: some Reducer<State, Action> {
        Reduce { _, _ in return .none }
    }
}
