//
//  MigrationReviewTransferView.swift
//  zodl
//
//  "Review Transfer" screen (MOB-1463, Figma S7 · immediate 2867:5924 / manual "3 of 5"
//  2729:8544). `onAppear` loads Amount/Fee live (immediate mode) via the store; when the manual-step
//  variant is a flow re-entry root (`isFlowRoot`), its back control closes the flow instead of
//  popping (MOB-1466). `confirmTapped`'s delegate (`.confirmed` or `.keystoneImmediateSignRequested`) is
//  consumed by `MigrationCoordFlowCoordinator` (phase 3).
//
//  MOB-1478 (W4): immediate mode's `confirmTapped` now silently splits first when needed — a failure
//  presents the same Cancel/Retry bottom sheet `MigrationNoteSplit` uses (this screen had no failure
//  path before).
//
//  MOB-1497 (T4, Q3'26 canvas): the R13 broadcast-server disclosure footer (added in T2 for the
//  immediate mode, whether the Tor sheet was skipped or confirmed) is retired per the new designs —
//  the footer, its `disclosureFooter` builder, and the store's `broadcastDisclosureHost` state are
//  removed. Migration screens no longer name which server will receive transfers.
//
//  MOB-1497 (T7, Q3'26 canvas · 3491:11447 "Review Transfer 3 (A)"): manual mode's `description`
//  briefly became the three-sentence composition `descManual + reviewAndConfirm + cannotBeUndone`,
//  with a `ZashiInfoCallout(.warning)` "Privacy Disclaimer" card below `detailRows`.
//
//  MOB-1513 (Q3'26 canvas · 3491:11612 / dark 4002:30822 "Review Transfer 3 (B)"): supersedes T7's
//  (A) above. Manual mode's `description` is back to the single-sentence `descManual`;
//  `cannotBeUndone` now renders as its own caption line inside `thisTransferBlock`, directly under
//  the "This Transfer" heading, instead of folding into `description`. The Privacy Disclaimer
//  callout is removed outright — no (B) iteration shows it. Immediate mode (`descImmediate`, frame
//  3485:6264) remains untouched throughout — its copy already ends with its own cannot-be-cancelled
//  sentence.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import SwiftUI

