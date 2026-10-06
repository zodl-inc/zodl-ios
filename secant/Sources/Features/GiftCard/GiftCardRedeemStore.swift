//
//  GiftCardRedeemStore.swift
//  Zodl
//
//  Created by Zodl on 2026-10-03.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

/// One gift card, from "looking for your gift" to "redeemed". Opens the card's isolated wallet
/// through `GiftCardClient`, waits for its sync, offers to redeem what it holds into the selected
/// account's shielded (Orchard-only) address, and reports the outcome.
///
/// The link is a bearer secret: it lives only in `state.link` (redacted) and is handed to the
/// client, never logged. Root closes wallets on parent navigation, while `GiftCardCoordFlow`
/// handles internal replacement. A cancelled open closes its returned handle itself.
@Reducer
struct GiftCardRedeem {
    enum Constants {
        /// How long the pending screen waits before checking again on its own, in seconds.
        static let autoRetryInterval = 30
    }

    @ObservableState
    struct State: Equatable {
        enum Step: Equatable {
            /// Opening and syncing the card's wallet.
            case checking
            /// The card can be redeemed; `redeemable` is what the wallet receives, after the fee.
            case ready(redeemable: Zatoshi)
            /// `amount` is still waiting for confirmations.
            case pending(amount: Zatoshi, confirmationsNeeded: Int?)
            /// Already redeemed, or not funded yet. Check again may find funds.
            case empty
            /// Holding no more than the network fee: nothing to redeem, and checking again cannot
            /// change that.
            case dust
            case invalidLink
            /// A card for a newer link format.
            case unsupportedVersion
            case wrongNetwork
            /// The card's balance could not be determined.
            case checkFailed
            /// This build cannot redeem gift cards yet.
            case unavailable
            /// `amount` is what the wallet is to receive, after the network fee.
            case redeeming(amount: Zatoshi)
            /// Redeemed; `received` is what the wallet gets, after the network fee.
            case success(received: Zatoshi)
            /// `amount` is what the wallet was to receive.
            case failure(amount: Zatoshi)
        }

        var cancelId = UUID()
        var autoRetryCancelId = UUID()

        var link: RedactableString
        var summary: GiftCardSummary?
        var handle: GiftCardHandle?
        var step: Step = .checking
        /// Sync progress of the card's wallet, `0...1`, while `step == .checking`.
        var syncProgress: Double?
        /// A Check again the user asked for on the Pending or Nothing to redeem screen is running:
        /// the screen stays, with its button busy.
        var isRechecking = false
        /// A check of a pending or empty card is running in the background (Check again, or the
        /// pending screen's own periodic check). Its failure keeps the screen as it is.
        var isQuietCheckInFlight = false
        /// The selected account's Orchard-only unified address, resolved in the background.
        var destinationAddress: RedactableString?
        var destinationAccountId: AccountUUID?
        var txId: String?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        var message: String? {
            guard let message = summary?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
                return nil
            }
            return message
        }

        /// The amount the step is about, available only before a successful redemption: what the
        /// wallet is to receive (Ready, Redeeming, Redemption not confirmed), or what is still
        /// waiting for confirmations (Pending).
        var amount: Zatoshi? {
            switch step {
            case .ready(let amount), .pending(let amount, _), .redeeming(let amount), .failure(let amount):
                return amount
            case .checking, .empty, .dust, .invalidLink, .unsupportedVersion, .wrongNetwork, .checkFailed, .unavailable, .success:
                return nil
            }
        }

        /// The amount the screens show: what the wallet receives from this card, after the network
        /// fee the wallet SDK computed for the card's notes, or (Pending) what is still waiting for
        /// confirmations.
        var receivedAmount: Zatoshi? {
            if case .success(let received) = step {
                return received
            }
            return amount
        }

        var isRedeemable: Bool {
            if case .ready(let redeemable) = step {
                return redeemable.amount > 0 && selectedWalletAccount != nil
            }
            return false
        }

        /// Whether the step offers Check again / Try again. A dust card does not: checking it again
        /// cannot help.
        var canRetry: Bool {
            switch step {
            case .pending, .empty, .checkFailed, .failure:
                return true
            default:
                return false
            }
        }

        /// Whether a retry keeps the screen and checks the card in the background: Pending and
        /// Nothing to redeem, while the card's wallet is open.
        var retriesQuietly: Bool {
            guard handle != nil else {
                return false
            }
            switch step {
            case .pending, .empty:
                return true
            default:
                return false
            }
        }

