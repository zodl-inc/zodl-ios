//
//  LedgerStepComponents.swift
//  Zashi
//
//  MOB-2020: the shared layout Figma's Ledger connect flow reuses across the intro and every
//  numbered step (node 1599:12387's frame) -- the nav-bar step title, the wordmark/title/subtitle
//  header, the numbered checklist card (steps 1 and 3), the numbered overview list (the intro
//  only), the info callout, and the number badge the checklist and overview rows both draw from.
//  Plain `String` inputs and no store dependency, so the intro (AddLedgerHWWalletView),
//  LedgerTurnOnView, LedgerDevicePickerView, LedgerOpenAppView and LedgerApproveOnDeviceView can
//  all build on it.
//
//  Also home to `LedgerWaitingIndicator` (Figma's "Waiting Indicator", node 1439:28709): step 4's
//  approve screen and the send confirmation flow's Ledger sign sheet (LedgerSignSheet.swift) both
//  draw their spinner-plus-title status from it, so it lives here rather than in either feature's
//  own file.
//
//  And `LedgerDeviceCard` (Figma 1635:250): step 2's device picker and the sign sheet's own
//  `.selectingDevice` state draw the same card from it -- the label only, each screen keeps its
//  own `Button` and tap action around it.
//

import SwiftUI
@preconcurrency import ZcashLightClientKit

// MARK: - Nav title

extension View {
    /// The shared step-screen nav bar title: two centred lines -- `ledger.step.navTitle` in
    /// text-tertiary above, `ledger.step.progress` (`step` of `totalSteps`) in text-primary below.
    /// The intro screen has no title at all (Figma 1599:11237) and never calls this.
    func ledgerStepNavTitle(step: Int, totalSteps: Int = 4) -> some View {
        zashiTitle {
            VStack(spacing: 0) {
                Text(localizable: .ledgerStepNavTitle)
                    .zFont(size: 14, style: Design.Text.tertiary)

                Text(localizable: .ledgerStepProgress(step, totalSteps))
                    .zFont(.medium, size: 14, style: Design.Text.primary)
            }
        }
    }
}

// MARK: - Header

/// The wordmark (40 pt high), 24 pt below it the title (semibold 24/30 text-primary), 8 pt below
/// that the subtitle (regular 14/20). `subtitleColor` is a parameter because step 4's subtitle
/// uses text-primary instead of the text-tertiary every other step/the intro uses.
struct LedgerStepHeader: View {
    let title: String
    let subtitle: String
    let subtitleColor: Colorable

    init(title: String, subtitle: String, subtitleColor: Colorable = Design.Text.tertiary) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Asset.Assets.Partners.ledgerTitleLogo.image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 40)

            Text(title)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)

            Text(subtitle)
                .zFont(size: 14, style: subtitleColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }
}

// MARK: - Number badge

/// The 24 pt number circle the checklist card and the overview list both draw their rows from --
/// filled `Design.Surfaces.bgTertiary`, the number centred, semibold 10 text-tertiary.
struct LedgerStepNumberBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let number: Int

    var body: some View {
        Text("\(number)")
            .zFont(.semiBold, size: 10, style: Design.Text.tertiary)
            .frame(width: 24, height: 24)
            .background {
                Circle()
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
            }
    }
}

// MARK: - Checklist card (steps 1 and 3)

private struct LedgerStepChecklistRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LedgerStepNumberBadge(number: number)

            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Background `Design.Surfaces.bgSecondary`, corner radius 16, padding 16, 16 pt between rows;
/// always the full content width, however short its rows are.
struct LedgerStepChecklistCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                LedgerStepChecklistRow(number: index + 1, text: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }
}

// MARK: - Overview list (intro only)

