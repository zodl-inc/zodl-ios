//
//  MigrationTorSheetStore.swift
//  zodl
//
//  "Enable Tor Protection" bottom sheet (MOB-1478 W2), replacing the full-screen Network Privacy
//  screen (S5, deleted). Hosted by `MigrationCoordFlowCoordinator` as a single coordinator-owned
//  sheet, presented from both Entry (immediate path) and How This Works (scheduled path) right before
//  the coordinator would otherwise route past the Tor step. `gotItTapped`'s `.delegate(.gotIt)` (and
//  sheet swipe-dismissal, treated identically by the coordinator) is consumed by the coordinator,
//  which persists `isTorOn` into a `MigrationNetworkPrivacyOptions` exactly as
//  `MigrationNetworkPrivacyStore` did, then resumes whichever destination it stashed before presenting.
//
//  MOB-1487 (round 3) briefly made the sheet Entry-immediate-only (scheduled path forced Tor on);
//  MOB-1494 (round 4) restores the scheduled host per the revised canvas — the toggle now defaults
//  ON (drawn ON in every frame, "strongly recommend" copy), and the body copy splits by path:
//  the immediate sheet says "your full balance", the scheduled sheet "your balance"
//  (`usesFullBalanceCopy`).
//
//  MOB-1497 (T2 of the Tor & broadcast-routing requirements round) adds the sheet's user-facing
//  compliance for R2/R3/R11/R12/R13, threaded in by the coordinator at PRESENTATION time (forming
//  moves there — see `MigrationCoordFlowCoordinator`'s header doc):
//  - R2/R12 (`isCustomServer`): identity-custom users get the no-toggle "unavailable" variant instead
//    of the toggle card — the view swaps in different body copy (`MigrationTorSheetView`), and
//    `gotItTapped` proceeds straight to `.delegate(.gotIt)` regardless of `isTorOn` (there is no
//    toggle to warn about; R12's disclosure IS the warning).
//  - R13 (`broadcastHost`): the formed snapshot's broadcast endpoint host, shown under the toggle
//    (provider) or folded into the unavailable-variant body (custom).
//  - R3/R11 (the off-warning `alert`): a PROVIDER user's `gotItTapped` with the toggle OFF presents a
//    confirmation alert (house `AlertState` idiom, mirroring `ServerSetup`'s migration-privacy
//    warning / `MigrationComplete`'s failure alert) instead of proceeding directly. "Proceed without
//    Tor" clears the alert and emits `.delegate(.gotIt)` with `isTorOn` still `false` — the
//    coordinator reads it from there to persist the choice and call `confirmProvisionalTorChoice`.
//    "Keep Tor on" (the alert's `.cancel`-role button, dispatched as the bare `.alert(.dismiss)`)
//    clears the alert AND resets `isTorOn` back to `true` — the sheet stays up showing ON, and no
//    delegate is emitted (nothing to resume). ON confirms proceed directly, unchanged, exactly like
//    the custom variant.
//

import ComposableArchitecture

@Reducer
struct MigrationTorSheet {
    @ObservableState
    struct State: Equatable {
        /// MOB-1494 (round 4): defaults ON — the canvas draws the toggle ON in every frame and the
        /// copy "strongly recommend"s it, superseding the earlier no-pre-selection rule.
        var isTorOn = true
        /// MOB-1494 (round 4): the immediate path's body reads "your full balance", the scheduled
        /// path's "your balance" — the view picks the string off this flag. MOB-1497 (T2): also
        /// selects the gradual/full R11 exposure text (unavailable-variant body / off-warning
        /// message) — "full" == immediate (this flag `true`), "gradual" == scheduled (`false`).
        var usesFullBalanceCopy = false
        /// MOB-1497 (T2, R2/R12): true when the account's sync server is identity-custom — threaded
        /// in by the coordinator from the formed snapshot's `syncProvider` at presentation time. The
        /// view swaps the toggle card for the no-toggle unavailable presentation, and `gotItTapped`
        /// proceeds unconditionally (no alert — there is no toggle to warn about).
        var isCustomServer = false
        /// MOB-1497 (T2, R13): the formed snapshot's broadcast endpoint host, threaded in by the
        /// coordinator at presentation time. Empty until a snapshot has been formed — the coordinator
        /// always forms one before presenting, so a live sheet never actually shows it empty.
        var broadcastHost = ""
        /// R7-T2 fix-wave 1 (Important-1): true iff the formed snapshot's broadcast server differs
        /// from its sync server (`broadcastProvider != syncProvider`), threaded in by the coordinator
        /// alongside `broadcastHost`. Gates the R13 disclosure line INDEPENDENTLY of `isCustomServer`
        /// — that flag only decides the R2/R12 no-toggle unavailable variant. Testnet and the
        /// defensive same-server fallback (`MigrationManagerLiveKey.createNetworkSnapshot`'s
        /// empty-candidates branch) both set `broadcastProvider == syncProvider` while still
        /// classifying as a normal provider (`isCustomServer == false`) — those users keep the toggle
        /// sheet but must not see a disclosure line claiming a "different server" that isn't true.
        var showsBroadcastDisclosure = true
        @Presents var alert: AlertState<Action>?

