//
//  MessageEditorStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 22.07.2022.
//

import Foundation
import ComposableArchitecture
import SwiftUI

@Reducer
struct MessageEditor {
    @ObservableState
    struct State: Equatable {
        /// default 0, no char limit
        var charLimit = 0
        @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
        var isUAaddedToMemo: Bool = false
        var text = ""
        var uAddress = ""
        
        var isCharLimited: Bool {
            charLimit > 0
        }
        
        var byteLength: Int {
            // The memo supports unicode so the overall count is not char count of text
            // but byte representation instead
            text.utf8.count
        }
        
        var isValid: Bool {
            charLimit > 0
            ? byteLength <= charLimit
            : true
        }
        
        var charLimitText: String {
            charLimit > 0
            ? "\(charLimit - byteLength)/\(charLimit)"
            : ""
        }

        init(charLimit: Int = 0, text: String = "") {
            self.charLimit = charLimit
            self.text = text
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<MessageEditor.State>)
    }
    
    init() {}
    
    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .binding(\.isUAaddedToMemo):
                let blob = String(localizable: .messageEditorAddUAformat(state.uAddress))
                if state.isUAaddedToMemo {
                    state.text += blob
                } else {
                    if state.text.contains(blob) {
                        state.text = state.text.replacingOccurrences(of: blob, with: "")
                    } else if state.text.contains(state.uAddress) {
                        state.text = state.text.replacingOccurrences(of: state.uAddress, with: "")
                    }
                }
                return .none

            case .binding:
                return .none
            }
        }
    }
}
