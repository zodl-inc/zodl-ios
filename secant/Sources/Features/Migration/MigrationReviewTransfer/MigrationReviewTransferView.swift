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
    @Perception.Bindable var store: StoreOf<MigrationReviewTransfer>
    @Shared(.inMemory(.exchangeRate)) private var currencyConversion: CurrencyConversion?

    init(store: StoreOf<MigrationReviewTransfer>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if isIconHeaderVisible {
                            MigrationPairedIcons()
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

                        if isThisTransferVisible {
                            thisTransferBlock
                                .padding(.bottom, 16)
                        }

                        detailRows
                    }
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
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                    .disabled(store.isConfirming)
                } else {
                    ZashiButton(String(localizable: .generalConfirm)) {
                        store.send(.confirmTapped)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
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
        case .manualStep(let number, let total):
            return String(localizable: .migrationReviewTitleManual(number, total))
        }
    }

    private var description: String {
        switch store.mode {
        case .immediate:
            return String(localizable: .migrationReviewDescImmediate)
        case .manualStep:
            // MOB-1513 (iteration B, 3491:11612): back to a single sentence — `reviewAndConfirm` and
            // `cannotBeUndone` no longer fold in here (MOB-1497 T7's three-sentence composition is
            // reverted); `cannotBeUndone` now renders as its own caption inside `thisTransferBlock`.
            return String(localizable: .migrationReviewDescManual)
        }
    }

    // MARK: - This Transfer

    /// The "This Transfer" summary block is manual-mode only — immediate mode is untouched.
    private var isThisTransferVisible: Bool {
        store.mode != .immediate
    }

    private var stepNumber: Int {
        guard case .manualStep(let number, _) = store.mode else { return 0 }
        return number
    }

    private var stepTotal: Int {
        guard case .manualStep(_, let total) = store.mode else { return 0 }
        return total
    }

    @ViewBuilder private var thisTransferBlock: some View {
        // MOB-1513 (iteration B, 3491:11612): `migrationReviewCannotBeUndone` moves back to its own
        // caption line here, directly under the heading — reverting MOB-1497 (T7)'s fold into the
        // top `description` paragraph (see that property's comment). Spacing/typography mirror
        // `thisTransferRow`'s own heading+caption pair below.
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .migrationReviewThisTransferTitle)
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text(localizable: .migrationReviewCannotBeUndone)
                    .zFont(size: 14, style: Design.Text.tertiary)
            }

            thisTransferRow
        }
    }

    @ViewBuilder private var thisTransferRow: some View {
        HStack(alignment: .top, spacing: 12) {
            MigrationStepBadge(number: stepNumber, style: .active, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .migrationReviewTransferOfTotal(stepNumber, stepTotal))
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                Text(localizable: .migrationReviewSendsNow)
                    .zFont(size: 14, style: Design.Text.tertiary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(store.amount.decimalString()) ZEC")
                    .zFont(.semiBold, size: 16, style: Design.Text.primary)

                if let currencyConversion {
                    Text(currencyConversion.convert(store.amount))
                        .zFont(size: 13, style: Design.Text.tertiary)
                }
            }
        }
    }

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

#Preview("Manual step 3 of 5") {
    NavigationView {
        MigrationReviewTransferView(
            store: StoreOf<MigrationReviewTransfer>(
                initialState: MigrationReviewTransfer.State(
                    mode: .manualStep(number: 3, total: 5),
                    amount: Zatoshi(243_100_000),
                    fee: Zatoshi(100_000)
                )
            ) {
                MigrationReviewTransfer()
            }
        )
    }
}