        init(
            isTorOn: Bool = true,
            usesFullBalanceCopy: Bool = false,
            isCustomServer: Bool = false,
            broadcastHost: String = "",
            showsBroadcastDisclosure: Bool? = nil
        ) {
            self.isTorOn = isTorOn
            self.usesFullBalanceCopy = usesFullBalanceCopy
            self.isCustomServer = isCustomServer
            self.broadcastHost = broadcastHost
            // Undeclared callers infer `!isCustomServer` — the pre-fix gate's exact rule — so any
            // caller that only ever set `isCustomServer` (every call site before this fix-wave) keeps
            // its original disclosure behavior without needing to learn about this new axis.
            self.showsBroadcastDisclosure = showsBroadcastDisclosure ?? !isCustomServer
        }
    }

    enum Action: BindableAction, Equatable {
        case alert(PresentationAction<Action>)
        case binding(BindingAction<State>)
        case delegate(Delegate)
        case gotItTapped
        /// MOB-1497 (T2, R3/R11): the off-warning alert's "Proceed without Tor" button.
        case offWarningProceedTapped

        enum Delegate: Equatable {
            case gotIt
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                // MOB-1497 (T2): "Keep Tor on" reaches here (the alert's cancel-role button dispatches
                // the bare `.alert(.dismiss)`, not a further-wrapped action — see `AlertState
                // .offWarning`) — force the toggle back ON so the sheet, which stays presented,
                // reflects the choice the user just reaffirmed rather than the OFF position that
                // triggered the warning. No delegate: the sheet isn't resolved, it's still showing.
                state.alert = nil
                state.isTorOn = true
                return .none

            case .binding:
                return .none

            case .delegate:
                return .none

            case .gotItTapped:
                // R12's disclosure IS the warning for a custom server — there's no toggle, so no
                // alert gate either; proceed unconditionally.
                guard !state.isCustomServer else {
                    return .send(.delegate(.gotIt))
                }
                // Provider + ON: proceeds directly, same as always.
                guard !state.isTorOn else {
                    return .send(.delegate(.gotIt))
                }
                // Provider + OFF: R3/R11 requires the explicit warning before this can take effect.
                state.alert = AlertState.offWarning(usesFullBalanceCopy: state.usesFullBalanceCopy)
                return .none

            case .offWarningProceedTapped:
                state.alert = nil
                return .send(.delegate(.gotIt))
            }
        }
    }
}

// MARK: - Alerts

extension AlertState where Action == MigrationTorSheet.Action {
    /// MOB-1497 (T2, R3/R11): presented by `gotItTapped` when a provider user confirms with the
    /// toggle OFF. Message text is the brief's adaptation of R11's exact per-path content (gradual/
    /// full — see the normative doc's R11 and `Localizable.xcstrings`'s `migrationTorSheet.offWarning.*`
    /// entries for the literal copy).
    static func offWarning(usesFullBalanceCopy: Bool) -> AlertState {
        AlertState {
            TextState(String(localizable: .migrationTorSheetOffWarningTitle))
        } actions: {
            ButtonState(role: .destructive, action: .offWarningProceedTapped) {
                TextState(String(localizable: .migrationTorSheetOffWarningProceed))
            }
            ButtonState(role: .cancel, action: .alert(.dismiss)) {
                TextState(String(localizable: .migrationTorSheetOffWarningKeepOn))
            }
        } message: {
            TextState(
                usesFullBalanceCopy
                    ? String(localizable: .migrationTorSheetOffWarningMessageFull)
                    : String(localizable: .migrationTorSheetOffWarningMessageGradual)
            )
        }
    }
}
