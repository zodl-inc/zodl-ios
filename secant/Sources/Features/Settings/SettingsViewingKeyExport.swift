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

    /// Runs before forEach removes popped destinations, including a multi-screen back swipe.
    func viewingKeyPrePopReduce() -> Reduce<State, Action> {
        Reduce { state, action in
            switch action {
            case let .path(.popFrom(id)):
                guard let index = state.path.ids.firstIndex(of: id) else { return .none }
                let removedIDs = Array(state.path.ids.dropFirst(index))
                for removedID in removedIDs {
                    if state.path[id: removedID]?.viewingKeyDetail != nil {
                        state.path[id: removedID, case: \.viewingKeyDetail]?.invalidateForExit()
                    } else if state.path[id: removedID]?.exportViewingKeys != nil {
                        state.path[id: removedID, case: \.exportViewingKeys]?.invalidateForExit()
                    }
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

        case let .path(.element(id: id, action: .exportViewingKeys(.delegate(.openDetail(kind))))):
            return openViewingKeyDetail(state: &state, chooserID: id, kind: kind)

        case let .path(.element(id: id, action: .exportViewingKeys(.delegate(.finished)))):
            guard let chooser = state.path[id: id]?.exportViewingKeys else { return .none }
            for routeID in Array(state.path.ids.reversed()) {
                if state.path[id: routeID]?.viewingKeyDetail?.session == chooser.session {
                    state.path[id: routeID, case: \.viewingKeyDetail]?.invalidateForExit()
                    state.path[id: routeID] = nil
                }
            }
            state.path[id: id, case: \.exportViewingKeys]?.invalidateForExit()
            state.path[id: id] = nil
            return .none

        case let .path(.element(id: id, action: .viewingKeyDetail(.delegate(.finished)))):
            guard let detail = state.path[id: id]?.viewingKeyDetail else { return .none }
            if !state.isViewingKeySessionValid(detail.session, network: zcashSDKEnvironment.network().networkType) {
                return invalidateViewingKeyExport(state: &state)
            }
            state.path[id: id, case: \.viewingKeyDetail]?.invalidateForExit()
            state.path[id: id] = nil
            return .none

        case .viewingKeyBecameInactive:
            state.isViewingKeyInactive = true
            // Mask synchronously, before child cancellation effects are delivered.
            for id in state.path.ids {
                if state.path[id: id]?.viewingKeyDetail != nil {
                    state.path[id: id, case: \.viewingKeyDetail]?.isInactive = true
                } else if state.path[id: id]?.exportViewingKeys != nil {
                    state.path[id: id, case: \.exportViewingKeys]?.isInactive = true
                }
            }
            return forwardViewingKeyLifecycle(inactive: true, state: &state)

        case .viewingKeyBecameActive:
            state.isViewingKeyInactive = false
            return forwardViewingKeyLifecycle(inactive: false, state: &state)

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
        var chooser = ExportViewingKeys.State(session: pending.session)
        chooser.isInactive = state.isViewingKeyInactive
        state.path.append(.exportViewingKeys(chooser))
        return .none
    }

    private func openViewingKeyDetail(
        state: inout State,
        chooserID: StackElementID,
        kind: ViewingKeyKind
    ) -> Effect<Action> {
        guard state.path.ids.last == chooserID,
              let chooser = state.path[id: chooserID]?.exportViewingKeys,
              !chooser.isInvalidated,
              !state.isViewingKeyInactive,
              chooser.pendingOpenDetail == kind,
              chooser.selectedKind == kind,
              chooser.session.key(for: kind) != nil,
              state.isViewingKeySessionValid(
                chooser.session,
                network: zcashSDKEnvironment.network().networkType
              ) else {
            return .none
        }
        state.path[id: chooserID, case: \.exportViewingKeys]?.pendingOpenDetail = nil
        var detail = ViewingKeyDetail.State(session: chooser.session, kind: kind)
        detail.isInactive = state.isViewingKeyInactive
        state.path.append(.viewingKeyDetail(detail))
        return .none
    }

    private func validateViewingKeySessions(state: inout State) -> Effect<Action> {
        let network = zcashSDKEnvironment.network().networkType
        if let pending = state.pendingViewingKeyAuthentication,
           state.path.ids.last != pending.advancedSettingsID
            || !state.isViewingKeySessionValid(pending.session, network: network) {
            state.pendingViewingKeyAuthentication = nil
            let cleanup = removeInvalidViewingKeyRoutes(state: &state, network: network)
            return .merge(
                .cancel(id: ViewingKeyCancelID.authentication),
                cleanup
            )
        }
        return removeInvalidViewingKeyRoutes(state: &state, network: network)
    }

    private func removeInvalidViewingKeyRoutes(state: inout State, network: NetworkType) -> Effect<Action> {
        let hasInvalidRoute = state.path.contains { route in
            if let chooser = route.exportViewingKeys {
                return !state.isViewingKeySessionValid(chooser.session, network: network)
            }
            if let detail = route.viewingKeyDetail {
                return !state.isViewingKeySessionValid(detail.session, network: network)
            }
            return false
        }
        return hasInvalidRoute ? invalidateViewingKeyExport(state: &state) : .none
    }

    private func forwardViewingKeyLifecycle(inactive: Bool, state: inout State) -> Effect<Action> {
        let network = zcashSDKEnvironment.network().networkType
        let cleanup = removeInvalidViewingKeyRoutes(state: &state, network: network)
        var effects: [Effect<Action>] = [cleanup]
        for id in Array(state.path.ids) {
            if state.path[id: id]?.exportViewingKeys != nil {
                let action: ExportViewingKeys.Action = inactive ? .becameInactive : .becameActive
                effects.append(.send(.path(.element(id: id, action: .exportViewingKeys(action)))))
            } else if state.path[id: id]?.viewingKeyDetail != nil {
                let action: ViewingKeyDetail.Action = inactive ? .becameInactive : .becameActive
                effects.append(.send(.path(.element(id: id, action: .viewingKeyDetail(action)))))
            }
        }
        return .merge(effects)
    }

    func invalidateViewingKeyExport(state: inout State) -> Effect<Action> {
        state.pendingViewingKeyAuthentication = nil
        for id in Array(state.path.ids.reversed()) {
            if state.path[id: id]?.viewingKeyDetail != nil {
                state.path[id: id, case: \.viewingKeyDetail]?.invalidateForExit()
                state.path[id: id] = nil
            } else if state.path[id: id]?.exportViewingKeys != nil {
                state.path[id: id, case: \.exportViewingKeys]?.invalidateForExit()
                state.path[id: id] = nil
            }
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
        return path.allSatisfy { route in
            if let chooser = route.exportViewingKeys {
                return isViewingKeySessionValid(chooser.session, network: chooser.session.network)
            }
            if let detail = route.viewingKeyDetail {
                return isViewingKeySessionValid(detail.session, network: detail.session.network)
            }
            return true
        }
    }

    func isViewingKeySessionValid(_ session: ViewingKeyExportSession, network: NetworkType) -> Bool {
        session.matches(account: selectedWalletAccount, network: network)
            && walletAccounts.filter { session.matches(account: $0, network: network) }.count == 1
    }
}
