//
//  WelcomeView.swift
//  Zashi
//
//  Created by Francisco Gindre on 1/6/22.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct WelcomeView: View {
    @PlatformBindable var store: StoreOf<Welcome>

    // Centered "Hi" logo, scaled up on macOS for the larger window. Matches SplashView.hiLogoHeight so
    // the launch transition (splash → welcome → home) shows ONE consistent logo — no GeometryReader/
    // .position recompute (the old over-engineering, from when two images needed placing) that made it
    // jump. iOS size is unchanged (Rule #11); only the structure is simplified.
    private var hiLogoHeight: CGFloat {
#if os(macOS)
        96
#else
        60
#endif
    }
    
    init(store: StoreOf<Welcome>) {
        self.store = store
    }

    var body: some View {
        // One centered logo on the full-bleed splash colour, identical on both platforms (only the size
        // differs). Replaces the iOS GeometryReader/.position path — simpler, and no recompute jitter.
        ZStack {
            Asset.Colors.splash.color.ignoresSafeArea()
            Asset.Assets.welcomeScreenLogo.image
                .zImage(height: hiLogoHeight, color: .white)
        }
    }
}

// MARK: - Previews

struct WelcomeView_Previews: PreviewProvider {
    static let squarePreviewSize: CGFloat = 360

    static var previews: some View {
        ZcashBadge()
            .applyScreenBackground()
            .previewLayout(
                .fixed(
                    width: squarePreviewSize,
                    height: squarePreviewSize
                )
            )
            .preferredColorScheme(.light)

        ZStack {
            ZcashBadge()
        }
        .padding()
        .applyScreenBackground()
        .previewLayout(
            .fixed(
                width: squarePreviewSize,
                height: squarePreviewSize
            )
        )
        .preferredColorScheme(.light)

        Group {
            WelcomeView(store: .demo)
                .preferredColorScheme(.light)

            WelcomeView(store: .demo)
                .previewDevice("iPhone SE (2nd generation)")
        }
    }
}

// MARK: - Store

extension StoreOf<Welcome> {
    static var demo = StoreOf<Welcome>(
        initialState: .initial
    ) {
        Welcome()
    }
}

// MARK: - Placeholders

extension Welcome.State {
    static let initial = Welcome.State()
}
