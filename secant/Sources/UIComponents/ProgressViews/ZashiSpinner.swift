//
//  ZashiSpinner.swift
//  Zodl
//
//  Created by Lukáš Korba on 2026-07-04.
//

import SwiftUI

/// The ONE circular activity spinner ([B4-27] consolidation — every inline `ProgressView()`
/// call site now renders this).
///
/// On iOS it renders EXACTLY what the call sites rendered before (a bare `ProgressView`,
/// or `CircularProgressViewStyle(tint: iosTint)` when a tint is passed) — zero visual
/// change on iPhone, per the never-break-iOS rule.
///
/// On macOS the system spinner is wrong twice (field, 2026-07-04):
/// - it draws the REGULAR-size NSProgressIndicator (~20 pt) — oversized against our
///   14–16 pt rows and buttons, stretching heights wherever it appears (several sites had
///   hand-patched with `.scaleEffect(0.7)`, which shrinks the PIXELS but not the LAYOUT
///   BOX, so heights stayed broken);
/// - it IGNORES SwiftUI tinting — always the system gray, which is white-ish in dark mode
///   and therefore INVISIBLE on a light primary button (the "Keep Zodl open" OK spinner).
/// So macOS renders a small custom arc that lays out at `size` (default 14 pt — the box,
/// not just the pixels) and honors a real color per `macTint`.
struct ZashiSpinner: View {
    /// How the macOS arc is colored. iOS ignores this entirely.
    enum MacTint {
        /// Adaptive neutral (`Color.secondary`) — spinners on screen backgrounds.
        case auto
        /// INHERIT the surrounding foreground color — spinners rendered as a `ZashiButton`
        /// accessory. The button already applies its per-TYPE, per-STATE label color to the
        /// whole label row (`.zForegroundColor(fgColor())`, ZashiButton body), so the arc
        /// strokes with exactly the color of the title next to it: dark-on-light primary in
        /// dark mode, light-on-dark in light mode, ghost/secondary/disabled all correct —
        /// no per-surface inversion logic needed, the button IS the source of truth.
        case buttonAccessory
        /// An explicit color (call sites that already compute a scheme-aware tint).
        case fixed(Color)
    }

    /// iOS-only tint: `nil` renders the bare system `ProgressView` (whatever the call site
    /// rendered before this consolidation); non-nil keeps its previous
    /// `CircularProgressViewStyle(tint:)`.
    var iosTint: Color?
    var macTint: MacTint
    /// macOS layout box; iOS uses the system size (unchanged).
    var size: CGFloat

    init(iosTint: Color? = nil, macTint: MacTint = .auto, size: CGFloat = 14) {
        self.iosTint = iosTint
        self.macTint = macTint
        self.size = size
    }

    var body: some View {
#if os(macOS)
        MacArcSpinner(tint: resolvedMacTint, size: size)
#else
        if let iosTint {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: iosTint))
        } else {
            ProgressView()
        }
#endif
    }

    /// `nil` = stroke with the INHERITED foreground (the `.buttonAccessory` contract).
    private var resolvedMacTint: Color? {
        switch macTint {
        case .auto: return Color.secondary
        case .buttonAccessory: return nil
        case .fixed(let color): return color
        }
    }
}

#if os(macOS)
/// Pure-SwiftUI indeterminate arc: correct layout box + honors real colors (both of
/// which the NSProgressIndicator-backed system spinner gets wrong on macOS).
/// `tint == nil` strokes with the INHERITED foreground color — inside a `ZashiButton`
/// that is the button's own label color, so the spinner always contrasts with the CTA
/// surface exactly like the title does.
private struct MacArcSpinner: View {
    let tint: Color?
    let size: CGFloat

    @State private var isSpinning = false

    var body: some View {
        arc
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                .linear(duration: 0.9).repeatForever(autoreverses: false),
                value: isSpinning
            )
            .onAppear { isSpinning = true }
    }

    @ViewBuilder private var arc: some View {
        let shape = Circle().trim(from: 0.18, to: 1)
        let strokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round)
        if let tint {
            shape.stroke(tint, style: strokeStyle)
        } else {
            // No explicit color: draws with the current foreground style (the inherited
            // `.foregroundColor` — ZashiButton's per-type label color).
            shape.stroke(style: strokeStyle)
        }
    }
}
#endif