struct MigrationReviewTransferView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<MigrationReviewTransfer>
    @Shared(.inMemory(.exchangeRate)) private var currencyConversion: CurrencyConversion?

    init(store: StoreOf<MigrationReviewTransfer>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                // SCROLLER SHAPE: full-bleed ScrollView, `screenHorizontalPadding()` on its CONTENT
                // and on each pinned footer child — never on the column that holds the scroller, or
                // the indicator is inset by the same 24pt and draws ON TOP of the detail rows'
                // values. See `MigrationEntryView` for the full note.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isIconHeaderVisible {
                            // FIGMA PARITY A1-C1 (2026-08-06): vendor-aware, same as
                            // `MigrationEntryView`'s call site. MOB-1468 parameterized the leading
                            // brandmark by account vendor but only updated Entry, so a Keystone
                            // account saw the Keystone mark on Entry and the Zodl mark one screen
                            // later on Review — a wallet-identity flicker mid-flow. Not visible in
                            // the designs, which only draw the software account.
                            MigrationPairedIcons(vendor: store.selectedWalletAccount?.vendor ?? .zcash)
                                .padding(.bottom, 16)
                        }

                        Text(title)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.bottom, 8)

                        Text(description)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)

                        detailRows
                    }
                    .screenHorizontalPadding()
                    .padding(.vertical, 1)
                }

                // MOB-1513 (B4): disabled+spinner while the Keystone PCZT build is in flight (the
                // established button-loading idiom — mirrors `SendConfirmationView`'s `isSending`
                // button).
                if store.isConfirming {
                    ZashiButton(
                        String(localizable: .generalConfirm),
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
                    .disabled(store.isConfirming)
                } else {
                    ZashiButton(String(localizable: .generalConfirm)) {
                        store.send(.confirmTapped)
                    }
                    .screenHorizontalPadding()
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .applyPresentationModifier(store: store)
            .zashiSheet(isPresented: $store.isFailurePresented) {
                failureSheetContent
            }
        }
        .applyScreenBackground()
        .onAppear {
            store.send(.onAppear)
        }
    }

    // MARK: - Header

    private var isIconHeaderVisible: Bool {
        store.mode == .immediate
    }

    // MARK: - Title + description

    private var title: String {
        switch store.mode {
        case .immediate:
            return String(localizable: .migrationReviewTitleImmediate)
        }
    }

    private var description: String {
        switch store.mode {
        case .immediate:
            return String(localizable: .migrationReviewDescImmediate)
        }
    }

    // (The manual-mode "This Transfer" block — `thisTransferBlock`/`thisTransferRow` and the
    // `stepNumber`/`stepTotal` readers — was REMOVED 2026-08-07 with `.manualStep`.)

    // MARK: - Detail rows

    @ViewBuilder private var detailRows: some View {
        VStack(spacing: 0) {
            MigrationDetailRow(
                title: String(localizable: .sendAmount),
                value: "\(store.amount.decimalString()) ZEC",
                rowAppereance: .top
            )

            MigrationDetailRow(
                title: String(localizable: .sendFeeSummary),
                value: "\(store.fee.decimalString()) ZEC",
                rowAppereance: .bottom
            )
        }
    }

    // MARK: - Failure sheet (immediate mode only; MOB-1496 R8-T1 — commit or propose failure)

    /// Mirrors `MigrationNoteSplitView`'s failure sheet shape (same Cancel/Retry layout) — this
    /// screen had no failure path before the silent split moved under its commit (MOB-1478 W4;
    /// removed again in MOB-1496 R8-T1's S1 fix, which made the immediate commit split-free).
    /// MOB-1496 (R8-T1, S3): the copy now depends on `store.failureReason` — a propose failure
    /// (nothing was ever broadcast) uses honest "couldn't load" copy instead of the commit
    /// failure's "couldn't be broadcast" copy.
    @ViewBuilder private var failureSheetContent: some View {
        VStack(spacing: 0) {
            Asset.Assets.Icons.alertOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)

            Text(failureTitle)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Text(failureBody)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)

            ZashiButton(String(localizable: .generalCancel), type: .secondary) {
                store.send(.cancelTapped)
            }
            .padding(.bottom, 12)

            ZashiButton(String(localizable: .migrationNoteSplitRetry)) {
                store.send(.retryTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }

    private var failureTitle: String {
        switch store.failureReason {
        case .propose: return String(localizable: .migrationPlanProposeFailedTitle)
        case .commit, nil: return String(localizable: .migrationNoteSplitFailedTitle)
        }
    }

    private var failureBody: String {
        switch store.failureReason {
        case .propose: return String(localizable: .migrationPlanProposeFailedBody)
        case .commit, nil: return String(localizable: .migrationNoteSplitFailedBody)
        }
    }
}

// MARK: - Presentation modifier

private extension View {
    /// Only the manual-step variant can be a re-entry root — immediate mode is always reached via
    /// normal push, so a plain pop stands there regardless of `isFlowRoot`.
    @ViewBuilder func applyPresentationModifier(store: StoreOf<MigrationReviewTransfer>) -> some View {
        if store.mode != .immediate && store.isFlowRoot {
            zashiBackV2 {
                store.send(.closeTapped)
            }
        } else {
            zashiBack()
        }
    }
}

// MARK: - Previews

#Preview("Immediate") {
    NavigationView {
        MigrationReviewTransferView(
            store: StoreOf<MigrationReviewTransfer>(
                initialState: MigrationReviewTransfer.State(
                    mode: .immediate,
                    amount: Zatoshi(1_245_800_000),
                    fee: Zatoshi(100_000)
                )
            ) {
                MigrationReviewTransfer()
            }
        )
    }
}

