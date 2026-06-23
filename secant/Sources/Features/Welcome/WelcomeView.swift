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

    var hiHeight: CGFloat {
        var potentialCountryCode: String?
        
        if #available(iOS 16, *) {
            potentialCountryCode = Locale.current.language.languageCode?.identifier
        } else {
            potentialCountryCode = Locale.current.languageCode
        }
        
        if let potentialCountryCode, potentialCountryCode == "es" {
            return 0.6
        } else {
            return 0.35
        }
    }
    
    init(store: StoreOf<Welcome>) {
        self.store = store
    }

    var body: some View {
#if os(macOS)
        // macOS: render IDENTICALLY to the static SplashView — a full-canvas, centered logo on the
        // splash colour. The GeometryReader/`.position` path below didn't fill the whole canvas (the
        // logo wasn't stretched and a second colour showed where it stopped), which made the splash
        // look like TWO different "Hi" states. One consistent Hi now. iOS path is untouched (Rule #11).
        ZStack {
            Asset.Colors.splash.color.ignoresSafeArea()
            Asset.Assets.welcomeScreenLogo.image
                .zImage(height: 60, color: .white)
        }
#else
        GeometryReader { proxy in
            WithPerceptionTracking {
                Asset.Assets.welcomeScreenLogo.image
                    .zImage(height: 60, color: .white)
                    .position(
                        x: proxy.frame(in: .local).midX,
                        y: proxy.frame(in: .local).midY
                    )
            }
        }
        .background(Asset.Colors.splash.color)
        .ignoresSafeArea()
#endif
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
