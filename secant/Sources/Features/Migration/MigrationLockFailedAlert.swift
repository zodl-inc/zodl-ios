//
//  MigrationLockFailedAlert.swift
//  zodl
//
//  MOB-1749 review fix: the single shared lock-failure AlertState builder. The same alert was
//  declared byte-identically in MigrationCompleteStore and MigrationResidualStore (modulo the
//  enclosing `Action` generic) — the exact drift `MigrationOffWarningAlert` was created to end.
//  `AlertState` is itself generic over its action and this alert declares no buttons, so one
//  unconstrained builder covers every adopter.
//

import ComposableArchitecture

extension AlertState {
    /// Generic failure copy — `lockMigrationDust` throws a bare error with no user-facing detail
    /// to surface. Reuses `MigrationNoteSplit`'s failure copy (same Migration domain, no
    /// interpolated argument); "tap below to try again" matches both adopters' shape exactly:
    /// dismissing lands back on `.offered` with "Lock balance" visible again.
    static func migrationLockFailed() -> AlertState<Action> {
        AlertState {
            TextState(String(localizable: .migrationNoteSplitFailedTitle))
        } message: {
            TextState(String(localizable: .migrationNoteSplitFailedBody))
        }
    }
}