        init(link: RedactableString) {
            self.link = link
        }
    }

    enum Action: Equatable {
        case closeTapped
        case delegate(Delegate)
        case onAppear
        case redeemTapped
        case retryTapped
        case response(UUID, Response)

        enum Response: Equatable {
            case autoRetryFired
            case checkFailed(GiftCardClientError)
            case destinationResolved(AccountUUID, RedactableString?)
            case redemptionDestinationResolved(AccountUUID, RedactableString?)
            case opened(GiftCardHandle)
            case openFailed(GiftCardClientError)
            case progressUpdated(Double)
            /// A background check of a pending or empty card failed; the screen stays.
            case recheckFailed(GiftCardClientError)
            /// A background check of a pending or empty card answered.
            case recheckLoaded(GiftCardStatus)
            case redeemFailed(GiftCardClientError)
            case redeemSucceeded(GiftCardRedemption)
            case statusLoaded(GiftCardStatus)
        }

        @CasePathable
        enum Delegate: Equatable {
            /// The user is done with the flow (any step).
            case dismiss
            /// The card was swept into the wallet; the wallet's history should refresh.
            case redeemed
        }
    }

    @Dependency(\.giftCard) var giftCard
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    init() { }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            if case let .response(visit, response) = action, visit != state.cancelId {
                if case .opened(let handle) = response {
                    return .run { _ in await giftCard.cleanup(handle) }
                }
                return .none
            }
            switch action {
            case .onAppear:
                // Only the first appearance starts work; coming back to this screen keeps its state.
                guard state.summary == nil, state.step == .checking else {
                    return .none
                }
                return start(&state)

            case .retryTapped where state.retriesQuietly:
                // Pending and Nothing to redeem keep their screen while the card is checked again.
                state.isRechecking = true
                return quietCheck(&state)

            case .response(_, .autoRetryFired):
                // The pending screen checks again on its own, quietly.
                guard state.retriesQuietly, !state.isRechecking else {
                    return .none
                }
                return quietCheck(&state)

            case .retryTapped:
                guard state.canRetry else {
                    return .none
                }
                state.isRechecking = false
                state.isQuietCheckInFlight = false
                state.step = .checking
                state.syncProgress = nil
                if let handle = state.handle {
                    return .merge(
                        .cancel(id: state.autoRetryCancelId),
                        check(handle, state: state)
                    )
                }
                return .merge(
                    .cancel(id: state.autoRetryCancelId),
                    start(&state)
                )

            case .response(_, .opened(let handle)):
                state.handle = handle
                return check(handle, state: state)

            case .response(_, .openFailed(let error)), .response(_, .checkFailed(let error)):
                state.syncProgress = nil
                state.step = step(for: error)
                if error == .unknownHandle {
                    // The card's wallet is gone (it could not be reopened after a failed sweep),
                    // so Retry must open the card again rather than check a handle that is dead.
                    state.handle = nil
                }
                return .cancel(id: state.cancelId)

            case .response(_, .progressUpdated(let progress)):
                guard state.step == .checking else {
                    return .none
                }
                state.syncProgress = min(max(progress, 0), 1)
                return .none

            case .response(_, .statusLoaded(let status)):
                state.syncProgress = nil
                return show(status, state: &state)

            case .response(_, .recheckLoaded(let status)):
                state.isRechecking = false
                state.isQuietCheckInFlight = false
                // A redemption, a close or a full retry may have started meanwhile.
                guard state.retriesQuietly else {
                    return .none
                }
                return show(status, state: &state)

            case .response(_, .recheckFailed(let error)):
                state.isRechecking = false
                state.isQuietCheckInFlight = false
                if error == .unknownHandle {
                    // The card's wallet is gone: the next Check again opens the card again.
                    state.handle = nil
                }
                // A pending card keeps checking on its own while its wallet is open.
                guard case .pending = state.step, state.handle != nil else {
                    return .none
                }
                return scheduleAutoRetry(state)

            case .response(_, .destinationResolved(let accountId, let address)):
                guard state.selectedWalletAccount?.id == accountId else { return .none }
                state.destinationAccountId = accountId
                state.destinationAddress = address
                return .none

            case .redeemTapped:
                guard state.isRedeemable, case .ready(let redeemable) = state.step, state.handle != nil else {
                    return .none
                }
                state.isRechecking = false
                state.isQuietCheckInFlight = false
                state.step = .redeeming(amount: redeemable)
                return resolveRedemptionDestination(state)

            case .response(_, .redemptionDestinationResolved(let accountId, let address)):
                guard case .redeeming = state.step, let handle = state.handle else { return .none }
                guard state.selectedWalletAccount?.id == accountId else {
                    return resolveRedemptionDestination(state)
                }
                guard let address else {
                    return .send(.response(state.cancelId, .redeemFailed(.redeemFailed)))
                }
                state.destinationAccountId = accountId
                state.destinationAddress = address
                let visit = state.cancelId
                let selectedAccount = state.$selectedWalletAccount
                return .run { send in
                    guard !Task.isCancelled else { return }
                    guard selectedAccount.wrappedValue?.id == accountId else {
                        await send(.response(visit, .redemptionDestinationResolved(accountId, nil)))
                        return
                    }
                    do {
                        let redemption = try await giftCard.redeem(handle, address.data)
                        await send(.response(visit, .redeemSucceeded(redemption)))
                    } catch is CancellationError {
                        return
                    } catch let error as GiftCardClientError {
                        await send(.response(visit, .redeemFailed(error)))
                    } catch {
                        await send(.response(visit, .redeemFailed(.redeemFailed)))
                    }
                }
                .cancellable(id: visit)

            case .response(_, .redeemSucceeded(let redemption)):
                guard case .redeeming(let amount) = state.step else {
                    return .none
                }
                state.txId = redemption.txId
                // What the redemption's own proposal sent; the Ready figure if it is not known.
                state.step = .success(received: redemption.received ?? amount)
                return .send(.delegate(.redeemed))

            case .response(_, .redeemFailed(let error)):
                guard case .redeeming(let amount) = state.step else {
                    return .none
                }
                switch error {
                case .unavailable:
                    state.step = .unavailable
                case .nothingToRedeem:
                    // Nothing was created or sent: the card was redeemed elsewhere meanwhile, or
                    // what it holds would all go to the fee. A fresh check tells which (Nothing to
                    // redeem, or the dust screen) instead of offering a Retry that fails the same way.
                    guard let handle = state.handle else {
                        state.step = .empty
                        return .none
                    }
                    state.step = .checking
                    return check(handle, state: state)
                default:
                    state.step = .failure(amount: amount)
                }
                return .none

            case .closeTapped:
                state.isRechecking = false
                state.isQuietCheckInFlight = false
                return .merge(
                    .cancel(id: state.cancelId),
                    .cancel(id: state.autoRetryCancelId),
                    .send(.delegate(.dismiss))
                )

            case .delegate:
                return .none
            }
        }
    }
}

