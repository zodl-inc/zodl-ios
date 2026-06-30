//
//  SplashView.swift
//
//
//  Created by Lukáš Korba on 27.09.2023.
//

import SwiftUI
import Combine
import ComposableArchitecture

@MainActor
final class SplashManager: ObservableObject {
    struct SplashShape: Shape {
        var points: [CGPoint]
        
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.width, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 0))
                points.forEach { path.addLine(to: $0) }
                path.closeSubpath()
            }
        }
    }

    @Published var points: [CGPoint] = []
    @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial

    let isHidden: Bool
    let screenSize: CGSize
    var task: Task<(), Never>?
    var currentMaxHeight: CGFloat = 0.0
    var step: CGFloat = 0.0
    @Published var authenticationDidntSucceed = false
    @Published var isOn = true
    let completion: () -> Void
    var timer: Timer?

    init(_ isHidden: Bool, completion: @escaping () -> Void) {
        self.isHidden = isHidden
        self.screenSize = PlatformScreen.bounds.size
        self.completion = completion
        
        if !isHidden {
            preparePoints()
            // Only prompt for biometrics at launch when a wallet actually EXISTS. Authenticating to
            // unlock nothing (fresh install / onboarding) is pointless and annoying — macOS surfaced
            // this by prompting Touch ID on the empty onboarding launch. `areKeysPresent` is the same
            // "wallet exists" signal the Root init flow uses; with no wallet, skip straight to reveal.
            @Dependency(\.walletStorage) var walletStorage
            let walletExists = (try? walletStorage.areKeysPresent()) ?? false
            if featureFlags.appLaunchBiometric && walletExists {
                authenticate()
            } else {
#if os(macOS)
                // macOS: no biometric + no animation — reveal Home right away (static logo only).
                Task { self.finished() }
#else
                Task {
                    self.spinTheWheel()
                }
#endif
            }
        }
    }

    func authenticate() {
        @Dependency(\.localAuthentication) var localAuthentication

        authenticationDidntSucceed = false

        Task {
            if await !localAuthentication.authenticate(for: .appUnlock) {
                self.authenticationFailed()
            } else {
#if os(macOS)
                // macOS: no tear-away animation — reveal Home immediately after a successful auth.
                self.finished()
#else
                self.spinTheWheel()
#endif
            }
        }
    }
    
    @MainActor func authenticationFailed() {
        authenticationDidntSucceed = true
    }
    
    @MainActor func spinTheWheel() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            // Timer was scheduled from @MainActor spinTheWheel(); fires on main run loop.
            if MainActor.assumeIsolated({ self.isOn }) {
                Task { @MainActor in
                    self.tick()

                    if self.currentMaxHeight <= 0.0 {
                        self.finished()
                    }
                }
            }
        }
    }
    
    func preparePoints() {
        let pointsInControl = Int.random(in: 4...7)
        let allPoints = pointsInControl + 1
        let rangeSize = screenSize.width / CGFloat(allPoints)
        let xOffsetHelper = screenSize.width * 0.05
        
        var prevHeight = 0.0
        
        for i in stride(from: allPoints, through: 0, by: -1) {
            // x
            var randomXOffset: CGFloat = 0.0
            
            if i > 0 && i < allPoints {
                randomXOffset = CGFloat.random(in: -xOffsetHelper...xOffsetHelper)
            }
            
            let x = rangeSize * CGFloat(i) + randomXOffset
            
            // y
            let y = screenSize.height + prevHeight
            
            if (allPoints - i) % 2 == 0 {
                prevHeight += CGFloat.random(in: 30...70)
            }

            points.append(CGPoint(x: x, y: y))
        }
        
        points.reverse()
        
        var maxHeight: CGFloat = 0.0
        
        points.forEach {
            if $0.y > maxHeight {
                maxHeight = $0.y
            }
        }
        
        currentMaxHeight = maxHeight
        step = currentMaxHeight / 100.0
    }
    
    @MainActor func tick() {
        step *= 1.04
        
        var newMaxHeight: CGFloat = 0.0
        
        points = points.enumerated().map {
            let y = $0.element.y - step
            
            if y > newMaxHeight {
                newMaxHeight = y
            }
            return CGPoint(x: $0.element.x, y: y)
        }
        
        currentMaxHeight = newMaxHeight
    }
    
    @MainActor func finished() {
        self.isOn.toggle()
        completion()
    }
}

