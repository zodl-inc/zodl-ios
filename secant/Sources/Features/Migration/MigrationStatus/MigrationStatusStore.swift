//
//  MigrationStatusStore.swift
//  zodl
//
//  "Migration Progress" / "Resume Migration" / "Re-scheduling…" screen (MOB-1464, Figma S10 ·
//  progress 2709:3350 / resume 2696:7133 / re-scheduling 2840:3656). Visually complete per Figma;
//  `rows` is a placeholder and every delegate is emitted but consumed by nobody yet — wiring the
//  real reschedule/send-now behavior and chaining into the rest of the migration flow lands in
//  MOB-1466.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationStatus {
    @ObservableState
    struct State: Equatable {
        enum Presentation: Equatable {
            case progress
            case resume
        }

        var presentation = Presentation.progress
        /// Placeholder; real proposal data lands in MOB-1466.
        var rows: IdentifiedArrayOf<MigrationTransferRow> = []
        var totalDurationHours = 0
        /// Resume header: "Transfer {n} of {m} …".
        var stalledNumber = 0
        var stalledHoursAgo = 0
        /// Visual-only: skeleton captions + disabled spinner button on the resume presentation.
        var isRescheduling = false

        var remainingCount: Int {
            rows.filter { $0.status != .sent }.count
        }

        init(
            presentation: Presentation = .progress,
            rows: IdentifiedArrayOf<MigrationTransferRow> = [],
            totalDurationHours: Int = 0,
            stalledNumber: Int = 0,
            stalledHoursAgo: Int = 0,
            isRescheduling: Bool = false
        ) {
            self.presentation = presentation
            self.rows = rows
            self.totalDurationHours = totalDurationHours
            self.stalledNumber = stalledNumber
            self.stalledHoursAgo = stalledHoursAgo
            self.isRescheduling = isRescheduling
        }
    }

    enum Action: Equatable {
        /// Progress CTA and the X close.
        case gotItTapped
        case delegate(Delegate)
        case rescheduleTapped
        case sendNowTapped

        enum Delegate: Equatable {
            case done
            case reschedule
            case sendNow
        }
    }

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .gotItTapped:
                return .send(.delegate(.done))

            case .rescheduleTapped:
                state.isRescheduling = true
                return .send(.delegate(.reschedule))

            case .sendNowTapped:
                return .send(.delegate(.sendNow))

            case .delegate:
                return .none
            }
        }
    }
}
