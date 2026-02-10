//
//  WelcomeView.swift
//  Zashi
//
//  Created by Francisco Gindre on 1/6/22.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import NumberFormatter

public struct WelcomeView: View {
    @Perception.Bindable var store: StoreOf<Welcome>

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
    
    public init(store: StoreOf<Welcome>) {
        self.store = store
    }

    public var body: some View {
        GeometryReader { proxy in
//        VStack {
            WithPerceptionTracking {
                Asset.Assets.welcomeScreenLogo.image
                    .zImage(width: 161, height: 60, color: Asset.Colors.primary.color)
                    .position(
                        x: proxy.frame(in: .local).midX,
                        y: proxy.frame(in: .local).midY
                    )

//                Asset.Assets.zashiLogo.image
//                    .zImage(width: 249, height: 321, color: .white)
//                    .scaleEffect(0.35)
//                    .position(
//                        x: proxy.frame(in: .local).midX,
//                        y: proxy.frame(in: .local).midY * 0.5
//                    )
//                
//                Asset.Assets.splashHi.image
//                    .resizable()
//                    .renderingMode(.template)
//                    .aspectRatio(contentMode: .fit)
//                    .frame(height: 213)
//                    .foregroundColor(.white)
//                    .scaleEffect(hiHeight)
//                    .position(
//                        x: proxy.frame(in: .local).midX,
//                        y: proxy.frame(in: .local).midY * 0.8
//                    )
//#if !SECANT_DISTRIB
//                    .accessDebugMenuWithHiddenGesture {
//                        store.send(.debugMenuStartup)
//                    }
//#endif
            }
        }
        .background(Asset.Colors.splash.color)
        .ignoresSafeArea()
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
    public static var demo = StoreOf<Welcome>(
        initialState: .initial
    ) {
        Welcome()
    }
}

// MARK: - Placeholders

extension Welcome.State {
    public static let initial = Welcome.State()
}
