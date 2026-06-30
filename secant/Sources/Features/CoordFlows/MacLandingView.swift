//
//  MacLandingView.swift
//  Zashi
//
//  macOS-only animated landing for the not-initialized (onboarding) state.
//
//  Launch sequence:
//    1. INTRO — the full-bleed Zodl sphinx hero fades/settles in on black, its eyes pulsing with a
//       soft glow (a repeating breath).
//    2. REVEAL — after a beat the sphinx slides a little to the LEFT (same size — never scaled down) as
//       a white "Get started" panel springs in from the right edge with the Restore / Create CTAs, and
//       the ZODL wordmark + tagline fade in over the rock.
//
//  The CTAs drive the SAME `RestoreWalletCoordFlow` actions as the iOS onboarding root
//  (`.importExistingWallet` / `.createNewWalletTapped`), so the entire restore/create NavigationStack
//  downstream is unchanged — this view only re-skins the macOS *root*. iOS keeps its original root
//  (Rule #11: the iOS tree is never touched).
//

#if os(macOS)
import SwiftUI
import ComposableArchitecture

struct MacLandingView: View {
    let store: StoreOf<RestoreWalletCoordFlow>

    // Animation phases.
    @State private var sphinxIn = false   // hero fade/settle on first appear
    @State private var eyesGlow = false   // pulsing eye glow (repeats forever)
    @State private var revealed = false   // sphinx slid left + panel slid in + branding shown

    // Native aspect of the hero art (zodl-sphinx-hero.png is 1920 × 1313).
    private let heroAspect: CGFloat = 1920.0 / 1313.0

    // MARK: - Tuning knobs (safe to tweak by hand)

    /// EYE GLOW POSITION — a fraction of the FITTED sphinx rect. x: 0 = left … 1 = right; y: 0 = top …
    /// 1 = bottom. Nudge these two numbers to sit the glow exactly on the eyes (bigger x → right,
    /// bigger y → down). This is the one to adjust.
    private let eyeCenter = CGPoint(x: 0.507, y: 0.313)
    /// Eye glow size as a fraction of the sphinx width (an ellipse — wider than tall) + softness.
    private let eyeGlowWidthFraction: CGFloat = 0.11
    private let eyeGlowHeightFraction: CGFloat = 0.05
    private let eyeGlowBlur: CGFloat = 6
    private let eyeGlowColor = Color(red: 0.72, green: 0.96, blue: 1.0)
    /// Pulse: dim ↔ bright opacity, small ↔ large scale, and seconds per breath.
    private let eyeGlowDimOpacity: CGFloat = 0.2
    private let eyeGlowBrightOpacity: CGFloat = 0.95
    private let eyeGlowDimScale: CGFloat = 0.85
    private let eyeGlowBrightScale: CGFloat = 1.15
    private let eyeGlowPulseSeconds: Double = 1.2
    /// How far the sphinx slides LEFT when the panel reveals, as a fraction of the panel width. The
    /// sphinx is NEVER scaled — it keeps its full intro size and only translates. 0 = stays centered.
    private let sphinxRevealShiftFraction: CGFloat = 0.5

    init(store: StoreOf<RestoreWalletCoordFlow>) {
        self.store = store
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // Panel claims ~42% of the window, clamped so the CTAs never look cramped or marooned.
            let panelW = min(max(w * 0.42, 380), 460)
            let leftRegionW = revealed ? (w - panelW) : w   // visible sphinx column

            ZStack(alignment: .leading) {
                Color.black.ignoresSafeArea()

                // Hero — ALWAYS fitted to the full window (never re-scaled); on reveal it just nudges
                // left so the creature sits in the visible column while the panel covers the right.
                sphinxStage
                    .frame(width: w, height: h)
                    .offset(x: revealed ? -(panelW * sphinxRevealShiftFraction) : 0)

                // ZODL wordmark + tagline, centered in the left column, fading in with the reveal.
                brandLockup
                    .frame(width: leftRegionW, height: h)
                    .opacity(revealed ? 1 : 0)

                // Get-started panel — parked off the right edge, springs into its slot.
                getStartedPanel
                    .frame(width: panelW, height: h)
                    .offset(x: revealed ? (w - panelW) : w)
            }
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear(perform: runIntro)
    }

    // MARK: - Hero + pulsing eyes

