//
//  TCALoggerReducer.swift
//  Zashi
//
//  Created by Lukáš Korba on 23.01.2023.
//

import ComposableArchitecture
@preconcurrency import ZODLSwiftWalletSDK

extension Reducer {
    func logging(
        _ logger: ReducerLogger<State, Action>? = .tcaLogger
    ) -> LogChangesReducer<Self> {
        LogChangesReducer<Self>(base: self, logger: logger)
    }
}

struct ReducerLogger<State, Action> {
    private let _logChange: (_ receivedAction: Action, _ oldState: State, _ newState: State) -> Void
    
    init(
        logChange: @escaping (_ receivedAction: Action, _ oldState: State, _ newState: State) -> Void
    ) {
        self._logChange = logChange
    }
    
    func logChange(receivedAction: Action, oldState: State, newState: State) {
        self._logChange(receivedAction, oldState, newState)
    }
}

extension ReducerLogger {
    static var tcaLogger: Self {
        Self { receivedAction, oldState, newState in
            var target = ""
            target.write("received action:\n")
            CustomDump.customDump(receivedAction, to: &target, indent: 2)
            target.write("\n")
            target.write(diff(oldState, newState).map { "\($0)\n" } ?? "  (No state changes)\n")
            OSLogger.live.tcaDebug("\(target)")
        }
    }
}

// Bundles the (Action, State, State, ReducerLogger) capture for `.run { }` so that the closure's
// `@Sendable` requirement is satisfied by a single Sendable value rather than by every TCA
// macro-generated Action/ObservableState type. Safe because the boxed values are by-value copies
// local to `reduce`, and the logging closure only reads them via reflection (`customDump`/`diff`).
struct LogPayloadBox<State, Action>: @unchecked Sendable {
    @usableFromInline let action: Action
    @usableFromInline let oldState: State
    @usableFromInline let newState: State
    @usableFromInline let logger: ReducerLogger<State, Action>

    @usableFromInline
    init(action: Action, oldState: State, newState: State, logger: ReducerLogger<State, Action>) {
        self.action = action
        self.oldState = oldState
        self.newState = newState
        self.logger = logger
    }
}

struct LogChangesReducer<Base: Reducer>: Reducer {
    @usableFromInline let base: Base

    @usableFromInline let logger: ReducerLogger<Base.State, Base.Action>?

    @usableFromInline
    init(base: Base, logger: ReducerLogger<Base.State, Base.Action>?) {
        self.base = base
        self.logger = logger
    }

    @inlinable
    func reduce(
        into state: inout Base.State, action: Base.Action
    ) -> Effect<Base.Action> {
        guard let logger else {
            return self.base.reduce(into: &state, action: action)
        }

        let oldState = state
        let effects = self.base.reduce(into: &state, action: action)
        let payload = LogPayloadBox(
            action: action,
            oldState: oldState,
            newState: state,
            logger: logger
        )
        return effects.merge(
            with: .run { _ in
                payload.logger.logChange(
                    receivedAction: payload.action,
                    oldState: payload.oldState,
                    newState: payload.newState
                )
            }
        )
    }
}
