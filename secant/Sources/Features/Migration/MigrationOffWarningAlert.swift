//
//  MigrationOffWarningAlert.swift
//  Zashi
//
//  R9-T2 (MOB-1497 review remediation, finding 14): the single shared off-warning `AlertState`
//  builder. `static func offWarning(usesFullBalanceCopy:)` was byte-identical (modulo the enclosing
//  `Action` generic) in `MigrationTorSheetStore`, `MigrationSendingStore`, and
//  `MigrationNoteSplitStore` — three copies of the same R3/R11 compliance copy that could silently
//  drift apart. `AlertState` is itself generic over its action, so ONE generic builder covers every
//  adopter (a fourth, `MigrationTransferPlanStore`, adopts it in R9-T2 commit 3) — the destructive
//  "Proceed without Tor" button's action is the one thing that varies per adopter (each has its own
//  `Action` type with no shared protocol), so it's threaded in as a parameter. The cancel "Keep Tor
//  on" button carries no explicit action: tapping it relies on the alert's own native dismissal (the
//  SAME `.alert(.dismiss)` a swipe-dismiss already produces), which every adopter already handles in
//  its own `case .alert(.dismiss):` reducer clause — see `swift-navigation`'s `Alert+Observation.swift`
//  (`if let action { store?.send(action) }` — a `nil` action tap sends nothing explicitly, letting
//  SwiftUI's own `isPresented` binding drive the dismiss).
//
//  Copy source: the normative doc's R11 and `Localizable.xcstrings`'s `migrationTorSheet.offWarning.*`
//  entries — gradual (scheduled/note-split lanes) vs. full-balance (immediate lane) message variants.
//

import ComposableArchitecture

extension AlertState {
    static func migrationTorOffWarning(usesFullBalanceCopy: Bool, proceedAction: Action) -> AlertState<Action> {
        AlertState<Action> {
            TextState(String(localizable: .migrationTorSheetOffWarningTitle))
        } actions: {
            ButtonState(role: .destructive, action: proceedAction) {
                TextState(String(localizable: .migrationTorSheetOffWarningProceed))
            }
            ButtonState(role: .cancel) {
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
