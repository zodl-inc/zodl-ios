//
//  ExportViewingKeysStore.swift
//  Zodl
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

enum ViewingKeyTab: Equatable, CaseIterable, Sendable {
    case qrCode
    case keyString
}

enum ViewingKeyConsent: CaseIterable, Equatable, Hashable, Sendable {
    case history
    case recipient
    case irreversible
}

@Reducer
struct ExportViewingKeys {
    @ObservableState
    struct State: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let session: ViewingKeyExportSession
        var selectedKind: ViewingKeyKind?
        var consent: Set<ViewingKeyConsent> = []
        var isConsentPresented = false
        var pendingFullExport = false
        var pendingOpenDetail: ViewingKeyKind?
        var isInactive = false
        var unavailableKey = false
        var isInvalidated = false
        var currentNetwork: NetworkType
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

        var canContinue: Bool {
            guard isSessionValid, let selectedKind else { return false }
            return session.key(for: selectedKind) != nil
        }

        var canExportFull: Bool {
            isSessionValid
                && selectedKind == .full
                && isConsentPresented
                && consent == Set(ViewingKeyConsent.allCases)
        }

        var isSessionValid: Bool {
            guard !isInvalidated,
                  session.matches(account: selectedWalletAccount, network: currentNetwork) else {
                return false
            }
            return walletAccounts.filter { session.matches(account: $0, network: currentNetwork) }.count == 1
        }

        var description: String { "<redacted viewing key export state>" }
        var debugDescription: String { description }
        var customMirror: Mirror {
            Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .struct)
        }

        init(session: ViewingKeyExportSession) {
            self.session = session
            self.currentNetwork = session.network
        }

        mutating func invalidateForExit() {
            isInvalidated = true
            isConsentPresented = false
            pendingFullExport = false
            pendingOpenDetail = nil
            consent = []
            isInactive = false
            unavailableKey = false
        }
    }

    enum Action: Equatable {
        enum Delegate: Equatable {
            case openDetail(ViewingKeyKind)
            case finished
        }

        case selectKind(ViewingKeyKind)
        case continueTapped
        case consentChanged(ViewingKeyConsent, Bool)
        case cancelConsent
        case exportFullTapped
        case consentDismissed
        case backTapped
        case becameInactive
        case becameActive
        case enteredBackground
        case validateSession
        case viewDisappeared
        case delegate(Delegate)
    }

    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            state.currentNetwork = zcashSDKEnvironment.network().networkType

            guard !state.isInvalidated else { return .none }

            guard state.isSessionValid else {
                state.invalidateForExit()
                return .send(.delegate(.finished))
            }

            switch action {
            case let .selectKind(kind):
                state.selectedKind = kind
                state.pendingOpenDetail = nil
                state.unavailableKey = state.session.key(for: kind) == nil
                return .none

            case .continueTapped:
                guard state.canContinue, state.pendingOpenDetail == nil,
                      let kind = state.selectedKind else { return .none }
                state.unavailableKey = false
                if kind == .incoming {
                    state.pendingOpenDetail = .incoming
                    return .send(.delegate(.openDetail(.incoming)))
                }
                state.consent = []
                state.pendingFullExport = false
                state.pendingOpenDetail = nil
                state.isConsentPresented = true
                return .none

            case let .consentChanged(item, isAccepted):
                guard state.isConsentPresented, state.selectedKind == .full else { return .none }
                if isAccepted {
                    state.consent.insert(item)
                } else {
                    state.consent.remove(item)
                }
                return .none

            case .cancelConsent:
                guard state.isConsentPresented else { return .none }
                state.consent = []
                state.isConsentPresented = false
                state.pendingFullExport = false
                state.pendingOpenDetail = nil
                return .none

            case .exportFullTapped:
                guard state.canExportFull else { return .none }
                state.isConsentPresented = false
                state.pendingFullExport = true
                return .none

            case .consentDismissed:
                guard state.pendingFullExport, state.selectedKind == .full else {
                    state.isConsentPresented = false
                    state.pendingFullExport = false
                    state.pendingOpenDetail = nil
                    state.consent = []
                    return .none
                }
                state.pendingFullExport = false
                state.isConsentPresented = false
                state.consent = []
                state.pendingOpenDetail = .full
                return .send(.delegate(.openDetail(.full)))

            case .backTapped, .enteredBackground, .viewDisappeared:
                state.invalidateForExit()
                return .send(.delegate(.finished))

            case .becameInactive:
                state.isInactive = true
                state.pendingOpenDetail = nil
                return .none

            case .becameActive:
                state.isInactive = false
                return .none

            case .validateSession, .delegate:
                return .none
            }
        }
    }
}
