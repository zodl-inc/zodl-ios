#if canImport(UIKit)
//
//  VisualEffectBlur.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-03.
//

import UIKit
import SwiftUI

struct VisualEffectBlur: UIViewRepresentable {
    init() {
        
    }
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) { }
}

#else
import SwiftUI

/// macOS: use a native SwiftUI material instead of UIVisualEffectView.
struct VisualEffectBlur: View {
    init() {}
    var body: some View {
        Rectangle().fill(.ultraThinMaterial)
    }
}
#endif
