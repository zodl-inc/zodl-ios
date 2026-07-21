//
//  MigrationOffWarningAlertTests.swift
//  zodlTests
//
//  Covers the R9-T2 (finding 14) shared off-warning `AlertState` builder
//  (Features/Migration/MigrationOffWarningAlert.swift) — `MigrationTorSheetStore`,
//  `MigrationSendingStore`, `MigrationNoteSplitStore` (and, from R9-T2 commit 3,
//  `MigrationTransferPlanStore`) each carried a byte-identical (modulo the enclosing `Action` generic)
//  copy of this alert. These tests pin the builder's OUTPUT against a hand-built `AlertState` using
//  full `Equatable` comparison — a stronger guarantee than inspecting individual fields that the
//  produced value is byte-identical to what the three pre-fix per-store copies built (title, message
//  per `usesFullBalanceCopy`, button roles/labels/actions).
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

struct MigrationOffWarningAlertTests {
    private enum DummyAction: Equatable {
        case proceed
        case otherProceed
    }

    @Test func matchesTheHandBuiltAlertStateForGradualCopy() {
        let expected = AlertState<DummyAction> {
            TextState(String(localizable: .migrationTorSheetOffWarningTitle))
        } actions: {
            ButtonState(role: .destructive, action: DummyAction.proceed) {
                TextState(String(localizable: .migrationTorSheetOffWarningProceed))
            }
            ButtonState(role: .cancel) {
                TextState(String(localizable: .migrationTorSheetOffWarningKeepOn))
            }
        } message: {
            TextState(String(localizable: .migrationTorSheetOffWarningMessageGradual))
        }

        let actual = AlertState<DummyAction>.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: DummyAction.proceed)

        #expect(actual == expected)
    }

    @Test func matchesTheHandBuiltAlertStateForFullBalanceCopy() {
        let expected = AlertState<DummyAction> {
            TextState(String(localizable: .migrationTorSheetOffWarningTitle))
        } actions: {
            ButtonState(role: .destructive, action: DummyAction.proceed) {
                TextState(String(localizable: .migrationTorSheetOffWarningProceed))
            }
            ButtonState(role: .cancel) {
                TextState(String(localizable: .migrationTorSheetOffWarningKeepOn))
            }
        } message: {
            TextState(String(localizable: .migrationTorSheetOffWarningMessageFull))
        }

        let actual = AlertState<DummyAction>.migrationTorOffWarning(usesFullBalanceCopy: true, proceedAction: DummyAction.proceed)

        #expect(actual == expected)
    }

    /// Proves `proceedAction` is actually threaded through (not hardcoded) — two calls differing only
    /// in `proceedAction` must produce unequal alerts.
    @Test func differingProceedActionsProduceUnequalAlerts() {
        let first = AlertState<DummyAction>.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: DummyAction.proceed)
        let second = AlertState<DummyAction>.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: DummyAction.otherProceed)

        #expect(first != second)
    }
}
