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

enum QRFailure: Error, Equatable, Sendable {
    case generationFailed
}

struct ViewingKeySharePayload: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id: UUID
    let key: ViewingKeyMaterial
    let png: ViewingKeyPNG

    var description: String { "<redacted viewing key share payload>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .struct)
    }
}

@Reducer
struct ExportViewingKeys {
    private enum CancelID {
        case qr
        case share
    }

    @ObservableState
    struct State: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        struct Detail: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
            let kind: ViewingKeyKind
            var tab: ViewingKeyTab = .qrCode
            var isRevealed = false
            var key: ViewingKeyMaterial?
            var qr: ViewingKeyPNG?
            var qrFailed = false
            var qrRequestID: UUID?
            var shareRequestID: UUID?
            var sharePayload: ViewingKeySharePayload?
            var isSharePresented = false

            var description: String { "<redacted viewing key detail>" }
            var debugDescription: String { description }
            var customMirror: Mirror {
                Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .struct)
            }

            init(kind: ViewingKeyKind) {
                self.kind = kind
            }
        }

        let session: ViewingKeyExportSession
        var selectedKind: ViewingKeyKind?
        var consent: Set<ViewingKeyConsent> = []
        var isConsentPresented = false
        var pendingFullExport = false
        var detail: Detail?
        var isInactive = false
        var unavailableKey = false
        var sharingError = false
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

        var canShare: Bool {
            guard isPayloadVisible, let detail else { return false }
            return detail.key != nil && detail.shareRequestID == nil && detail.sharePayload == nil
        }

        var isPayloadVisible: Bool {
            isSessionValid && !isInactive && detail?.isRevealed == true
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
    }

    enum Action: Equatable {
        enum Delegate: Equatable {
            case finished
        }

        case selectKind(ViewingKeyKind)
        case continueTapped
        case consentChanged(ViewingKeyConsent, Bool)
        case cancelConsent
        case exportFullTapped
        case consentDismissed
        case selectTab(ViewingKeyTab)
        case revealTapped
        case hideTapped
        case shareTapped
        case qrReady(UUID, Result<ViewingKeyPNG, QRFailure>)
        case shareReady(UUID, Result<ViewingKeySharePayload, QRFailure>)
        case sharePresented
        case shareDismissed
        case dismissError
        case displayKeyString
        case backTapped
        case becameInactive
        case becameActive
        case enteredBackground
        case validateSession
        case viewDisappeared
        case delegate(Delegate)
    }

    @Dependency(\.viewingKeyQRCode) var viewingKeyQRCode
    @Dependency(\.uuid) var uuid
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            state.currentNetwork = zcashSDKEnvironment.network().networkType

            if state.isInvalidated {
                if case .shareDismissed = action {
                    state.detail?.sharePayload = nil
                    state.detail?.isSharePresented = false
                }
                return .none
            }

            if !state.isSessionValid {
                state.isInvalidated = true
                clearDisclosure(state: &state)
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share),
                    .send(.delegate(.finished))
                )
            }

            switch action {
            case let .selectKind(kind):
                guard state.isSessionValid else { return .none }
                state.selectedKind = kind
                state.unavailableKey = state.session.key(for: kind) == nil
                return .none

            case .continueTapped:
                guard state.canContinue, let selectedKind = state.selectedKind else { return .none }
                state.unavailableKey = false
                switch selectedKind {
                case .incoming:
                    state.detail = State.Detail(kind: .incoming)
                case .full:
                    state.consent = []
                    state.pendingFullExport = false
                    state.isConsentPresented = true
                }
                return .none

            case let .consentChanged(item, isAccepted):
                guard state.isSessionValid, state.isConsentPresented, state.selectedKind == .full else { return .none }
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
                return .none

            case .exportFullTapped:
                guard state.canExportFull else { return .none }
                state.isConsentPresented = false
                state.pendingFullExport = true
                return .none

            case .consentDismissed:
                guard state.isConsentPresented || state.pendingFullExport else {
                    return .none
                }
                if state.pendingFullExport, state.selectedKind == .full {
                    state.pendingFullExport = false
                    state.detail = State.Detail(kind: .full)
                } else {
                    state.consent = []
                    state.isConsentPresented = false
                    state.pendingFullExport = false
                }
                return .none

            case let .selectTab(tab):
                guard state.detail != nil else { return .none }
                state.detail?.tab = tab
                return .none

            case .revealTapped:
                guard !state.isInactive,
                      var detail = state.detail,
                      !detail.isRevealed,
                      let key = state.session.key(for: detail.kind) else {
                    return .none
                }
                let requestID = uuid()
                detail.isRevealed = true
                detail.key = key
                detail.qr = nil
                detail.qrFailed = false
                detail.qrRequestID = requestID
                state.detail = detail
                return generateQRCode(key: key, requestID: requestID)

            case .hideTapped:
                guard var detail = state.detail else { return .none }
                detail.isRevealed = false
                detail.key = nil
                detail.qr = nil
                detail.qrFailed = false
                detail.qrRequestID = nil
                detail.shareRequestID = nil
                if !detail.isSharePresented {
                    detail.sharePayload = nil
                }
                state.detail = detail
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share)
                )

            case .shareTapped:
                guard state.canShare,
                      var detail = state.detail,
                      let key = detail.key else {
                    return .none
                }
                let requestID = uuid()
                detail.shareRequestID = requestID
                state.detail = detail
                return .run { @Sendable [key, requestID, png = viewingKeyQRCode.png] send in
                    do {
                        let image = try await png(key)
                        try Task.checkCancellation()
                        await send(.shareReady(
                            requestID,
                            .success(ViewingKeySharePayload(id: requestID, key: key, png: image))
                        ))
                    } catch is CancellationError {
                        return
                    } catch {
                        await send(.shareReady(requestID, .failure(.generationFailed)))
                    }
                }
                .cancellable(id: CancelID.share, cancelInFlight: true)

            case let .qrReady(requestID, result):
                guard var detail = state.detail,
                      detail.isRevealed,
                      !state.isInactive,
                      detail.qrRequestID == requestID else {
                    return .none
                }
                detail.qrRequestID = nil
                switch result {
                case let .success(png):
                    detail.qr = png
                    detail.qrFailed = false
                case .failure:
                    detail.qr = nil
                    detail.qrFailed = true
                }
                state.detail = detail
                return .none

            case let .shareReady(requestID, result):
                guard var detail = state.detail,
                      detail.isRevealed,
                      !state.isInactive,
                      detail.shareRequestID == requestID else {
                    return .none
                }
                detail.shareRequestID = nil
                switch result {
                case let .success(payload):
                    detail.sharePayload = payload
                case .failure:
                    detail.sharePayload = nil
                    state.sharingError = true
                }
                state.detail = detail
                return .none

            case .sharePresented:
                guard state.isPayloadVisible, state.detail?.sharePayload != nil else { return .none }
                state.detail?.isSharePresented = true
                return .none

            case .shareDismissed:
                state.detail?.sharePayload = nil
                state.detail?.isSharePresented = false
                return .none

            case .dismissError:
                state.sharingError = false
                return .none

            case .displayKeyString:
                guard state.detail != nil else { return .none }
                state.detail?.tab = .keyString
                return .none

            case .backTapped:
                state.detail = nil
                state.sharingError = false
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share)
                )

            case .becameInactive:
                state.isInactive = true
                state.detail?.qrRequestID = nil
                if state.detail?.isSharePresented != true {
                    state.detail?.shareRequestID = nil
                    state.detail?.sharePayload = nil
                }
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share)
                )

            case .becameActive:
                state.isInactive = false
                guard var detail = state.detail,
                      detail.isRevealed,
                      detail.qr == nil,
                      !detail.qrFailed,
                      detail.qrRequestID == nil,
                      let key = detail.key else {
                    return .none
                }
                let requestID = uuid()
                detail.qrRequestID = requestID
                state.detail = detail
                return generateQRCode(key: key, requestID: requestID)

            case .enteredBackground, .viewDisappeared:
                state.isInvalidated = true
                clearDisclosure(state: &state)
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share),
                    .send(.delegate(.finished))
                )

            case .validateSession, .delegate:
                return .none
            }
        }
    }

    private func clearDisclosure(state: inout State) {
        state.isConsentPresented = false
        state.pendingFullExport = false
        state.consent = []
        state.isInactive = false
        state.unavailableKey = false
        state.sharingError = false
        guard var detail = state.detail else { return }
        detail.isRevealed = false
        detail.key = nil
        detail.qr = nil
        detail.qrFailed = false
        detail.qrRequestID = nil
        detail.shareRequestID = nil
        if !detail.isSharePresented {
            detail.sharePayload = nil
        }
        state.detail = detail
    }

    private func generateQRCode(key: ViewingKeyMaterial, requestID: UUID) -> Effect<Action> {
        Effect.run { @Sendable [key, requestID, png = viewingKeyQRCode.png] send in
            do {
                let image = try await png(key)
                try Task.checkCancellation()
                await send(.qrReady(requestID, .success(image)))
            } catch is CancellationError {
                return
            } catch {
                await send(.qrReady(requestID, .failure(.generationFailed)))
            }
        }
        .cancellable(id: CancelID.qr, cancelInFlight: true)
    }
}