    private var sphinxStage: some View {
        GeometryReader { geo in
            let rect = MacLandingView.fittedRect(in: geo.size, aspect: heroAspect)

            ZStack {
                Asset.Assets.zodlSphinxHero.image
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                // Eye glow — additive soft light over the eye band, breathing between dim and bright.
                RadialGradient(
                    gradient: Gradient(colors: [eyeGlowColor, eyeGlowColor.opacity(0)]),
                    center: .center,
                    startRadius: 0,
                    endRadius: rect.width * eyeGlowWidthFraction * 0.5
                )
                .frame(width: rect.width * eyeGlowWidthFraction, height: rect.width * eyeGlowHeightFraction)
                .blur(radius: eyeGlowBlur)
                .blendMode(.screen)
                // Pulse BEFORE positioning. `scaleEffect` AFTER `.position` scales around the PARENT's
                // center (a positioned view fills its parent), and because the glow sits off-center that
                // drags it up/down as it breathes. Scaling the small framed glow first keeps the pulse
                // anchored on the eye — it grows/shrinks in place, no vertical drift. (To kill the size
                // breath entirely and pulse brightness only, set eyeGlowDimScale == eyeGlowBrightScale.)
                .scaleEffect(eyesGlow ? eyeGlowBrightScale : eyeGlowDimScale)
                .opacity(eyesGlow ? eyeGlowBrightOpacity : eyeGlowDimOpacity)
                .position(
                    x: rect.minX + eyeCenter.x * rect.width,
                    y: rect.minY + eyeCenter.y * rect.height
                )
                .allowsHitTesting(false)
            }
        }
        .opacity(sphinxIn ? 1 : 0)
        .scaleEffect(sphinxIn ? 1 : 1.06)
    }

    // MARK: - Brand lockup (mark + ZODL wordmark + tagline) over the rock

    private var brandLockup: some View {
        VStack(spacing: 0) {
            Spacer()

            HStack(spacing: 10) {
                Asset.Assets.zashiLogo.image
                    .zImage(width: 30, height: 30, color: .white)
                Asset.Assets.zashiTitle.image
                    .zImage(width: 96, height: 24, color: .white)
            }
            .padding(.bottom, 14)

            Text(localizable: .plainOnboardingTagline)
                .zFont(.semiBold, size: 18, color: .white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 56)
        }
    }

    // MARK: - Get-started panel (respects the app's color scheme, like the iOS onboarding root)

    private var getStartedPanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Asset.Assets.zashiLogo.image
                .zImage(width: 52, height: 52, color: Asset.Colors.primary.color)
                .padding(.bottom, 20)

            Text(localizable: .plainOnboardingGetStarted)
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            // Fixed gap (not an expanding Spacer) so the whole block — logo + title + CTAs — stays a
            // unit that the top/bottom Spacers center vertically, rather than title-top / buttons-bottom.
            Spacer().frame(height: 44)

            ZashiButton(
                String(localizable: .plainOnboardingButtonRestoreWallet),
                type: .tertiary
            ) {
                store.send(.importExistingWallet)
            }
            .accessibilityIdentifier(AccessibilityID.Onboarding.restoreWallet)
            .padding(.bottom, 10)

            ZashiButton(String(localizable: .plainOnboardingButtonCreateNewWallet)) {
                store.send(.createNewWalletTapped)
            }
            .accessibilityIdentifier(AccessibilityID.Onboarding.createWallet)

            // Bottom Spacer mirrors the top one so the content block sits vertically centered (with a
            // 24pt minimum margin) instead of pinned to the bottom by fixed padding.
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Respect the app's light/dark setting — same coloring as the iOS onboarding root (and the
        // pre-landing macOS root): the adaptive onboarding gradient, with the logo / title / ZashiButtons
        // resolving their Design colors against `@Environment(\.colorScheme)`. (Previously this was pinned
        // to a white `.light` card; the sphinx side stays dark, branding stays white, regardless.)
        .applyOnboardingScreenBackground()
        // Soft depth where the panel meets the dark hero.
        .shadow(color: .black.opacity(0.35), radius: 18, x: -8, y: 0)
    }

    // MARK: - Intro choreography

    private func runIntro() {
        // Hero settles in.
        withAnimation(.easeOut(duration: 0.9)) {
            sphinxIn = true
        }
        // Eyes begin to breathe (slightly delayed so they "wake up" after the hero lands).
        withAnimation(.easeInOut(duration: eyeGlowPulseSeconds).repeatForever(autoreverses: true).delay(0.4)) {
            eyesGlow = true
        }
        // Hold the hero, then reveal the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.8)) {
                revealed = true
            }
        }
    }

    // MARK: - Geometry

    /// The rect a `scaledToFit` image of `aspect` (w/h) occupies inside `container`, centered. Used to
    /// anchor the eye glow to the art regardless of window size.
    static func fittedRect(in container: CGSize, aspect: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0, aspect > 0 else { return .zero }
        let containerAspect = container.width / container.height
        let width: CGFloat
        let height: CGFloat
        if containerAspect > aspect {
            // Container is wider than the art → the art is height-limited (pillarboxed).
            height = container.height
            width = height * aspect
        } else {
            // Container is taller/narrower → the art is width-limited (letterboxed).
            width = container.width
            height = width / aspect
        }
        return CGRect(
            x: (container.width - width) / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }
}
#endif
