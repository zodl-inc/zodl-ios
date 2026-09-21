import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

extension Settings {
    enum ViewingKeyCancelID {
        case authentication
    }

    struct PendingViewingKeyAuthentication: Equatable {
        let requestID: UUID
        let advancedSettingsID: StackElementID
        let session: ViewingKeyExportSession
    }

    /// Runs before forEach removes a popped destination, including a multi-screen back swipe.
    func viewingKeyPrePopReduce() -> Reduce<State, Action> {
        Reduce { state, action in
            switch action {
            case let .path(.popFrom(id)):
                guard let index = state.path.ids.firstIndex(of: id) else { return .none }
                let removedIDs = Array(state.path.ids.dropFirst(index))
                for removedID in removedIDs where state.path[id: removedID]?.exportViewingKeys != nil {
                    state.path[id: removedID, case: \.exportViewingKeys]?.invalidateForExit()
                }
                if let pending = state.pendingViewingKeyAuthentication,
                   removedIDs.contains(pending.advancedSettingsID) {
                    state.pendingViewingKeyAuthentication = nil
                    return .cancel(id: ViewingKeyCancelID.authentication)
                }
                return .none

            default:
                return .none
            }
        }
    }

    /// Runs inside forEach's parent reducer so removing a route also cancels its effects.
    func reduceViewingKeyExport(state: inout State, action: Action) -> Effect<Action>? {
        switch action {
        case let .path(.element(id: id, action: .advancedSettings(.operationAccessCheck(.exportViewingKey)))):
            return beginViewingKeyAuthentication(state: &state, advancedSettingsID: id)

        case let .viewingKeyAuthenticationFinished(requestID, success):
            return finishViewingKeyAuthentication(state: &state, requestID: requestID, success: success)

        case let .path(.element(id: id, action: .exportViewingKeys(.delegate(.finished)))):
            state.path[id: id, case: \.exportViewingKeys]?.invalidateForExit()
            state.path[id: id] = nil
            return Effect.none

        case .viewingKeyBecameInactive:
            state.isViewingKeyInactive = true
            // Mask synchronously, before the child cancellation action is delivered.
            for id in state.path.ids where state.path[id: id]?.exportViewingKeys != nil {
                state.path[id: id, case: \.exportViewingKeys]?.isInactive = true
            }
            return forwardViewingKeyLifecycle(.becameInactive, state: &state)

        case .viewingKeyBecameActive:
            state.isViewingKeyInactive = false
            return forwardViewingKeyLifecycle(.becameActive, state: &state)

        case .validateViewingKeySession:
            return validateViewingKeySessions(state: &state)

        case .viewingKeyEnteredBackground:
            state.isViewingKeyInactive = true
            return invalidateViewingKeyExport(state: &state)

        case .backToHomeTapped, .viewingKeySettingsDisappeared, .invalidateViewingKeyExport,
            .path(.element(id: _, action: .resetZashi(.deleteTapped))),
            .path(.element(id: _, action: .disconnectHWWallet(.disconnectConfirmed))),
            .path(.element(id: _, action: .disconnectHWWallet(.disconnectFinished))):
            return invalidateViewingKeyExport(state: &state)

        default:
            return nil
        }
    }

    private func beginViewingKeyAuthentication(state: inout State, advancedSettingsID id: StackElementID) -> Effect<Action> {
        guard state.pendingViewingKeyAuthentication == nil,
              state.path.ids.last == id,
              state.path[id: id]?.advancedSettings != nil,
              let account = state.selectedWalletAccount else { return .none }
        let requestID = uuid()
        let session = ViewingKeyExportSession(
            id: requestID,
            account: account,
            network: zcashSDKEnvironment.network().networkType
        )
        guard state.isViewingKeySessionValid(session, network: session.network) else { return .none }
        state.pendingViewingKeyAuthentication = PendingViewingKeyAuthentication(
            requestID: requestID,
            advancedSettingsID: id,
            session: session
        )
        return localAuthentication.gated(
            success: Settings.Action.viewingKeyAuthenticationFinished(requestID, true),
            cancelled: Settings.Action.viewingKeyAuthenticationFinished(requestID, false)
        )
        .cancellable(id: ViewingKeyCancelID.authentication, cancelInFlight: true)
    }