private struct LedgerStepOverviewRow: View {
    let number: Int
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            LedgerStepNumberBadge(number: number)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text(message)
                    .zFont(size: 14, style: Design.Text.tertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// No card, 16 pt between rows; each row is the number badge, a medium 14/20 text-primary title
/// and, 2 pt below, a regular 14/20 text-tertiary message.
struct LedgerStepOverviewList: View {
    struct Item {
        let title: String
        let message: String

        init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    let items: [Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                LedgerStepOverviewRow(number: index + 1, title: item.title, message: item.message)
            }
        }
    }
}

// MARK: - Info callout

/// Background `Design.Utility.HyperBlue._50`, corner radius 16, padding 16, always the full
/// content width; a leading 20 pt outlined `alertCircleOutline` (Figma's `alert-circle`) tinted
/// `HyperBlue._600`; 12 pt gap to a semibold 14/20 title and, 4 pt below, a regular 12/16 message,
/// both `HyperBlue._600`. Deliberately not `ZashiInfoCallout`, whose values don't match this Figma
/// callout.
struct LedgerStepCallout: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Asset.Assets.Icons.alertCircleOutline.image
                .zImage(size: 20, style: Design.Utility.HyperBlue._600)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .zFont(.semiBold, size: 14, style: Design.Utility.HyperBlue._600)

                Text(message)
                    .zFont(size: 12, style: Design.Utility.HyperBlue._600)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Utility.HyperBlue._50.color(colorScheme))
        }
    }
}

// MARK: - Device card (step 2 picker, sign sheet)

/// The Ledger row Figma draws as a single card (node 1635:250): step 2's device picker and the
/// sign sheet's own device list both draw this same label -- each screen keeps its own `Button`
/// and tap action around it. Corner radius 12 (`Design.Radius._xl`), `bgPrimary` fill,
/// `strokeSecondary` 1 pt (2 pt `bgAlt` when selected, with Figma's small card shadow), padding
/// 12 vertical and 16 horizontal; a 40 pt icon circle, 12 pt gap, then the device's own name in
/// semibold 14 on one line, then a 20 pt radio.
struct LedgerDeviceCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let device: LedgerBluetoothDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Asset.Assets.Partners.ledgerMark.image
                .resizable()
                .frame(width: 24, height: 24)
                .padding(8)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgAlt.color(colorScheme))
                }
                .padding(.trailing, 12)

            Text(device.name ?? device.model.productName)
                .zFont(.semiBold, size: 14, style: Design.Text.primary)
                .lineLimit(1)

            Spacer()

            radio(isSelected: isSelected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .stroke(
                            isSelected
                            ? Design.Surfaces.bgAlt.color(colorScheme)
                            : Design.Surfaces.strokeSecondary.color(colorScheme),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
        }
        // Figma's small card shadow, the same two-layer pair used across the app -- shown only
        // for the selected row, via opacity rather than branching the view so the row's identity
        // (and any implicit animation) stays stable across selection changes.
        .shadow(color: .black.opacity(isSelected ? 0.02 : 0), radius: 0.66667, x: 0, y: 1.33333)
        .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 1.33333, x: 0, y: 1.33333)
        // The icon, name and radio read as one VoiceOver element -- the row's own Button, at
        // each call site, carries this same label -- rather than a button followed by a
        // separately announced radio; `.isSelected` replaces the radio's own state for VoiceOver.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func radio(isSelected: Bool) -> some View {
        if isSelected {
            Circle()
                .fill(Design.Btns.Primary.bg.color(colorScheme))
                .frame(width: 20, height: 20)
                .overlay {
                    Asset.Assets.check.image
                        .zImage(size: 12, style: Design.Btns.Primary.fg)
                }
        } else {
            Circle()
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                .frame(width: 20, height: 20)
                .overlay {
                    Circle()
                        .stroke(Design.Checkboxes.offStroke.color(colorScheme), lineWidth: 1)
                }
        }
    }
}

// MARK: - Waiting indicator

/// Figma "Waiting Indicator" (node 1439:28709): a 24 pt `loading-02` spinner that completes one
/// turn per second, 12 pt below it a semibold 16 text-primary title, and, only when `subtitle` is
/// given, a regular 14 text-primary line 4 pt under that -- all centred and at most 280 pt wide.
/// `.fixedSize(horizontal: false, vertical: true)` on both lines keeps long text wrapping instead
/// of truncating inside a host that re-measures height, such as the sign sheet's `zashiSheet`.
struct LedgerWaitingIndicator: View {
    @State private var isRotating = false

    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 12) {
            Asset.Assets.Icons.loading.image
                .zImage(size: 24, style: Design.Text.primary)
                .rotationEffect(.degrees(isRotating ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isRotating)
                .onAppear { isRotating = true }

            VStack(spacing: 4) {
                Text(title)
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .zFont(size: 14, style: Design.Text.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 280)
    }
}
