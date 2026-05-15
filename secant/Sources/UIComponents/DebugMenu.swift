//
//  DebugMenu.swift
//  Zashi
//
//  Created by Lukáš Korba on 15.04.2022.
//

import SwiftUI

// TODO: [#273] Make sure this code will never be in the production (app store) build (https://github.com/Electric-Coin-Company/zashi-ios/issues/273)

// swiftlint:disable:next private_over_fileprivate strict_fileprivate
struct DebugMenuModifier: ViewModifier {
    enum DragState {
        case inactive
        case pressing
        case dragging(translation: CGSize)
    }

    @GestureState var dragState = DragState.inactive
    var minimumDuration: Double
    let action: () -> Void
    
    func body(content: Content) -> some View {
        let longPressDrag = LongPressGesture(minimumDuration: minimumDuration)
            .sequenced(before: DragGesture())
            .updating($dragState) { value, state, _ in
                switch value {
                    // Long press begins.
                case .first(true):
                    state = .pressing
                    // Long press confirmed, dragging may begin.
                case .second(true, let drag):
                    state = .dragging(translation: drag?.translation ?? .zero)
                    // Dragging ended or the long press cancelled.
                default:
                    state = .inactive
                }
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                
                if drag.translation.height > 0 {
                    action()
                }
            }
        
        return content.gesture(longPressDrag)
    }
}

extension View {
    func accessDebugMenuWithHiddenGesture(minimumDuration: Double = 0.75, action: @escaping () -> Void ) -> some View {
        self.modifier(
            DebugMenuModifier(minimumDuration: minimumDuration) {
                action()
            }
        )
    }
}
