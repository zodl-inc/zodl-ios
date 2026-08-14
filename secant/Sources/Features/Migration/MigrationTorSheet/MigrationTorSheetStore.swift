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
//    (pre-T3) `gotItTapped` proceeded straight to `.delegate(.gotIt)` regardless of `isTorOn` — see
//    T3 below, which replaces this.
//  - R13 (`broadcastHost`): the formed snapshot's broadcast endpoint host, shown under the toggle
//    (provider) or folded into the unavailable-variant body (custom) — see T3 below, which removes
//    this field from `State` entirely.
//  - R3/R11 (the off-warning `alert`): REMOVED 2026-08-06 — see the Figma-parity note below.
//
//  FIGMA PARITY A1-2.4 — the off-warning alert is DELETED from this sheet (Lukas's decision,
//  2026-08-06). Toggle off + "Got it" now simply resolves the sheet and continues, which is what the
//  designs draw: Figma has no warning anywhere in this flow. The requirement came from MOB-1497's
//  attached "Tor and Broadcast Routing Requirements (R1–R17)" doc, but that same ticket's §J recorded
//  that these dialogs "do not exist in Figma" and flagged them for a product/design pass that never
//  happened — the copy was written to the doc, not by product. Lukas: "all strings there are fully AI
//  artificial, no one from product ever saw it… keep it simple, no alert, no warning."
//
//  The shared `AlertState.migrationTorOffWarning` builder SURVIVES: the R14 broadcast-failure lane
//  (`MigrationSendingStore`, `MigrationStatusStore`) still presents it at a different moment — after
//  a broadcast has already failed over Tor — and that moment was not part of this decision.
//
//  MOB-1497 (T3): redesigns the custom-server ("identity-custom") variant per the refreshed canvas
//  (4207:10692 / dark 4207:10875) — the no-toggle "unavailable" body is joined by a
//  `MigrationRisksCard` ("What are the risks?"), and two new actions replace the shared "Got it"
//  button for that variant: `continueWithoutTorTapped` (destructive1 "Continue without Tor",
//  proceeds exactly like the old custom-server "Got it" did — `.send(.delegate(.gotIt))`) and
//  `switchServerTapped` (primary "Switch Server", a NEW `Delegate.switchServer` case — the
//  coordinator wiring for it lands in T4; this commit only produces the delegate). Both are guarded
//  to `state.isCustomServer`; a stray tap from a provider sheet — unreachable via the real UI, which
//  never renders these buttons there — is a no-op. `gotItTapped` drops its `isCustomServer`
//  early-return: the custom variant no longer renders that button at all, so the case now only ever
//  fires from the provider toggle sheet, falling straight through the existing ON/OFF+alert logic
//  unchanged. `broadcastHost`/`showsBroadcastDisclosure` also leave `State` entirely — the redesigned
//  variant has no disclosure line of its own (nor does the provider toggle card any more; see
//  `MigrationTorSheetView`'s doc), so neither field has a reader left on the sheet itself. R13 still
//  surfaces, exactly as before, via the TransferPlan/ReviewTransfer confirm footers —
//  `MigrationCoordFlowCoordinator.confirmTorSheet` now re-peeks the formed snapshot through the same
//  non-forming `broadcastDisclosureHost` helper the sheet-SKIPPED routes already used, instead of
//  reading it back off this sheet's (now-trimmed) state.
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
        /// MOB-1497 (T2/T3, R2/R12): true when the account's sync server is identity-custom —
        /// threaded in by the coordinator from the formed snapshot's `syncProvider` at presentation
        /// time. The view swaps the toggle card for the redesigned no-toggle "unavailable"
        /// presentation (T3: risks card + "Continue without Tor" / "Switch Server", replacing the old
        /// Got it + inline disclosure).
        var isCustomServer = false

        init(
            isTorOn: Bool = true,
            usesFullBalanceCopy: Bool = false,
            isCustomServer: Bool = false
        ) {
            self.isTorOn = isTorOn
            self.usesFullBalanceCopy = usesFullBalanceCopy
            self.isCustomServer = isCustomServer
        }
    }

    enum Action: BindableAction, Equatable {
        case binding(BindingAction<State>)
        /// MOB-1497 (T3): the custom-server variant's destructive "Continue without Tor" button —
        /// guarded to that variant only (`state.isCustomServer`); a provider tap is a no-op. The
        /// provider variant's own way to proceed without Tor is simply toggling off and tapping
        /// "Got it" — see `gotItTapped`.
        case continueWithoutTorTapped
        case delegate(Delegate)
        case gotItTapped
        /// MOB-1497 (T3): the custom-server variant's primary "Switch Server" button — guarded to
        /// that variant only (`state.isCustomServer`); the coordinator wiring for it lands in T4, so
        /// this commit only ever produces the delegate.
        case switchServerTapped

        enum Delegate: Equatable {
            case gotIt
            /// MOB-1497 (T3): the custom-server variant's "Switch Server" button. Coordinator
            /// handling lands in T4.
            case switchServer
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .continueWithoutTorTapped:
                // MOB-1497 (T3): the custom variant's own CTA — same `.delegate(.gotIt)` contract the
                // removed `gotItTapped` shortcut used to produce for this case. Unreachable from a
                // provider sheet (that variant never renders this button), guarded anyway.
                guard state.isCustomServer else { return .none }
                return .send(.delegate(.gotIt))

            case .delegate:
                return .none

            case .gotItTapped:
                // MOB-1497 (T3): the custom-server shortcut that used to live here is gone — the
                // redesigned unavailable variant no longer renders a "Got it" button at all
                // (`continueWithoutTorTapped`/`switchServerTapped` replace it), so this case now only
                // ever fires from the PROVIDER toggle sheet in practice. Sending it directly against
                // an `isCustomServer == true` state (e.g. from a test) simply falls through the same
                // ON/OFF logic below — there is no dedicated branch left to bypass it with.
                //
                // FIGMA PARITY A1-2.4 (Lukas, 2026-08-06): whatever the toggle shows, "Got it"
                // resolves the sheet. The R3/R11 off-warning alert that used to intercept the OFF
                // case is GONE — see this file's header for why.
                return .send(.delegate(.gotIt))

            case .switchServerTapped:
                // MOB-1497 (T3): guarded the same way as `continueWithoutTorTapped` above.
                guard state.isCustomServer else { return .none }
                return .send(.delegate(.switchServer))
            }
        }
    }
}
