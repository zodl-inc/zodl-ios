//
//  ScreenBackground.swift
//  Zashi
//
//  Created by Francisco Gindre on 10/18/21.
//

import SwiftUI
import Generated

public struct ScreenBackgroundModifier: ViewModifier {
    var color: Color

    public func body(content: Content) -> some View {
        ZStack {
            color
                .edgesIgnoringSafeArea(.all)

            content
        }
    }
}

public struct ScreenGradientBackground: View {
    @Environment(\.colorScheme) var colorScheme

    public enum Mode {
        case branded
        case defaultGradient
        case erred
        case failure
        case onboardingDark
        case onboardingLight
        case success
        case warning
        case indigo

        public func stops(_ colorScheme: ColorScheme) -> [Gradient.Stop] {
            switch self {
            case .branded:
                return [
                    Gradient.Stop(color: Design.Utility.Brand._600.color(colorScheme), location: 0.0),
                    Gradient.Stop(color: Design.Utility.Brand._400.color(colorScheme), location: 0.5),
                    Gradient.Stop(color: Design.screenBackground.color(colorScheme), location: 0.75)
                ]
            case .defaultGradient:
                return [
                    Gradient.Stop(color: Design.Surfaces.bgAdjust.color(colorScheme), location: 0.0),
                    Gradient.Stop(color: Design.Surfaces.bgPrimary.color(colorScheme), location: 0.25)
                ]
            case .erred:
                return [
                    Gradient.Stop(color: Design.Utility.WarningYellow._100.color(colorScheme), location: 0.0),
                    Gradient.Stop(color: Design.screenBackground.color(colorScheme), location: 0.4)
                ]
            case .indigo:
                return [
                    Gradient.Stop(color: Design.Utility.Indigo._100.color(colorScheme), location: 0.0),
                    Gradient.Stop(color: Design.screenBackground.color(colorScheme), location: 0.4)
                ]
            case .failure:
                return [
                    Gradient.Stop(color: Design.Utility.ErrorRed._100.color(colorScheme), location: 0.0),
                    Gradient.Stop(color: Design.screenBackground.color(colorScheme), location: 0.4)
                ]
            case .onboardingDark:
                return [
                    Gradient.Stop(color: Asset.Colors.ZDesign.sharkShades06dp.color, location: 0.0),
                    Gradient.Stop(color: Asset.Colors.ZDesign.Base.obsidian.color, location: 1.0)
                ]
            case .onboardingLight:
                return [
                    Gradient.Stop(color: Asset.Colors.ZDesign.Base.concrete.color, location: 0.0),
                    Gradient.Stop(color: Asset.Colors.ZDesign.Base.bone.color, location: 1.0)
                ]
            case .success:
                return [
                    Gradient.Stop(color: Design.Utility.SuccessGreen._100.color(colorScheme), location: 0.0),
                    Gradient.Stop(color: Design.screenBackground.color(colorScheme), location: 0.4)
                ]
            case .warning:
                return [
                    Gradient.Stop(color: Design.Utility.WarningYellow._500.color(colorScheme), location: 0.0),
                    Gradient.Stop(color: Design.screenBackground.color(colorScheme), location: 0.4)
                ]
            }
        }
    }
    
    let mode: Mode

    public var body: some View {
        LinearGradient(
            stops: mode.stops(colorScheme),
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct ScreenGradientBackgroundModifier: ViewModifier {
    let mode: ScreenGradientBackground.Mode

    func body(content: Content) -> some View {
        ZStack {
            ScreenGradientBackground(mode: mode)
                .edgesIgnoringSafeArea(.all)
            
            content
        }
    }
}

struct ScreenOnboardingGradientBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        ZStack {
            ScreenGradientBackground(
                mode: colorScheme == .light ? .onboardingLight : .onboardingDark
            )
            .edgesIgnoringSafeArea(.all)
            
            content
        }
    }
}

struct ScreenDefaultGradientBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        ZStack {
            ScreenGradientBackground(
                mode: .defaultGradient
            )
            .edgesIgnoringSafeArea(.all)
            
            content
        }
    }
}

extension View {
    public func applyScreenBackground() -> some View {
        modifier(
            ScreenBackgroundModifier(
                color: Asset.Colors.background.color
            )
        )
    }
    
    public func applySheetBackground() -> some View {
        if #available(iOS 26.0, *) {
            modifier(
                ScreenBackgroundModifier(
                    color: .clear
                )
            )
        } else {
            modifier(
                ScreenBackgroundModifier(
                    color: Asset.Colors.background.color
                )
            )
        }
    }
    
    public func applyErredScreenBackground() -> some View {
        modifier(
            ScreenGradientBackgroundModifier(mode: .erred)
        )
    }
    
    public func applyIndigoScreenBackground() -> some View {
        modifier(
            ScreenGradientBackgroundModifier(mode: .indigo)
        )
    }
    
    public func applyBrandedScreenBackground() -> some View {
        modifier(
            ScreenGradientBackgroundModifier(mode: .branded)
        )
    }
    
    public func applyOnboardingScreenBackground() -> some View {
        self.modifier(
            ScreenOnboardingGradientBackgroundModifier()
        )
    }

    public func applyDefaultGradientScreenBackground() -> some View {
        self.modifier(
            ScreenDefaultGradientBackgroundModifier()
        )
    }

    public func applySuccessScreenBackground() -> some View {
        modifier(
            ScreenGradientBackgroundModifier(mode: .success)
        )
    }
    
    public func applyFailureScreenBackground() -> some View {
        modifier(
            ScreenGradientBackgroundModifier(mode: .failure)
        )
    }
    
    public func applyWarnScreenBackground() -> some View {
        modifier(
            ScreenGradientBackgroundModifier(mode: .warning)
        )
    }
}

struct ScreenBackground_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Text("Hello")
        }
        .applyScreenBackground()
        .preferredColorScheme(.light)
    }
}
