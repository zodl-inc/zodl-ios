//
//  MigrationRestartView.swift
//  zodl
//
//  "Restart Migration" (Figma: Advanced Settings → Migration Settings → Bottom Sheet).
//
//  Two surfaces, one store: the screen states what a restart costs, and the sheet takes the
//  irreversible confirmation. The sheet is presented through `zashiSheet`, matching every other
//  migration confirmation in the app.
//
//  THE BUSY RULE (Lukas, 2026-08-07): "add a spinner, disable all buttons so nothing else
//  interferes." While `isRestarting` is true the confirm button wears a `ProgressView`, BOTH sheet
//  buttons are disabled, the sheet cannot be swiped away (the store refuses the binding write), and
//  the screen's own Next is disabled behind it. One engine call, no second entrance.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationRestartView: View {
    @Environment(\.colorScheme) private var colorScheme

    @PlatformBindable var store: StoreOf<MigrationRestart>

    init(store: StoreOf<MigrationRestart>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        headerIcons
                            .padding(.top, 24)
                            .padding(.bottom, 20)

                        Text(String(localizable: .migrationRestartTitle))
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(String(localizable: .migrationRestartDesc))
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                            .padding(.bottom, 20)

                        summaryCard
                            .padding(.bottom, 12)

                        warningBox
                    }
                    .screenHorizontalPadding()
                }

                Spacer(minLength: 24)

                supportNote
                    .screenHorizontalPadding()
                    .padding(.bottom, 20)

                ZashiButton(String(localizable: .generalNext)) {
                    store.send(.nextTapped)
                }
                .disabled(!store.isRestartPossible || store.isRestarting)
                .screenHorizontalPadding()
                .padding(.bottom, 24)
            }
            .applyScreenBackground()
            .zashiNavBarTitleDisplayMode(.inline)
            .zashiBack(store.isRestarting)
            .onAppear { store.send(.onAppear) }
            .zashiSheet(
                isPresented: $store.isConfirmationPresented.sending(\.confirmationPresentedChanged)
            ) {
                // Same wrapper every migration sheet uses: a `.sheet` closure renders in a NEW view
                // tree, so store reads inside need their own tracking scope or the sheet never
                // re-renders when `isRestarting` flips.
                WithPerceptionTracking {
                    confirmationSheetContent
                }
            }
        }
    }

    // MARK: - Screen

    /// The paired badge from the design: the Zodl mark beside the migration glyph (`coinsSwap` —
    /// the same icon every other migration surface uses). Composed from existing assets; a direct
    /// export can replace it without touching anything else.
    private var headerIcons: some View {
        HStack(spacing: -8) {
            Asset.Assets.Icons.zashiLogoSqBold.image
                .zImage(size: 20, style: Design.Text.opposite)
                .padding(12)
                .background {
                    Circle()
                        .fill(Design.Text.primary.color(colorScheme))
                }

            Asset.Assets.Icons.coinsSwap.image
                .zImage(size: 20, style: Design.Text.primary)
                .padding(12)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                }
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            summaryRow(
                label: String(localizable: .migrationRestartMigrated),
                value: String(localizable: .migrationRestartMigratedValue(store.doneTransfers, store.totalTransfers))
            )

            summaryRow(
                label: String(localizable: .migrationRestartRemainingBalance),
                value: "\(store.remainingBalance.decimalString()) ZEC"
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .zFont(size: 14, style: Design.Text.tertiary)

            Spacer(minLength: 8)

            Text(value)
                .zFont(.medium, size: 14, style: Design.Text.primary)
        }
    }

    /// The irreversibility warning — the one red thing on the screen, because it is the one
    /// consequence the user cannot walk back.
    private var warningBox: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(localizable: .migrationRestartWarning))
                .zFont(size: 14, style: Design.Utility.ErrorRed._800)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            Spacer(minLength: 0)

            Asset.Assets.infoOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._800)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Utility.ErrorRed._100.color(colorScheme))
        }
    }

    private var supportNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Asset.Assets.infoOutline.image
                .zImage(size: 20, style: Design.Text.tertiary)

            Text(String(localizable: .migrationRestartSupportNote))
                .zFont(size: 12, style: Design.Text.tertiary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }

    // MARK: - Confirmation sheet

    private var confirmationSheetContent: some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(String(localizable: .migrationRestartConfirmTitle))
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(
                String(
                    localizable: .migrationRestartConfirmDesc(
                        "\(store.remainingBalance.decimalString()) ZEC",
                        store.doneTransfers
                    )
                )
            )
            .zFont(size: 14, style: Design.Text.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .padding(.bottom, 24)

            summaryRow(
                label: String(localizable: .migrationRestartRemainingToMigrate),
                value: "\(store.remainingBalance.decimalString()) ZEC"
            )
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(Design.Surfaces.bgPrimary.color(colorScheme))
            }
            .padding(.bottom, 20)

            // THE BUSY RULE: spinner on the acting button, both buttons dead, until the engine
            // answers. `.disabled(true)` on the spinner branch rather than a bare visual swap —
            // the tap must be refused, not merely discouraged.
            if store.isRestarting {
                ZashiButton(
                    String(localizable: .migrationRestartConfirmCta),
                    type: .destructive1,
                    accessoryView: ProgressView()
                ) { }
                    .disabled(true)
                    .padding(.bottom, 8)
            } else {
                ZashiButton(
                    String(localizable: .migrationRestartConfirmCta),
                    type: .destructive1
                ) {
                    store.send(.confirmRestartTapped)
                }
                .padding(.bottom, 8)
            }

            ZashiButton(String(localizable: .generalCancel)) {
                store.send(.cancelTapped)
            }
            .disabled(store.isRestarting)
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        MigrationRestartView(store: .initial)
    }
}

// MARK: Placeholders

extension MigrationRestart.State {
    static let initial = MigrationRestart.State()
}

extension StoreOf<MigrationRestart> {
    static let initial = StoreOf<MigrationRestart>(
        initialState: .initial
    ) {
        MigrationRestart()
    }
}
