//
//  LedgerIssueSheetContent.swift
//  Zashi
//
//  MOB-2020: the shared sheet body Figma's "Error States and Edge Cases" (node 1073:12817, e.g.
//  1073:12880 and 1073:12961) draws for every Ledger failure -- an alert icon, a title, a
//  message and one button. `AddLedgerHWWallet`'s device picker is the first caller; every later
//  Ledger error sheet (the sign sheet included) reuses this content instead of its own copy.
//

import SwiftUI

/// Plain content for a `zashiSheet` -- no store, no `.onAppear`. The caller supplies the
/// `LedgerIssue` being shown and which `Context` it is shown in; this view reads the title,
/// message and primary button straight off `issue`, unless `primaryAction` overrides it (the
/// sign sheet does this once "Open System Settings" has already been tapped once -- see
/// `LedgerSigning.State.failedPrimaryAction`). An optional `secondary` button (e.g. Cancel) is
/// shown below the primary one.
struct LedgerIssueSheetContent: View {
    /// A second, lower-emphasis button shown below the primary one.
    struct SecondaryButton {
        let title: String
        let type: ZashiButton<EmptyView, EmptyView>.`Type`
        let action: () -> Void
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    let issue: LedgerIssue
    let context: LedgerIssue.Context
    /// Overrides `issue.primaryAction(in: context)` for both the button's title and its
    /// open-Settings behaviour, when set.
    var primaryAction: LedgerIssue.PrimaryAction? = nil
    let onPrimary: () -> Void
    var secondary: SecondaryButton? = nil

    /// `primaryAction` when the caller overrides it, else `issue`'s own action for `context`.
    private var resolvedPrimaryAction: LedgerIssue.PrimaryAction {
        primaryAction ?? issue.primaryAction(in: context)
    }

    /// The same mapping `LedgerIssue.primaryActionTitle(in:)` does, but off `resolvedPrimaryAction`
    /// directly, so an override doesn't have to round-trip back through `issue`/`context` to
    /// recover a title that no longer matches it.
    private var resolvedPrimaryTitle: String? {
        switch resolvedPrimaryAction {
        case .tryAgain: return String(localizable: .ledgerIssueTryAgain)
        case .openSettings: return String(localizable: .ledgerIssueOpenSettings)
        case .goToAccount: return String(localizable: .ledgerIssueGoToAccount)
        case .close: return String(localizable: .generalClose)
        case .none: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertCircleOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .padding(12)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                }

            Text(issue.title(in: context))
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            Text(issue.message(in: context))
                .zFont(size: 14, style: Design.Text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(spacing: 12) {
                if let resolvedPrimaryTitle {
                    ZashiButton(resolvedPrimaryTitle, type: .primary) {
                        if resolvedPrimaryAction == .openSettings,
                           let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                        onPrimary()
                    }
                }

                if let secondary {
                    ZashiButton(secondary.title, type: secondary.type, action: secondary.action)
                }
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        .padding(.bottom, Design.Spacing.sheetBottomSpace)
    }
}