    private func finishViewingKeyAuthentication(state: inout State, requestID: UUID, success: Bool) -> Effect<Action> {
        guard let pending = state.pendingViewingKeyAuthentication,
              pending.requestID == requestID else { return .none }
        state.pendingViewingKeyAuthentication = nil
        guard success,
              state.path.ids.last == pending.advancedSettingsID,
              state.path[id: pending.advancedSettingsID]?.advancedSettings != nil,
              state.isViewingKeySessionValid(pending.session, network: zcashSDKEnvironment.network().networkType) else {
            return .none
        }
        var flow = ExportViewingKeys.State(session: pending.session)
        flow.isInactive = state.isViewingKeyInactive
        state.path.append(.exportViewingKeys(flow))
        return .none
    }

    private func validateViewingKeySessions(state: inout State) -> Effect<Action> {
        let network = zcashSDKEnvironment.network().networkType
        var effects: [Effect<Action>] = []
        if let pending = state.pendingViewingKeyAuthentication,
           state.path.ids.last != pending.advancedSettingsID
            || !state.isViewingKeySessionValid(pending.session, network: network) {
            state.pendingViewingKeyAuthentication = nil
            effects.append(.cancel(id: ViewingKeyCancelID.authentication))
        }
        for id in Array(state.path.ids) {
            guard let flow = state.path[id: id]?.exportViewingKeys,
                  !state.isViewingKeySessionValid(flow.session, network: network) else { continue }
            state.path[id: id, case: \.exportViewingKeys]?.invalidateForExit()
            state.path[id: id] = nil
        }
        return .merge(effects)
    }

    private func forwardViewingKeyLifecycle(_ action: ExportViewingKeys.Action, state: inout State) -> Effect<Action> {
        let network = zcashSDKEnvironment.network().networkType
        var effects: [Effect<Action>] = []
        for id in Array(state.path.ids) {
            guard let flow = state.path[id: id]?.exportViewingKeys else { continue }
            guard state.isViewingKeySessionValid(flow.session, network: network) else {
                state.path[id: id, case: \.exportViewingKeys]?.invalidateForExit()
                state.path[id: id] = nil
                continue
            }
            effects.append(.send(.path(.element(id: id, action: .exportViewingKeys(action)))))
        }
        return .merge(effects)
    }

    func invalidateViewingKeyExport(state: inout State) -> Effect<Action> {
        state.pendingViewingKeyAuthentication = nil
        for id in Array(state.path.ids) where state.path[id: id]?.exportViewingKeys != nil {
            state.path[id: id, case: \.exportViewingKeys]?.invalidateForExit()
            state.path[id: id] = nil
        }
        return .cancel(id: ViewingKeyCancelID.authentication)
    }
}

extension Settings.State {
    /// Observing this fence ignores rotating receive addresses while tracking SDK provenance
    /// and authoritative account membership. Reducer results also revalidate independently.
    var isViewingKeyProvenanceValid: Bool {
        if let pending = pendingViewingKeyAuthentication {
            return path.ids.last == pending.advancedSettingsID
                && isViewingKeySessionValid(pending.session, network: pending.session.network)
        }
        return path.compactMap { $0.exportViewingKeys }.allSatisfy {
            isViewingKeySessionValid($0.session, network: $0.session.network)
        }
    }

    func isViewingKeySessionValid(_ session: ViewingKeyExportSession, network: NetworkType) -> Bool {
        session.matches(account: selectedWalletAccount, network: network)
            && walletAccounts.filter { session.matches(account: $0, network: network) }.count == 1
    }
}
