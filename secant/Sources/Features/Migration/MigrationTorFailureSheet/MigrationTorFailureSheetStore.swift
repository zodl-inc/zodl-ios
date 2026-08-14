//
//  MigrationTorFailureSheetStore.swift
//  zodl
//
//  "Couldn't Connect to Tor" bottom sheet (MOB-1497 T6, Figma 4207:9064 light / 4207:9324 dark).
//  DESIGNED to be presented over Home after a BACKGROUND migration broadcast fails on a Tor-class
//  route — currently unwired: the T5 latch that was to arm it was deleted (audit 2026-08-03, #16;
//  nothing could set it), so no presenter exists yet. It offers the user two ways forward:
//  "Continue without Tor" (destructive — turns Tor off for the rest of the run, then retries over
//  clearnet) and "Try again" (retries keeping Tor). This is the deliberate, explicit-consent escape
//  hatch to the otherwise-strict "never offer clearnet" stance (R15): the sheet's `MigrationRisksCard`
//  IS the consent surface, so there is no second confirmation alert.
//
//  The store itself is intentionally minimal: it only translates each button tap into its `.delegate`
//  case. `Root` owns every side effect (dismiss, clear the latch, `overrideTorForRun`, the single
//  foreground broadcast attempt, and — on a Tor-class retry failure — re-arming the latch and
//  re-presenting) — see `Root.torFailurePrompt(.delegate)` handling in `RootCoordinator`.
//

import ComposableArchitecture

@Reducer
struct MigrationTorFailureSheet {
    @ObservableState
    struct State: Equatable { }

    enum Action: Equatable {
        case continueWithoutTorTapped
        case delegate(Delegate)
        case tryAgainTapped

        enum Delegate: Equatable {
            case continueWithoutTor
            case tryAgain
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            switch action {
            case .continueWithoutTorTapped:
                return .send(.delegate(.continueWithoutTor))

            case .delegate:
                return .none

            case .tryAgainTapped:
                return .send(.delegate(.tryAgain))
            }
        }
    }
}
