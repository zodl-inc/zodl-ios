//
//  MigrationResidualView.swift
//  zodl
//
//  MOB-1749 "Remaining Orchard Funds" — Figma 6855:24967 (offered), 6855:25169 (locking),
//  6855:25254 (locked), explainer sheet 6855:25052. Header badge + title + subtitle and a
//  continuous summary card (two rows, plus a Locked in Orchard middle row when an earlier
//  visit locked part of the balance) sit at the top; the decision callout and the primary CTA
//  are anchored at the bottom, as the frames draw them. No back button (the frame hides it, exactly
//  like Migration Complete): the exits are Lock balance → Got it, or Migrate anyway. The trailing
//  help button opens the shared explainer sheet. Every decision piece is the shared
//  `MigrationLockResolutionViews` implementation Migration Complete renders.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationResidualView: View {
    @Perception.Bindable var store: StoreOf<MigrationResidual>

    init(store: StoreOf<MigrationResidual>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                MigrationLockBadge()
                    .padding(.top, 12)

                Text(localizable: .migrationResidualTitle)
                    .zFont(.semiBold, size: 28, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)

                Text(localizable: .migrationResidualSubtitle)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                summaryCard
                    .padding(.top, 24)

                Spacer()

                MigrationLockCallout(
                    resolution: store.lock.resolution,
                    offeredBodyMarkdown: String(localizable: .migrationResidualDustBody("^[\(amountText)](style: 'boldPrimary')")),
                    lockedBodyMarkdown: String(localizable: .migrationCompleteLockedBody("^[\(amountText)](style: 'boldPrimary')")),
                    isMigrateAnywayDisabled: store.lock.resolution == .locking || store.lock.isMigratingAnyway,
                    onMigrateAnyway: { store.send(.lock(.migrateAnywayTapped)) }
                )
                .padding(.bottom, 20)

                primaryButton
                    .padding(.bottom, 24)
            }
            .padding(.vertical, 1)
            .screenHorizontalPadding()
            .applyScreenBackground()
            .onAppear { store.send(.lock(.onAppear)) }
            .navigationBarBackButtonHidden()
            .navigationBarItems(trailing: helpButton)
            .alert($store.scope(state: \.alert, action: \.alert))
            // `$store.<flag>.sending` rather than a hand-rolled `Binding(get:set:)` — see
            // MigrationCompleteView's identical note on perception tracking.
            .zashiSheet(
                isPresented: $store.lock.isLockExplainerPresented.sending(\.lock.lockExplainerPresentedChanged)
            ) {
                MigrationLockExplainerSheetContent {
                    store.send(.lock(.lockExplainerDismissed))
                }
            }
        }
    }

    // MARK: - Nav bar

    @ViewBuilder private var helpButton: some View {
        MigrationLockHelpButton {
            store.send(.lock(.lockExplainerHelpTapped))
        }
    }

    // MARK: - Summary card

    private var amountText: String {
        "\(store.orchardBalance.decimalString()) ZEC"
    }

    /// Figma 6855:25020: one continuous card — the rows share the `bgSecondary` fill with no
    /// inter-row gap (`isContinuous`). MOB-1749 review fix: a residual the user locked on an
    /// EARLIER visit is still part of the Orchard pool — hiding it made this screen disagree with
    /// the Balances breakdown and never name the amount that earlier visit locked, so a nonzero
    /// locked balance gets its own middle row. Wave 2: pending Orchard value gets its own
    /// conditional row for the same reason — the rows must sum to the pool total the Balances
    /// breakdown shows.
    @ViewBuilder private var summaryCard: some View {
        VStack(spacing: 0) {
            MigrationDetailRow(
                title: String(localizable: .migrationResidualRowIronwood),
                value: "\(store.ironwoodBalance.decimalString()) ZEC",
                rowAppereance: .top,
                isContinuous: true
            )

            if store.lockedOrchardBalance > .zero {
                MigrationDetailRow(
                    title: String(localizable: .migrationResidualRowLocked),
                    value: "\(store.lockedOrchardBalance.decimalString()) ZEC",
                    rowAppereance: .middle,
                    isContinuous: true
                )
            }

            if store.pendingOrchardBalance > .zero {
                MigrationDetailRow(
                    title: String(localizable: .migrationResidualRowPending),
                    value: "\(store.pendingOrchardBalance.decimalString()) ZEC",
                    rowAppereance: .middle,
                    isContinuous: true
                )
            }

            MigrationDetailRow(
                title: String(localizable: .migrationResidualRowOrchard),
                value: amountText,
                rowAppereance: .bottom,
                isContinuous: true
            )
        }
    }

    // MARK: - Primary button

    @ViewBuilder private var primaryButton: some View {
        MigrationLockPrimaryButton(
            resolution: store.lock.resolution,
            onLock: { store.send(.lock(.lockBalanceTapped)) },
            onGotIt: { store.send(.gotItTapped) }
        )
        // Wave 2: both CTAs this renders (Lock balance, Got it) are inert while the sweep
        // hand-over is in flight — the reducer backstops the same rule.
        .disabled(store.lock.isMigratingAnyway)
    }
}

// MARK: - Previews

#Preview("Offered") {
    NavigationView {
        MigrationResidualView(
            store: StoreOf<MigrationResidual>(
                initialState: MigrationResidual.State(
                    orchardBalance: Zatoshi(800_000),
                    lockedOrchardBalance: Zatoshi(500_000),
                    ironwoodBalance: Zatoshi(1_245_000_000)
                )
            ) {
                MigrationResidual()
            }
        )
    }
}

#Preview("Locking") {
    NavigationView {
        MigrationResidualView(
            store: StoreOf<MigrationResidual>(
                initialState: MigrationResidual.State(
                    orchardBalance: Zatoshi(800_000),
                    ironwoodBalance: Zatoshi(1_245_000_000),
                    resolution: .locking
                )
            ) {
                MigrationResidual()
            }
        )
    }
}

#Preview("Locked") {
    NavigationView {
        MigrationResidualView(
            store: StoreOf<MigrationResidual>(
                initialState: MigrationResidual.State(
                    orchardBalance: Zatoshi(800_000),
                    ironwoodBalance: Zatoshi(1_245_000_000),
                    resolution: .locked
                )
            ) {
                MigrationResidual()
            }
        )
    }
}
