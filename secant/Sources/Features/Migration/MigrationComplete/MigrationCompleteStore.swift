//
//  MigrationCompleteStore.swift
//  zodl
//
//  "Migration Complete" screen (MOB-1464, Figma S12 · 2696:7267). Display-only summary fields are
//  injected by the coordinator (MOB-1466). This screen has no back control at all
//  (`.navigationBarBackButtonHidden()`); `isFlowRoot` is carried in State for coordinator-injection
//  consistency with the other re-entry roots even though there's no back-control behavior to gate
//  here. The `gotItTapped` delegate is consumed by `MigrationCoordFlowCoordinator` (MOB-1466).
//
//  MOB-1487 (round 2, Figma offered 3836:8394 / locking 3836:8488 / locked 3836:8643): a leftover
//  Orchard balance is a DECISION, not a take-it-or-leave-it callout — lock it, or migrate it anyway.
//  MOB-1487 (round 3, Figma 3925:24209) added the "What does locking do?" explainer sheet, and
//  MOB-1458 (F4) the single-flight guard on "Migrate anyway"; audit 2026-08-03 (#11) then made that
//  guard re-arm on every arrival, after a successful hand-over followed by a back-swipe landed here
//  with the button permanently disabled.
//
//  MOB-1749 review fix: all of that machinery is now `MigrationLockDecision`, scoped in as `lock`
//  and shared verbatim with the Remaining Orchard Funds screen — the two used to carry
//  byte-identical rename-copies of it, so the #11 fix above had to be made twice, which is exactly
//  the drift that gets missed the third time. What is left here is this screen's own glue: the run
//  summary, the failure ALERT the child's `.lockFailed` delegate asks for, the `.migrateAnyway`
//  delegate re-surfaced at screen level so the coordinator keeps listening to the SCREEN, and
//  `gotItTapped` — unchanged, and reachable both with no dust at all and from `.locked`.
//
//  Whether there is anything to decide is `hasDust` (`dust > 0`), never a state of the lock machine:
//  the old `DustResolution` carried a fourth `.none` case that the view had to map away at its own
//  boundary, and a vocabulary that can say "no dust" to a machine that only ever runs when there IS
//  dust is a vocabulary that can lie. The coordinator hydrates `dust` from the run's own summary
//  first; the account-wide locked figure speaks — and pins `resolution` to `.locked` — only when
//  the run left nothing unlocked.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationComplete {
    @ObservableState
    struct State: Equatable {
        @Presents var alert: AlertState<Action>?
        /// The total value transferred across the whole run. `nil` when not derivable — a W1
        /// fallback re-entry with no persisted schedule (MOB-1513) — never a placeholder
        /// `Zatoshi.zero`; the view renders an em-dash in its place (see `MigrationCompleteView
        /// .summaryCard`).
        var totalTransferred: Zatoshi?
        var dust = Zatoshi.zero
        /// The shared lock machine — resolution, explainer sheet, "Migrate anyway" single-flight.
        /// Meaningful only while `hasDust`; the view renders none of its pieces otherwise.
        var lock: MigrationLockDecision.State
        var transfersSent = 0
        var transfersTotal = 0
        /// Same "nil, never a placeholder `0`" W1-fallback convention as `totalTransferred` above.
        var durationHours: Int?
        /// Carried for consistency with the other re-entry-root screens; this screen has no back
        /// control to gate (`.navigationBarBackButtonHidden()`, no custom leading toolbar item).
        var isFlowRoot = false

        var hasDust: Bool {
            dust.amount > 0
        }

        init(
            totalTransferred: Zatoshi? = nil,
            dust: Zatoshi = .zero,
            transfersSent: Int = 0,
            transfersTotal: Int = 0,
            durationHours: Int? = nil,
            isFlowRoot: Bool = false,
            resolution: MigrationLockResolution? = nil
        ) {
            self.totalTransferred = totalTransferred
            self.dust = dust
            // `.offered` is the resting state of a decision nobody has taken yet; a caller that
            // knows better (the coordinator, when only a locked balance remains) says so explicitly.
            // With no dust the machine is simply never rendered, so its value is moot.
            self.lock = MigrationLockDecision.State(resolution: resolution ?? .offered)
            self.transfersSent = transfersSent
            self.transfersTotal = transfersTotal
            self.durationHours = durationHours
            self.isFlowRoot = isFlowRoot
        }
    }

    enum Action: Equatable {
        case alert(PresentationAction<Action>)
        case delegate(Delegate)
        case gotItTapped
        case lock(MigrationLockDecision.Action)

        enum Delegate: Equatable {
            case done
            case migrateAnyway
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Scope(state: \.lock, action: \.lock) {
            MigrationLockDecision()
        }

        Reduce { state, action in
            switch action {
            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .delegate:
                return .none

            case .gotItTapped:
                return .send(.delegate(.done))

            case .lock(.delegate(.lockFailed)):
                state.alert = AlertState.migrationLockFailed()
                return .none

            case .lock(.delegate(.migrateAnyway)):
                // Re-surfaced at screen level: the coordinator listens for the SCREEN's delegate,
                // so both adopters keep their own coordinator wiring unchanged.
                return .send(.delegate(.migrateAnyway))

            case .lock:
                return .none
            }
        }
    }
}
