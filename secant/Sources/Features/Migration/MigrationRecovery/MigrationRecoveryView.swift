//
//  MigrationRecoveryView.swift
//  zodl
//
//  "Reschedule Transfers" / "Transfers No Longer Valid" screen (MOB-1464, Figma S11 · spent
//  2696:5626 / expired 2973:5698). When `isFlowRoot` is set, the back control closes the flow
//  instead of popping (MOB-1466). The `continueTapped` delegate (plan-recreation) is consumed by
//  `MigrationCoordFlowCoordinator` (phase 3).
//
//  PHASE 5: restored from #1930 verbatim except for the SCROLLER SHAPE (see `MigrationEntryView`) —
//  `screenHorizontalPadding()` moved off the column that holds the ScrollView and onto its content
//  and its pinned footer, so the scroll indicator rides the screen edge instead of drawing on top
//  of the numbered bullets.
//

import ComposableArchitecture
import SwiftUI

struct MigrationRecoveryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<MigrationRecovery>

    init(store: StoreOf<MigrationRecovery>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(description)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        Text(localizable: .migrationRecoveryWhatNext)
                            .zFont(.medium, size: 14, style: Design.Text.primary)
                            .padding(.bottom, 12)

                        whatHappensNext
                    }
                    .screenHorizontalPadding()
                    .padding(.vertical, 1)
                }

                // MOB-1458 (final review I3): disabled+spinner while a recovery is in flight — the
                // established button-loading idiom (mirrors `MigrationTransferPlanView`'s `isConfirming`
                // confirm button) so a double-tap can't start a second refresh/restart.
                if store.isRecovering {
                    ZashiButton(
                        String(localizable: .migrationNoteSplitContinue),
                        accessoryView:
                            ProgressView()
                            .progressViewStyle(
                                CircularProgressViewStyle(
                                    tint: Asset.Colors.secondary.color
                                )
                            )
                    ) { }
                    .screenHorizontalPadding()
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                    .disabled(store.isRecovering)
                } else {
                    ZashiButton(String(localizable: .migrationNoteSplitContinue)) {
                        store.send(.continueTapped)
                    }
                    .screenHorizontalPadding()
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .applyPresentationModifier(store: store)
        }
        .applyScreenBackground()
        .onAppear { store.send(.onAppear) }
    }

    // MARK: - Title + description

    private var title: String {
        switch store.reason {
        case .notesSpent:
            return String(localizable: .migrationRecoveryTitleSpent)
        case .expired:
            return String(localizable: .migrationRecoveryTitleExpired)
        }
    }

    private var description: String {
        switch store.reason {
        case .notesSpent:
            return String(localizable: .migrationRecoveryDescSpent(store.firstTransfer, store.lastTransfer))
        case .expired:
            return String(localizable: .migrationRecoveryDescExpired(store.firstTransfer, store.lastTransfer))
        }
    }

    // MARK: - What happens next

    @ViewBuilder private var whatHappensNext: some View {
        VStack(alignment: .leading, spacing: 0) {
            numberedBullet(
                number: 1,
                text: String(localizable: .migrationRecoveryBullet1),
                isLast: false
            )

            numberedBullet(
                number: 2,
                text: String(localizable: .migrationRecoveryBullet2(store.firstTransfer, store.lastTransfer)),
                isLast: false
            )

            numberedBullet(
                number: 3,
                text: String(localizable: .migrationRecoveryBullet3),
                isLast: true
            )
        }
    }

    @ViewBuilder private func numberedBullet(number: Int, text: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Circle()
                    .fill(Design.Text.primary.color(colorScheme))
                    .frame(width: 24, height: 24)
                    .overlay {
                        Text("\(number)")
                            .zFont(.semiBold, size: 11, style: Design.Surfaces.bgPrimary)
                    }

                if !isLast {
                    Rectangle()
                        .fill(Design.Surfaces.bgAlt.color(colorScheme))
                        .frame(width: 2, height: 20)
                }
            }

            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Presentation modifier

private extension View {
    @ViewBuilder func applyPresentationModifier(store: StoreOf<MigrationRecovery>) -> some View {
        if store.isFlowRoot {
            zashiBackV2 {
                store.send(.closeTapped)
            }
        } else {
            zashiBack()
        }
    }
}

// MARK: - Previews

#Preview("Notes spent") {
    NavigationView {
        MigrationRecoveryView(
            store: StoreOf<MigrationRecovery>(
                initialState: MigrationRecovery.State(reason: .notesSpent, firstTransfer: 3, lastTransfer: 5)
            ) {
                MigrationRecovery()
            }
        )
    }
}

#Preview("Expired") {
    NavigationView {
        MigrationRecoveryView(
            store: StoreOf<MigrationRecovery>(
                initialState: MigrationRecovery.State(reason: .expired, firstTransfer: 3, lastTransfer: 5)
            ) {
                MigrationRecovery()
            }
        )
    }
}