extension GiftCardRedeem {
    /// Moves to the screen for `status`. A pending card checks again on its own after
    /// `Constants.autoRetryInterval`.
    private func show(_ status: GiftCardStatus, state: inout State) -> Effect<Action> {
        switch status {
        case let .ready(spendable, redeemable):
            // The wallet SDK reports a card as ready only when the fee leaves something to send.
            if redeemable.amount > 0 {
                state.step = .ready(redeemable: redeemable)
            } else {
                state.step = spendable.amount > 0 ? .dust : .empty
            }
            return .cancel(id: state.autoRetryCancelId)
        case let .pending(amount, confirmationsNeeded):
            state.step = .pending(amount: amount, confirmationsNeeded: confirmationsNeeded)
            return scheduleAutoRetry(state)
        case .dust:
            state.step = .dust
            return .cancel(id: state.autoRetryCancelId)
        case .empty:
            state.step = .empty
            return .cancel(id: state.autoRetryCancelId)
        }
    }

    private func scheduleAutoRetry(_ state: State) -> Effect<Action> {
        let visit = state.cancelId
        return .run { send in
            try await mainQueue.sleep(for: .seconds(Constants.autoRetryInterval))
            await send(.response(visit, .autoRetryFired))
        }
        .cancellable(id: state.autoRetryCancelId, cancelInFlight: true)
    }

