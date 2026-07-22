//
//  MigrationTorSheetTests.swift
//  zodlTests
//
//  Covers the MigrationTorSheet reducer
//  (Features/Migration/MigrationTorSheet/MigrationTorSheetStore.swift) for MOB-1478 (W2) +
//  MOB-1494 (round 4): the `isTorOn` binding (defaults ON per the round-4 canvas), the per-path
//  body-copy flag (`usesFullBalanceCopy`), and the `gotItTapped` delegate contract. Persisting the
//  choice via `migrationManager.setNetworkPrivacyOptions(useTor:)` and resuming the stashed
//  destination is `MigrationCoordFlowCoordinator`'s job — covered in `MigrationCoordFlowTests`. No
//  shared/global state -> no `.serialized`.
//
//  MOB-1497 (T2 of the Tor & broadcast-routing requirements round) adds two more axes this file
//  covers:
//  - R2/R12 (`isCustomServer`): the identity-custom no-toggle variant.
//  - R3/R11 (the off-warning alert): a PROVIDER user's `gotItTapped` with the toggle OFF presents a
//    confirmation `AlertState` (house idiom — `@Presents var alert`) instead of proceeding directly;
//    ON proceeds directly, unchanged. "Proceed without Tor" clears the alert and emits
//    `.delegate(.gotIt)` (`isTorOn` stays false — the coordinator reads it from there to persist +
//    call `confirmProvisionalTorChoice`); "Keep Tor on" (`.alert(.dismiss)`) clears the alert AND
//    resets `isTorOn` back to `true`, emitting no delegate — the sheet stays up showing ON. Persisting
//    the choice itself is the coordinator's job (`MigrationCoordFlowTests`).
//
//  MOB-1497 (T3) redesigns the custom-server variant and adds this file's third axis:
//  `continueWithoutTorTapped`/`switchServerTapped`, the two buttons that replace "Got it" for that
//  variant — both guarded to `state.isCustomServer`, a no-op otherwise. `gotItTapped` itself drops
//  its `isCustomServer` early-return (the redesigned variant no longer renders that button), so it
//  now always falls through the provider ON/OFF+alert logic — see the tests right after the R3/R11
//  cluster below for what that means when sent against an (unreachable-from-the-real-UI)
//  `isCustomServer == true` state. `broadcastHost`/`showsBroadcastDisclosure` leave `State` in the
//  same commit — see `MigrationTorSheetStore`'s header doc.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct MigrationTorSheetTests {
    @MainActor @Test func defaultStateHasTorOnAndScheduledBodyCopy() async {
        // MOB-1494 (round 4): the canvas draws the toggle ON in every frame — default-on
        // supersedes the earlier no-pre-selection rule. The body copy defaults to the scheduled
        // ("your balance") variant.
        let state = MigrationTorSheet.State()

        #expect(state.isTorOn == true)
        #expect(state.usesFullBalanceCopy == false)
        // MOB-1497 (T2): provider is the default variant — no sheet presentation ever leaves this at
        // its bare-init default (the coordinator always threads a real value), but the default itself
        // must read as "provider" rather than accidentally "custom".
        #expect(state.isCustomServer == false)
    }

    @MainActor @Test func initCanOverrideToggleAndBodyCopyVariant() async {
        let state = MigrationTorSheet.State(isTorOn: false, usesFullBalanceCopy: true)

        #expect(state.isTorOn == false)
        #expect(state.usesFullBalanceCopy == true)
    }

    @MainActor @Test func initCanSetCustomServer() async {
        let state = MigrationTorSheet.State(isTorOn: false, isCustomServer: true)

        #expect(state.isCustomServer == true)
    }

    @MainActor @Test func isTorOnBindingTogglesOff() async {
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.binding(.set(\.isTorOn, false))) {
            $0.isTorOn = false
        }
    }

    @MainActor @Test func isTorOnBindingTogglesOn() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isTorOn: false)) {
            MigrationTorSheet()
        }

        await store.send(.binding(.set(\.isTorOn, true))) {
            $0.isTorOn = true
        }
    }

    @MainActor @Test func gotItTappedEmitsDelegateGotIt() async {
        // Provider, toggle ON (the default) — proceeds directly, no alert.
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.gotIt))
    }

    @MainActor @Test func delegateActionProducesNoStateChangeOrEffects() async {
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.delegate(.gotIt))
    }

    // MARK: - MOB-1497 (T3): continueWithoutTorTapped / switchServerTapped (custom-server variant only)

    @MainActor @Test func continueWithoutTorTappedOnCustomServerEmitsGotIt() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isCustomServer: true)) {
            MigrationTorSheet()
        }

        await store.send(.continueWithoutTorTapped)
        await store.receive(.delegate(.gotIt))
    }

    @MainActor @Test func continueWithoutTorTappedOnProviderIsIgnored() async {
        // Unreachable via the real UI (the provider sheet never renders this button) — guarded
        // anyway, so a stray send is a documented no-op rather than an unchecked assumption.
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.continueWithoutTorTapped)
    }

    @MainActor @Test func switchServerTappedOnCustomServerEmitsSwitchServerDelegate() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isCustomServer: true)) {
            MigrationTorSheet()
        }

        await store.send(.switchServerTapped)
        await store.receive(.delegate(.switchServer))
    }

    @MainActor @Test func switchServerTappedOnProviderIsIgnored() async {
        let store = TestStore(initialState: MigrationTorSheet.State()) {
            MigrationTorSheet()
        }

        await store.send(.switchServerTapped)
    }

    // MARK: - MOB-1497 (T3): gotItTapped no longer short-circuits for identity-custom

    /// The old `isCustomServer` early-return is gone — the redesigned variant doesn't render "Got
    /// it" any more (`continueWithoutTorTapped`/`switchServerTapped` replace it), so a direct
    /// `gotItTapped` now just falls through the SAME ON/OFF+alert logic every provider tap already
    /// used. With the default toggle (ON), that means proceeding straight through — the same
    /// observable outcome the old shortcut produced for this one combination; the divergence only
    /// shows up with the toggle OFF (see the alert test right below).
    @MainActor @Test func gotItTappedOnCustomServerStateNoLongerShortCircuits() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isCustomServer: true)) {
            MigrationTorSheet()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.gotIt))
    }

    /// The actual proof the shortcut is gone: before this change, an identity-custom `gotItTapped`
    /// emitted `.delegate(.gotIt)` unconditionally, the toggle value never even inspected. Now, with
    /// the toggle showing OFF, it falls into the exact same off-warning alert a provider tap would
    /// show — dead code from the real UI (the custom variant never renders a toggle to turn OFF in
    /// the first place), but the reducer no longer has a dedicated branch to special-case it away.
    @MainActor @Test func gotItTappedOnCustomServerWithToggleOffFallsThroughToOffWarningAlert() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isTorOn: false, isCustomServer: true)) {
            MigrationTorSheet()
        }

        await store.send(.gotItTapped) {
            $0.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        }
    }

    // MARK: - MOB-1497 (T2, R3/R11): provider off-warning

    @MainActor @Test func gotItTappedWithToggleOffPresentsOffWarningAlertWithGradualMessage() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isTorOn: false, usesFullBalanceCopy: false)) {
            MigrationTorSheet()
        }

        await store.send(.gotItTapped) {
            $0.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        }
    }

    @MainActor @Test func gotItTappedWithToggleOffPresentsOffWarningAlertWithFullMessage() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isTorOn: false, usesFullBalanceCopy: true)) {
            MigrationTorSheet()
        }

        await store.send(.gotItTapped) {
            $0.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: true, proceedAction: .offWarningProceedTapped)
        }
    }

    @MainActor @Test func gotItTappedWithToggleOffDoesNotEmitDelegateUntilTheAlertResolves() async {
        let store = TestStore(initialState: MigrationTorSheet.State(isTorOn: false)) {
            MigrationTorSheet()
        }
        store.exhaustivity = .off

        await store.send(.gotItTapped)

        // No `.delegate(.gotIt)` yet — the coordinator must never see the sheet "confirmed" for an
        // OFF choice before the user has actually resolved the warning.
        #expect(store.state.alert != nil)
    }

    @MainActor @Test func offWarningProceedTappedClearsAlertAndEmitsDelegateGotItLeavingToggleOff() async {
        var state = MigrationTorSheet.State(isTorOn: false, usesFullBalanceCopy: false)
        state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        let store = TestStore(initialState: state) {
            MigrationTorSheet()
        }

        // Mirrors the real dispatch shape a tap on the "Proceed without Tor" `ButtonState` produces
        // (`AlertState`'s SwiftUI wiring wraps the button's own action in `.alert(.presented(...))`
        // before sending it) — see `AlertState.migrationTorOffWarning`'s destructive
        // `ButtonState(action: proceedAction)`.
        await store.send(.alert(.presented(.offWarningProceedTapped)))
        await store.receive(.offWarningProceedTapped) {
            $0.alert = nil
        }
        await store.receive(.delegate(.gotIt))

        #expect(store.state.isTorOn == false)
    }

    @MainActor @Test func alertDismissKeepsTorOnResetsToggleBackToOnAndEmitsNoDelegate() async {
        var state = MigrationTorSheet.State(isTorOn: false, usesFullBalanceCopy: false)
        state.alert = AlertState.migrationTorOffWarning(usesFullBalanceCopy: false, proceedAction: .offWarningProceedTapped)
        let store = TestStore(initialState: state) {
            MigrationTorSheet()
        }

        // "Keep Tor on" is `ButtonState(role: .cancel, action: .alert(.dismiss))` — the real dispatch
        // is the bare `.alert(.dismiss)` PresentationAction, not a further-wrapped custom action.
        await store.send(.alert(.dismiss)) {
            $0.alert = nil
            $0.isTorOn = true
        }
    }

    @MainActor @Test func gotItTappedWithToggleOnEmitsDelegateDirectlyEvenAfterAPriorOffWarningWasDismissed() async {
        // Sanity: once back at ON (either the user re-toggled it, or "Keep Tor on" reset it), a
        // fresh `gotItTapped` proceeds directly again — the alert-gating is keyed off the CURRENT
        // toggle value each time, not some sticky "has warned once" flag.
        let store = TestStore(initialState: MigrationTorSheet.State(isTorOn: true)) {
            MigrationTorSheet()
        }

        await store.send(.gotItTapped)
        await store.receive(.delegate(.gotIt))

        #expect(store.state.alert == nil)
    }
}