struct SplashView: View {
    @StateObject var splashManager: SplashManager
    let isHidden: Bool
    var authenticationIcon: Image {
        @Dependency(\.localAuthentication) var localAuthentication

        switch localAuthentication.method() {
        case .faceID: return Image(systemName: "faceid")
        case .touchID: return Image(systemName: "touchid")
        case .passcode: return Asset.Assets.Icons.authKey.image
        default: return Asset.Assets.Icons.coinsHand.image
        }
    }

    var authenticationDesc: String {
        @Dependency(\.localAuthentication) var localAuthentication

        switch localAuthentication.method() {
        case .faceID: return String(localizable: .splashAuthFaceID)
        case .touchID: return String(localizable: .splashAuthTouchID)
        case .passcode: return String(localizable: .splashAuthPasscode)
        default: return ""
        }
    }
    
    var hiIconYOffset: CGFloat {
        splashManager.authenticationDidntSucceed
        ? 100.0
        : 0.0
    }

    // Centered "Hi" logo, scaled up on macOS for the larger window. Matches WelcomeView.hiLogoHeight so
    // the launch transition (splash → welcome → home) shows ONE consistent logo. iOS size unchanged.
    private var hiLogoHeight: CGFloat {
#if os(macOS)
        96
#else
        60
#endif
    }

    var body: some View {
        if splashManager.isOn && !isHidden {
#if os(macOS)
            // macOS: a STATIC, window-sized logo — no tear-away animation, no screen-bounds mask
            // (that mask sized to the whole screen and "framed" the logo inside the window). Touch ID
            // runs over it; on success Home is revealed immediately. iOS keeps the animated splash.
            ZStack {
                Asset.Colors.splash.color.ignoresSafeArea()
                Asset.Assets.welcomeScreenLogo.image
                    .zImage(height: hiLogoHeight, color: .white)
                lockedIcons()
            }
#else
            ZStack {
                hiIcon()
                lockedIcons()
            }
            .ignoresSafeArea(.keyboard)
#endif
        }
    }
    
    @ViewBuilder func hiIcon() -> some View {
        // Simplified from a GeometryReader/.position (over-engineering left from when two images needed
        // placing) to a plain centered ZStack — the logo just centers, shifted up by hiIconYOffset when
        // auth fails. The tear-away mask + splash colour are unchanged, so the iOS animation is identical.
        ZStack {
            Asset.Colors.splash.color
            Asset.Assets.welcomeScreenLogo.image
                .zImage(height: hiLogoHeight, color: .white)
                .offset(y: -hiIconYOffset)
        }
        .mask {
            SplashManager.SplashShape(points: splashManager.points)
        }
        .ignoresSafeArea()
        .onChange(of: isHidden) { value in
            if value {
                splashManager.preparePoints()
            }
        }
    }
    
    @ViewBuilder func lockedIcons() -> some View {
        if splashManager.authenticationDidntSucceed {
            VStack(spacing: 0) {
                Spacer()
                
                Button {
                    splashManager.authenticate()
                } label: {
                    authenticationIcon
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .foregroundColor(.white)
                }

                Text(localizable: .splashAuthTitle)
                    .font(.custom(FontFamily.Inter.semiBold.name, size: 20))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                Text(authenticationDesc)
                    .font(.custom(FontFamily.Inter.regular.name, size: 14))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding(.bottom, 160)
            .screenHorizontalPadding()
        }
    }
}

struct SplashModifier: ViewModifier {
    let isHidden: Bool
    let completion: () -> Void
    
    func body(content: Content) -> some View {
        content
            .overlay {
                if isHidden {
                    SplashView(
                        splashManager: SplashManager(isHidden) {
                            completion()
                        },
                        isHidden: isHidden
                    )
                    .hidden()
                } else {
                    SplashView(
                        splashManager: SplashManager(isHidden) {
                            completion()
                        },
                        isHidden: isHidden
                    )
                }
            }
    }
}

extension View {
    func overlayedWithSplash(_ isHidden: Bool = false, completion: @escaping () -> Void) -> some View {
        modifier(SplashModifier(isHidden: isHidden, completion: completion))
    }
}
