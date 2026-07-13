//
//  BridgeRequestStore.swift
//  Zashi
//
//  Zodl Bridge review + confirm (spec BR-4/BR-6, docs/macos/ZODL_BRIDGE_SPEC.md).
//  The card renders ONLY engine-proposal data (never page-supplied text) and the
//  submission path mirrors the shipped Flexa/SendConfirmation sequence exactly:
//  SE-decrypt-as-biometric → derive spending key → createAndSubmitProposedTransactions,
//  including the "grpcFailure may still settle — don't invite a double payment" rule.
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

@Reducer
struct BridgeRequest {
    @ObservableState
    struct State: Equatable {
        enum Tier: Equatable {
            /// BR-7 Tier 1: the request was natively re-fetched from the merchant's own domain.
            case verified(domain: String)
            /// BR-7 Tier 2: read from page content; labeled unverifiable in the card.
            case pageEmbedded
        }

        enum Phase: Equatable {
            case review
            case sending
            case success(txid: String)
            case failure(message: String)
            /// Gate refusals (Keystone account, invalid/multi-recipient request,
            /// failed origin verification, proposal failure) — visible, not silent.
            case refused(message: String)
        }

        var phase: Phase = .review
        var tier: Tier = .pageEmbedded
        /// Browser-attested page origin; empty = the extension popup's manual paste box.
        var origin = ""
        var address = ""
        var amount = Zatoshi(0)
        var memoText = ""
        var feeRequired = Zatoshi(0)
        var proposal: Proposal?
        var zip32AccountIndex: Zip32AccountIndex?

        init(
            phase: Phase = .review,
            tier: Tier = .pageEmbedded,
            origin: String = "",
            address: String = "",
            amount: Zatoshi = Zatoshi(0),
            memoText: String = "",
            feeRequired: Zatoshi = Zatoshi(0),
            proposal: Proposal? = nil,
            zip32AccountIndex: Zip32AccountIndex? = nil
        ) {
            self.phase = phase
            self.tier = tier
            self.origin = origin
            self.address = address
            self.amount = amount
            self.memoText = memoText
            self.feeRequired = feeRequired
            self.proposal = proposal
            self.zip32AccountIndex = zip32AccountIndex
        }
    }

    enum Action: Equatable {
        case cancelTapped
        case closeTapped
        case payTapped
        case sendDone(String)
        case sendFailed(String)
    }

    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .cancelTapped, .closeTapped:
                // Root clears `bridgeRequestState` (one-in-flight gate re-opens there).
                return .none

            case .payTapped:
                guard case .review = state.phase else { return .none }
                guard let proposal = state.proposal, let zip32AccountIndex = state.zip32AccountIndex else {
                    state.phase = .failure(message: String(bridge: .bridgeRefusedInvalid))
                    return .none
                }
                state.phase = .sending
                return .run { send in
                    do {
                        // macOS: the Secure-Enclave seed decrypt below is itself the biometric
                        // gate (`authenticateForSeedDecrypt` returns true without prompting);
                        // iOS would prompt here — same contract as SendConfirmation/Flexa.
                        guard await localAuthentication.authenticateForSeedDecrypt(for: .sendFunds) else {
                            await send(.sendFailed(String(bridge: .bridgeAuthFailed)))
                            return
                        }
                        let storedWallet = try await walletStorage.exportWallet(AuthenticationContext.sendFunds.localizedReason)
                        let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                        let network = zcashSDKEnvironment.network().networkType
                        let spendingKey = try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, network)

                        let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal, spendingKey)

                        switch result {
                        case .success(let txIds):
                            await send(.sendDone(txIds.last ?? ""))
                        case .grpcFailure(let txIds, _):
                            // Transport failure is not definitive: the SDK keeps rebroadcasting,
                            // so if the txId exists locally the payment may still settle — report
                            // it as sent rather than inviting a double payment (Flexa precedent).
                            if let txId = txIds.last, (try? await sdkSynchronizer.txIdExists(txId)) == true {
                                await send(.sendDone(txId))
                            } else {
                                await send(.sendFailed(String(bridge: .bridgeFailureNetwork)))
                            }
                        case .failure(_, let code, let description):
                            await send(.sendFailed("\(description) (\(code))"))
                        case .partial(let txIds, _):
                            // Multi-tx partial success cannot be represented as paid/unpaid for a
                            // single invoice — surface as failure with the txids for support.
                            await send(.sendFailed(String(bridge: .bridgeFailurePartial(txIds.joined(separator: ", ")))))
                        }
                    } catch {
                        await send(.sendFailed(error.localizedDescription))
                    }
                }

            case .sendDone(let txid):
                state.phase = .success(txid: txid)
                return .none

            case .sendFailed(let message):
                state.phase = .failure(message: message)
                return .none
            }
        }
    }
}
