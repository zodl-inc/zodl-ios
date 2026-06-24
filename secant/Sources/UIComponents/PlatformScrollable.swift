//
//  PlatformScrollable.swift
//  Zashi
//
//  A screen container that scrolls on iOS but not on macOS.
//
//  iOS targets small screens, so content lives in a `ScrollView` and the CTA flows directly under the
//  form (scrolling into view). macOS runs in a fixed, roomy window where scrolling a short form feels
//  wrong and CTAs belong pinned at the bottom. So on macOS this is a FILLING `VStack` instead — which
//  lets a screen place a `#if os(macOS) Spacer()` between its form and its CTA to push the CTA to the
//  bottom, with no scroll. (Mirrors the PlatformBindable idea: one name, platform-correct behavior.)
//
//  Usage (the Send spike):
//      PlatformScrollable {
//          form
//  #if os(macOS)
//          Spacer()                 // pins the CTA to the bottom on macOS; absent (and harmless) on iOS
//  #endif
//          reviewCTA
//      }
//  For the macOS Spacer to expand, the content's own stack must fill the height too — a screen that
//  nests its form in a VStack should give that VStack `.frame(maxHeight: .infinity)` on macOS.
//

import SwiftUI

struct PlatformScrollable<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
#if os(macOS)
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        ScrollView {
            content
        }
#endif
    }
}
