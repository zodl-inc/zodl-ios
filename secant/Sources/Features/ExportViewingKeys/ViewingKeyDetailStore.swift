//
//  ViewingKeyDetailStore.swift
//  Zodl
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

@Reducer
struct ViewingKeyDetail {
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
            var shareOwnership: ViewingKeyShareOwnership?
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
        var detail: Detail
        var isInactive = false
        var sharingError = false
        var isInvalidated = false
        var currentNetwork: NetworkType
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []

        var canShare: Bool {
            isPayloadVisible
                && detail.key != nil
                && detail.shareRequestID == nil
                && detail.sharePayload == nil
                && detail.shareOwnership == nil
        }

        var isPayloadVisible: Bool {
            isSessionValid && !isInactive && detail.isRevealed
        }

        var isSessionValid: Bool {
            guard !isInvalidated,
                  session.matches(account: selectedWalletAccount, network: currentNetwork) else {
                return false
            }
            return walletAccounts.filter { session.matches(account: $0, network: currentNetwork) }.count == 1
        }

        var description: String { "<redacted viewing key detail state>" }
        var debugDescription: String { description }
        var customMirror: Mirror {
            Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .struct)
        }

        init(session: ViewingKeyExportSession, kind: ViewingKeyKind) {
            self.session = session
            self.detail = Detail(kind: kind)
            self.currentNetwork = session.network
        }

        /// Scrubs app-owned material before the route is removed. A claimed UIKit token finishes independently.
        mutating func invalidateForExit() {
            isInvalidated = true
            isInactive = false
            sharingError = false
            detail.isRevealed = false
            detail.key = nil
            detail.qr = nil
            detail.qrFailed = false
            detail.qrRequestID = nil
            detail.shareRequestID = nil
            if detail.shareOwnership?.cancelPreparedUnlessNativeOwned() != true {
                detail.sharePayload = nil
                detail.shareOwnership = nil
                detail.isSharePresented = false
            }
        }
    }

    enum Action: Equatable {
        enum Delegate: Equatable {
            case finished
        }

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
                    state.detail.shareOwnership?.finish()
                    state.detail.sharePayload = nil
                    state.detail.shareOwnership = nil
                    state.detail.isSharePresented = false
                }
                return .none
            }

            if !state.isSessionValid {
                state.invalidateForExit()
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share),
                    .send(.delegate(.finished))
                )
            }

            switch action {
            case let .selectTab(tab):
                state.detail.tab = tab
                return .none

            case .revealTapped:
                guard !state.isInactive,
                      !state.detail.isRevealed,
                      let key = state.session.key(for: state.detail.kind) else {
                    return .none
                }
                let requestID = uuid()
                state.detail.isRevealed = true
                state.detail.key = key
                state.detail.qr = nil
                state.detail.qrFailed = false
                state.detail.qrRequestID = requestID
                return generateQRCode(key: key, requestID: requestID)

            case .hideTapped:
                state.detail.isRevealed = false
                state.detail.key = nil
                state.detail.qr = nil
                state.detail.qrFailed = false
                state.detail.qrRequestID = nil
                state.detail.shareRequestID = nil
                if state.detail.shareOwnership?.cancelPreparedUnlessNativeOwned() != true {
                    state.detail.sharePayload = nil
                    state.detail.shareOwnership = nil
                    state.detail.isSharePresented = false
                }
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share)
                )

            case .shareTapped:
                guard state.canShare, let key = state.detail.key else { return .none }
                let requestID = uuid()
                state.detail.shareRequestID = requestID
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
                guard state.detail.isRevealed,
                      !state.isInactive,
                      state.detail.qrRequestID == requestID else {
                    return .none
                }
                state.detail.qrRequestID = nil
                switch result {
                case let .success(png):
                    state.detail.qr = png
                    state.detail.qrFailed = false
                case .failure:
                    state.detail.qr = nil
                    state.detail.qrFailed = true
                }
                return .none

            case let .shareReady(requestID, result):
                guard state.detail.isRevealed,
                      !state.isInactive,
                      state.detail.shareRequestID == requestID else {
                    return .none
                }
                state.detail.shareRequestID = nil
                switch result {
                case let .success(payload):
                    state.detail.sharePayload = payload
                    state.detail.shareOwnership = ViewingKeyShareOwnership(payloadID: payload.id)
                case .failure:
                    state.detail.sharePayload = nil
                    state.detail.shareOwnership = nil
                    state.sharingError = true
                }
                return .none

            case .sharePresented:
                guard let payload = state.detail.sharePayload,
                      state.detail.shareOwnership?.payloadID == payload.id,
                      state.detail.shareOwnership?.hasNativeOwnership == true else {
                    return .none
                }
                state.detail.isSharePresented = true
                return .none

            case .shareDismissed:
                state.detail.shareOwnership?.finish()
                state.detail.sharePayload = nil
                state.detail.shareOwnership = nil
                state.detail.isSharePresented = false
                return .none

            case .dismissError:
                state.sharingError = false
                return .none

            case .displayKeyString:
                state.detail.tab = .keyString
                return .none

            case .backTapped:
                state.invalidateForExit()
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share),
                    .send(.delegate(.finished))
                )

            case .becameInactive:
                state.isInactive = true
                state.detail.qrRequestID = nil
                let nativeOwnsPayload = state.detail.shareOwnership?.cancelPreparedUnlessNativeOwned() == true
                if !nativeOwnsPayload {
                    state.detail.shareRequestID = nil
                    state.detail.sharePayload = nil
                    state.detail.shareOwnership = nil
                    state.detail.isSharePresented = false
                }
                return .merge(
                    .cancel(id: CancelID.qr),
                    .cancel(id: CancelID.share)
                )

            case .becameActive:
                state.isInactive = false
                guard state.detail.isRevealed,
                      state.detail.qr == nil,
                      !state.detail.qrFailed,
                      state.detail.qrRequestID == nil,
                      let key = state.detail.key else {
                    return .none
                }
                let requestID = uuid()
                state.detail.qrRequestID = requestID
                return generateQRCode(key: key, requestID: requestID)

            case .enteredBackground, .viewDisappeared:
                state.invalidateForExit()
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
