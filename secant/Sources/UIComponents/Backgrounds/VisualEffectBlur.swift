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
