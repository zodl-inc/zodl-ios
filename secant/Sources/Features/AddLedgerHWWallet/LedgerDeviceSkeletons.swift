//
//  LedgerDeviceSkeletons.swift
//  Zashi
//
//  MOB-2020: the placeholder device rows PR 127 first drew inline in LedgerDevicePickerView
//  (`skeletonDeviceList()`/`skeletonCard()`), now shared with the Approve on Your Device screen --
//  as Android's `LedgerDeviceSkeletons.kt` shares them between its scan and handshake screens. A
//  shimmer flag and a trailing overlay slot are the only two things that differ between callers:
//  the picker lays its own 164 pt bottom fade over the slot exactly as it always has (unchanged
//  look), and the approve screen lays a fade that turns fully opaque halfway down the rows, with
//  the waiting indicator, over it instead. `accessibilityHidden` covers only the decorative rows,
//  not the slot, so a caller whose overlay carries real copy (the approve screen's waiting title
//  and subtitle) stays readable to VoiceOver.
//

import SwiftUI

struct LedgerDeviceSkeletons<Overlay: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let isShimmering: Bool
    @ViewBuilder let overlay: () -> Overlay

    init(isShimmering: Bool, @ViewBuilder overlay: @escaping () -> Overlay = { EmptyView() }) {
        self.isShimmering = isShimmering
        self.overlay = overlay
    }

    var body: some View {
        VStack(spacing: 12) {
            skeletonCard()
            skeletonCard()
            skeletonCard()
        }
        .accessibilityHidden(true)
        .overlay {
            overlay()
        }
    }

    // Same placeholder chain as `NoTransactionPlaceholder`: `.fill(...)` -> `.shimmer(...)` ->
    // `.clipShape(...)` -> `.frame(...)`, one per shape, so the shimmer gradient is clipped to
    // each shape rather than the shape's bounding box.
    @ViewBuilder private func skeletonCard() -> some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                .shimmer(isShimmering)
                .clipShape(Circle())
                .frame(width: 32, height: 32)
                .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: Design.Radius._xs)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .shimmer(isShimmering)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius._xs))
                    .frame(width: 100, height: 16)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    .shimmer(isShimmering)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: 68, height: 12)
            }

            Spacer()

            RoundedRectangle(cornerRadius: Design.Radius._sm)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                .shimmer(isShimmering)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius._sm))
                .frame(width: 20, height: 20)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                }
        }
    }
}
