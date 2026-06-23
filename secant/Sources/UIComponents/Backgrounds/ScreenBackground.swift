//
//  ScreenBackground.swift
//  Zashi
//
//  Created by Francisco Gindre on 10/18/21.
//

import SwiftUI

/// macOS layout foundation: a screen's *content* (lists, stacks, forms) is capped to a readable
/// column width, while the colorful screen background stays full-bleed. Applied centrally by the
/// `apply*ScreenBackground()` modifiers below, so single-view flows AND the split's right panel
/// both inherit the cap without per-screen changes. No effect on iOS.
enum ZashiScreenLayout {
    /// Max content width on macOS. Single full-window views (~1120pt) and the split's right panel
    /// (~842pt) both constrain their content to this; the background is never capped.
    static let macContentMaxWidth: CGFloat = 740
}

private extension View {
    /// Cap a screen's content to `ZashiScreenLayout.macContentMaxWidth` (centered) on macOS so it
    /// doesn't sprawl across the wide window; no-op on iOS. The background modifier that wraps the
    /// result keeps filling the full screen — only the content column is constrained.
    @ViewBuilder func macCappedScreenContent() -> some View {
#if os(macOS)
        frame(maxWidth: ZashiScreenLayout.macContentMaxWidth)
#else
        self
#endif
    }
}

struct ScreenBackgroundModifier: ViewModifier {
    var color: Color

    func body(content: Content) -> some View {
        ZStack {
            color
                .edgesIgnoringSafeArea(.all)

            content
        }
    }
}

struct ScreenGradientBackground: View {
    @Environment(\.colorScheme) var colorScheme

    enum Mode {
        case branded
        case defaultGradient
        case erred
        case failure
        case onboardingDark
        case onboardingLight
        case success
        case warning
        case indigo

        func stops(_ colorScheme: ColorScheme) -> [Gradient.Stop] {
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

    var body: some View {
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
    /// RULE #8: caps content to `macContentMaxWidth` on macOS (no-op on iOS). RULE #9: the scan view
    /// passes `capped: false` so its full-window camera overlay isn't shrunk to the 800pt column.
    /// On iOS both paths are identical (the cap is macOS-only), so this is iOS-neutral (Rule #11).
    @ViewBuilder func applyScreenBackground(capped: Bool = true) -> some View {
        if capped {
            macCappedScreenContent()
                .modifier(ScreenBackgroundModifier(color: Asset.Colors.background.color))
        } else {
            modifier(ScreenBackgroundModifier(color: Asset.Colors.background.color))
        }
    }

    func applySheetBackground() -> some View {
        // Sheets manage their own (narrower) width on macOS, so the screen content cap isn't applied.
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

    func applyErredScreenBackground() -> some View {
        macCappedScreenContent()
            .modifier(
                ScreenGradientBackgroundModifier(mode: .erred)
            )
    }

    func applyIndigoScreenBackground() -> some View {
        macCappedScreenContent()
            .modifier(
                ScreenGradientBackgroundModifier(mode: .indigo)
            )
    }

    func applyBrandedScreenBackground() -> some View {
        macCappedScreenContent()
            .modifier(
                ScreenGradientBackgroundModifier(mode: .branded)
            )
    }

    func applyOnboardingScreenBackground() -> some View {
        macCappedScreenContent()
            .modifier(
                ScreenOnboardingGradientBackgroundModifier()
            )
    }

    func applyDefaultGradientScreenBackground() -> some View {
        macCappedScreenContent()
            .modifier(
                ScreenDefaultGradientBackgroundModifier()
            )
    }

    func applySuccessScreenBackground() -> some View {
        macCappedScreenContent()
            .modifier(
                ScreenGradientBackgroundModifier(mode: .success)
            )
    }

    func applyFailureScreenBackground() -> some View {
        macCappedScreenContent()
            .modifier(
                ScreenGradientBackgroundModifier(mode: .failure)
            )
    }

    func applyWarnScreenBackground() -> some View {
        macCappedScreenContent()
            .modifier(
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
