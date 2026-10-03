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
/// client, never logged. Closing the card's wallet (`GiftCardClient.cleanup`) is owned by
/// `GiftCardCoordFlow`, which is still alive when this screen goes away.
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
            case ready(spendable: Zatoshi)
            case pending(amount: Zatoshi, confirmationsNeeded: Int?)
            /// Already redeemed, or not funded yet.
            case empty
            case invalidLink
            /// A card for a newer link format.
            case unsupportedVersion
            case wrongNetwork
            /// The card's balance could not be determined.
            case checkFailed
            /// This build cannot redeem gift cards yet.
            case unavailable
            case redeeming(amount: Zatoshi)
            case success(amount: Zatoshi)
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
        /// The selected account's Orchard-only unified address, resolved in the background.
        var destinationAddress: RedactableString?
        var txId: String?
        @Shared(.inMemory(.exchangeRate)) var currencyConversion: CurrencyConversion? = nil
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

        var message: String? {
            guard let message = summary?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
                return nil
            }
            return message
        }

        /// The amount the screen is about, whichever step it is on.
        var amount: Zatoshi? {
            switch step {
            case .ready(let amount), .pending(let amount, _), .redeeming(let amount), .success(let amount), .failure(let amount):
                return amount
            case .checking, .empty, .invalidLink, .unsupportedVersion, .wrongNetwork, .checkFailed, .unavailable:
                return nil
            }
        }

        var fiatAmount: String? {
            guard let amount, let currencyConversion else {
                return nil
            }
            let converted: String = currencyConversion.convert(amount)
            return converted
        }

        var isRedeemable: Bool {
            if case .ready(let spendable) = step {
                return spendable.amount > 0 && selectedWalletAccount != nil
            }
            return false
        }

        var canRetry: Bool {
            switch step {
            case .pending, .empty, .checkFailed, .failure:
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
        case autoRetryFired
        case checkFailed(GiftCardClientError)
        case closeTapped
        case delegate(Delegate)
        case destinationResolved(RedactableString?)
        case onAppear
        case opened(GiftCardHandle)
        case openFailed(GiftCardClientError)
        case progressUpdated(Double)
        case redeemFailed(GiftCardClientError)
        case redeemSucceeded(String)
        case redeemTapped
        case retryTapped
        case statusLoaded(GiftCardStatus)

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
            switch action {
            case .onAppear:
                // Only the first appearance starts work; coming back to this screen keeps its state.
                guard state.summary == nil, state.step == .checking else {
                    return .none
                }
                return start(&state)

            case .retryTapped, .autoRetryFired:
                guard state.canRetry else {
                    return .none
                }
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

            case .opened(let handle):
                state.handle = handle
                return check(handle, state: state)

            case .openFailed(let error), .checkFailed(let error):
                state.syncProgress = nil
                state.step = step(for: error)
                return .cancel(id: state.cancelId)

            case .progressUpdated(let progress):
                guard state.step == .checking else {
                    return .none
                }
                state.syncProgress = min(max(progress, 0), 1)
                return .none

            case .statusLoaded(let status):
                state.syncProgress = nil
                switch status {
                case .ready(let spendable):
                    state.step = spendable.amount > 0 ? .ready(spendable: spendable) : .empty
                    return .none
                case let .pending(amount, confirmationsNeeded):
                    state.step = .pending(amount: amount, confirmationsNeeded: confirmationsNeeded)
                    return .run { send in
                        try await mainQueue.sleep(for: .seconds(Constants.autoRetryInterval))
                        await send(.autoRetryFired)
                    }
                    .cancellable(id: state.autoRetryCancelId, cancelInFlight: true)
                case .empty:
                    state.step = .empty
                    return .none
                }

            case .destinationResolved(let address):
                state.destinationAddress = address
                return .none

            case .redeemTapped:
                guard state.isRedeemable, case .ready(let spendable) = state.step, let handle = state.handle else {
                    return .none
                }
                state.step = .redeeming(amount: spendable)
                let knownAddress = state.destinationAddress
                let accountId = state.selectedWalletAccount?.id
                return .run { send in
                    do {
                        var address = knownAddress?.data
                        if address == nil, let accountId {
                            address = try await sdkSynchronizer.getCustomUnifiedAddress(accountId, [.orchard])?.stringEncoded
                        }
                        guard let address else {
                            await send(.redeemFailed(.redeemFailed))
                            return
                        }
                        let txId = try await giftCard.redeem(handle, address)
                        await send(.redeemSucceeded(txId))
                    } catch let error as GiftCardClientError {
                        await send(.redeemFailed(error))
                    } catch {
                        await send(.redeemFailed(.redeemFailed))
                    }
                }
                .cancellable(id: state.cancelId)

            case .redeemSucceeded(let txId):
                guard case .redeeming(let amount) = state.step else {
                    return .none
                }
                state.txId = txId
                state.step = .success(amount: amount)
                return .send(.delegate(.redeemed))

            case .redeemFailed(let error):
                guard case .redeeming(let amount) = state.step else {
                    return .none
                }
                state.step = error == .unavailable ? .unavailable : .failure(amount: amount)
                return .none

            case .closeTapped:
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
        let accountId = state.selectedWalletAccount?.id
        return .merge(
            .run { send in
                do {
                    let handle = try await giftCard.open(link.data)
                    await send(.opened(handle))
                } catch let error as GiftCardClientError {
                    await send(.openFailed(error))
                } catch {
                    await send(.openFailed(.checkFailed))
                }
            }
            .cancellable(id: state.cancelId, cancelInFlight: true),
            .run { send in
                guard let accountId else {
                    return
                }
                let address = try? await sdkSynchronizer.getCustomUnifiedAddress(accountId, [.orchard])
                await send(.destinationResolved(address?.stringEncoded.redacted))
            }
        )
    }

    /// Syncs the card and reports its status, streaming sync progress meanwhile.
    private func check(_ handle: GiftCardHandle, state: State) -> Effect<Action> {
        .merge(
            .run { send in
                for await progress in giftCard.progress(handle) {
                    await send(.progressUpdated(progress))
                }
            },
            .run { send in
                do {
                    let status = try await giftCard.check(handle)
                    await send(.statusLoaded(status))
                } catch let error as GiftCardClientError {
                    await send(.checkFailed(error))
                } catch {
                    await send(.checkFailed(.checkFailed))
                }
            }
        )
        .cancellable(id: state.cancelId, cancelInFlight: true)
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
        case .unknownHandle, .checkFailed, .redeemFailed:
            return .checkFailed
        }
    }
}
