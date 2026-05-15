//
//  HiddenIfSet.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-23-2024.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import Combine

struct HiddenIfSetModifier: ViewModifier {
    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    
    func body(content: Content) -> some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                if isSensitiveContentHidden {
                    Text(localizable: .generalHideBalancesMostStandalone)
                } else {
                    content
                }
            }
        }
    }
}

extension Text {
    func hiddenIfSet() -> some View {
        modifier(HiddenIfSetModifier())
    }
}
