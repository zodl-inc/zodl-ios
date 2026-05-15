//
//  CircularProgressView.swift
//  Zashi
//
//  Created by Lukáš Korba on 04-03-2025.
//

import SwiftUI

struct CircularProgressView: View {
    @Environment(\.colorScheme) var colorScheme
    
    var progress: Double
    
    init(progress: Double) {
        self.progress = progress
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Design.Utility.Purple._400.color(.light), lineWidth: 4)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Design.Utility.Purple._50.color(.light), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: progress)
        }
    }
}
