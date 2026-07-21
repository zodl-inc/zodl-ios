//
//  MigrationBroadcastFailureSheetView.swift
//  zodl
//
//  Shared broadcast-failure sheet content for migration screens (R9-T1, MOB-1497 remediation
//  finding 15): `MigrationSendingView` and `MigrationNoteSplitView` each carried a byte-for-byte
//  identical ~97-line `failureSheetContent`/`failureSheetTitle`/`failureSheetBody`/
//  `failureSheetButtons` group switching on `MigrationBroadcastFailureRoute` (R14-R17) — extracted
//  here so the compliance-critical copy/routing can't drift between the two screens. Takes plain
//  values and closures rather than a store: `MigrationSending` and `MigrationNoteSplit` have
//  distinct `Action` types, so a shared TCA feature isn't a fit here — each call site scopes its
//  own store into these closures instead. A third screen (`MigrationTransferPlan`) adopts this
//  same component in a later task.
//
//  No Figma exists for this section (copy source is the R7-T3 brief's §8); `nil`, `.retryRotated`,
//  and `.plainRetry` all render the same existing generic content (R16's rotation is silent).
//

import SwiftUI

struct MigrationBroadcastFailureSheetView: View {
    @Environment(\.colorScheme) private var colorScheme

    let failureKind: MigrationBroadcastFailureRoute?
    let cancelTapped: () -> Void
    let proceedWithoutTorTapped: () -> Void
    let retryTapped: () -> Void
    let useSyncServerTapped: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(failureSheetTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(failureSheetBody)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            failureSheetButtons
        }
    }

    private var failureSheetTitle: String {
        switch failureKind {
        case .torFirstRunChoice:
            return String(localizable: .migrationFailureTorFirstRunTitle)
        case .torHold:
            return String(localizable: .migrationFailureTorHoldTitle)
        case .providerExhausted:
            return String(localizable: .migrationFailureProviderExhaustedTitle)
        case .retryRotated, .plainRetry, nil:
            return String(localizable: .migrationNoteSplitFailedTitle)
        }
    }

    private var failureSheetBody: String {
        switch failureKind {
        case .torFirstRunChoice:
            return String(localizable: .migrationFailureTorFirstRunBody)
        case .torHold:
            return String(localizable: .migrationFailureTorHoldBody)
        case .providerExhausted(let torEnabled):
            return torEnabled
                ? String(localizable: .migrationFailureProviderExhaustedBodyTorOn)
                : String(localizable: .migrationFailureProviderExhaustedBodyTorOff)
        case .retryRotated, .plainRetry, nil:
            return String(localizable: .migrationNoteSplitFailedBody)
        }
    }

    @ViewBuilder private var failureSheetButtons: some View {
        switch failureKind {
        case .torFirstRunChoice:
            ZashiButton(String(localizable: .generalCancel), type: .secondary) {
                cancelTapped()
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationTorSheetOffWarningProceed), type: .secondary) {
                proceedWithoutTorTapped()
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationNoteSplitRetry)) {
                retryTapped()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)

        case .providerExhausted:
            ZashiButton(String(localizable: .migrationFailureProviderExhaustedKeepWaiting), type: .secondary) {
                cancelTapped()
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationFailureProviderExhaustedUseSyncServer)) {
                useSyncServerTapped()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)

        case .torHold, .retryRotated, .plainRetry, nil:
            ZashiButton(String(localizable: .generalCancel), type: .secondary) {
                cancelTapped()
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationNoteSplitRetry)) {
                retryTapped()
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

// MARK: - Previews

#Preview("Tor first-run choice") {
    MigrationBroadcastFailureSheetView(
        failureKind: .torFirstRunChoice,
        cancelTapped: { },
        proceedWithoutTorTapped: { },
        retryTapped: { },
        useSyncServerTapped: { }
    )
}

#Preview("Tor hold") {
    MigrationBroadcastFailureSheetView(
        failureKind: .torHold,
        cancelTapped: { },
        proceedWithoutTorTapped: { },
        retryTapped: { },
        useSyncServerTapped: { }
    )
}

#Preview("Provider exhausted") {
    MigrationBroadcastFailureSheetView(
        failureKind: .providerExhausted(torEnabled: true),
        cancelTapped: { },
        proceedWithoutTorTapped: { },
        retryTapped: { },
        useSyncServerTapped: { }
    )
}

#Preview("Generic (nil)") {
    MigrationBroadcastFailureSheetView(
        failureKind: nil,
        cancelTapped: { },
        proceedWithoutTorTapped: { },
        retryTapped: { },
        useSyncServerTapped: { }
    )
}