    /// Checks the card again without leaving the Pending or Nothing to redeem screen. A check
    /// already running in the background is joined rather than repeated.
    private func quietCheck(_ state: inout State) -> Effect<Action> {
        guard let handle = state.handle else {
            return .none
        }
        guard !state.isQuietCheckInFlight else {
            return .none
        }
        state.isQuietCheckInFlight = true
        let visit = state.cancelId
        return .merge(
            .cancel(id: state.autoRetryCancelId),
            .run { send in
                do {
                    let status = try await giftCard.check(handle)
                    await send(.response(visit, .recheckLoaded(status)))
                } catch is CancellationError {
                    return
                } catch let error as GiftCardClientError {
                    await send(.response(visit, .recheckFailed(error)))
                } catch {
                    await send(.response(visit, .recheckFailed(.checkFailed)))
                }
            }
            .cancellable(id: visit)
        )
    }

    /// Parses the link and, if it is a card for this wallet's network, opens it and resolves the
    /// destination address in parallel.
    private func start(_ state: inout State) -> Effect<Action> {
        let summary: GiftCardSummary
        do {
            summary = try giftCard.parse(state.link.data)
        } catch let error as GiftCardClientError {
            state.step = step(for: error)
            return .none
        } catch {
            state.step = .invalidLink
            return .none
        }

        guard summary.networkType == zcashSDKEnvironment.network().networkType else {
            state.summary = summary
            state.step = .wrongNetwork
            return .none
        }

        state.summary = summary
        state.step = .checking
        let link = state.link
        let visit = state.cancelId
        let accountId = state.selectedWalletAccount?.id
        return .merge(
            .run { send in
                do {
                    let handle = try await giftCard.open(link.data)
                    guard !Task.isCancelled else {
                        await giftCard.cleanup(handle)
                        return
                    }
                    await send(.response(visit, .opened(handle)))
                    // Cancellation may race with delivery and suppress the queued response.
                    if Task.isCancelled { await giftCard.cleanup(handle) }
                } catch is CancellationError {
                    return
                } catch let error as GiftCardClientError {
                    await send(.response(visit, .openFailed(error)))
                } catch {
                    await send(.response(visit, .openFailed(.checkFailed)))
                }
            }
            .cancellable(id: state.cancelId),
            .run { send in
                guard let accountId else {
                    return
                }
                let address = try? await sdkSynchronizer.getCustomUnifiedAddress(accountId, [.orchard])
                guard !Task.isCancelled else { return }
                await send(.response(visit, .destinationResolved(accountId, address?.stringEncoded.redacted)))
            }
            .cancellable(id: state.cancelId)
        )
    }

    /// Syncs the card and reports its status, streaming sync progress meanwhile.
    private func check(_ handle: GiftCardHandle, state: State) -> Effect<Action> {
        let visit = state.cancelId
        return .merge(
            .run { send in
                for await progress in giftCard.progress(handle) {
                    await send(.response(visit, .progressUpdated(progress)))
                }
            },
            .run { send in
                do {
                    let status = try await giftCard.check(handle)
                    await send(.response(visit, .statusLoaded(status)))
                } catch is CancellationError {
                    return
                } catch let error as GiftCardClientError {
                    await send(.response(visit, .checkFailed(error)))
                } catch {
                    await send(.response(visit, .checkFailed(.checkFailed)))
                }
            }
        )
        .cancellable(id: state.cancelId)
    }

    private func resolveRedemptionDestination(_ state: State) -> Effect<Action> {
        let visit = state.cancelId
        guard let accountId = state.selectedWalletAccount?.id else {
            return .send(.response(visit, .redeemFailed(.redeemFailed)))
        }
        if state.destinationAccountId == accountId, let address = state.destinationAddress {
            return .send(.response(visit, .redemptionDestinationResolved(accountId, address)))
        }
        return .run { send in
            let address = try? await sdkSynchronizer.getCustomUnifiedAddress(accountId, [.orchard])
            guard !Task.isCancelled else { return }
            await send(.response(visit, .redemptionDestinationResolved(accountId, address?.stringEncoded.redacted)))
        }
        .cancellable(id: visit)
    }

    private func step(for error: GiftCardClientError) -> State.Step {
        switch error {
        case .notAGiftCardLink, .invalidLink:
            return .invalidLink
        case .unsupportedVersion:
            return .unsupportedVersion
        case .networkMismatch:
            return .wrongNetwork
        case .unavailable:
            return .unavailable
        case .nothingToRedeem:
            return .empty
        case .unknownHandle, .checkFailed, .redeemFailed:
            return .checkFailed
        }
    }
}
