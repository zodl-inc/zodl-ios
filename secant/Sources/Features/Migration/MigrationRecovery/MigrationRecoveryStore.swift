//
//  MigrationRecoveryStore.swift
//  zodl
//
//  "Reschedule Transfers" / "Transfers No Longer Valid" screen (MOB-1464, Figma S11 · spent
//  2696:5626 / expired 2973:5698). When this screen is the coordinator's re-entry root
//  (`isFlowRoot`), its back control closes the flow (`closeTapped` -> `.delegate(.close)`) instead
//  of popping (MOB-1466). The `continueTapped` delegate (plan-recreation) is consumed by
//  `MigrationCoordFlowCoordinator` (MOB-1466).
//

import ComposableArchitecture

@Reducer
struct MigrationRecovery {
    @ObservableState
    struct State: Equatable {
        enum Reason: Equatable {
            case notesSpent
            case expired
        }

        var reason = Reason.notesSpent
        /// "Transfers {a}–{b}" range in copy.
        var firstTransfer = 3
        var lastTransfer = 5
        /// True when this screen is the coordinator's re-entry root — its back control then closes
        /// the flow instead of popping.
        var isFlowRoot = false
        /// MOB-1458 (final review I3): a recovery (refresh/restart) is in flight — the Continue button
        /// shows a spinner and is disabled, so a double-tap can't start a second multi-second
        /// operation. SET by the coordinator's `.recovery(.delegate(.recreate))` handler (which owns
        /// the async work), mirroring how `.status(.delegate(.reschedule))` sets `isRescheduling` on
        /// its child element. CLEARED by the coordinator on the failure alert (so Cancel/Restart leave
        /// a usable button) and reset here on `.onAppear` when the screen re-appears after navigating
        /// away.
        var isRecovering = false

        init(
            reason: Reason = .notesSpent,
            firstTransfer: Int = 3,
            lastTransfer: Int = 5,
            isFlowRoot: Bool = false,
            isRecovering: Bool = false
        ) {
            self.reason = reason
            self.firstTransfer = firstTransfer
            self.lastTransfer = lastTransfer
            self.isFlowRoot = isFlowRoot
            self.isRecovering = isRecovering
        }
    }

    enum Action: Equatable {
        /// Flow-root back control: closes the flow instead of popping.
        case closeTapped
        case continueTapped
        /// MOB-1458 (final review I3): resets `isRecovering` when the screen re-appears (a pop-back
        /// after the ceremony navigated away, or a Keystone abandon that popped back here) so its
        /// Continue button is usable again. A first appearance is a harmless no-op (already false).
        case onAppear
        case delegate(Delegate)

        enum Delegate: Equatable {
            case close
            case recreate
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .closeTapped:
                return .send(.delegate(.close))

            case .continueTapped:
                // Single-flight lives coordinator-side (it owns the async work and the `isRecovering`
                // set); this just forwards. The disabled button already blocks the common double-tap.
                return .send(.delegate(.recreate))

            case .onAppear:
                state.isRecovering = false
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
