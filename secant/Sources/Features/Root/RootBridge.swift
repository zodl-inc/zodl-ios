//
//  RootBridge.swift
//  Zashi
//
//  Zodl Bridge intake at Root (docs/macos/ZODL_BRIDGE_SPEC.md BR-2..BR-7 +
//  ZODL_BRIDGE_PLAN.md Phase B). One-way by construction: requests flow in from
//  the UDS listener; nothing but a local delivery ack ever leaves the app.
//  Inherits the MOB-1348 rule verbatim: single explicit payment only, fail closed.
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit
import ZcashPaymentURI

extension Root {
    @CasePathable
    enum BridgeAction: Equatable {
        case startListener
        case incoming(BridgePaymentRequest)
        case present(BridgeRequest.State)
        case child(BridgeRequest.Action)
    }

    // swiftlint:disable:next cyclomatic_complexity
    func bridgeReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case .bridge(.startListener):
                #if os(macOS)
                return .run { send in
                    for await request in bridgeServer.start() {
                        await send(.bridge(.incoming(request)))
                    }
                }
                .cancellable(id: state.BridgeListenerCancelId, cancelInFlight: true)
                #else
                return .none
                #endif

            case .bridge(.incoming(let request)):
                // Arrival gates (spec BR-4): silent drops for state/pacing, visible
                // refusal cards for account/content problems the user should see.
                guard
                    state.destinationState.destination == .home,
                    !state.isRestoringWallet,
                    state.bridgeRequestState == nil
                else { return .none }

                let now = Date().timeIntervalSince1970
                guard now - state.lastBridgeRequestAt >= 5 else { return .none }
                state.lastBridgeRequestAt = now

                guard
                    let account = state.selectedWalletAccount,
                    let zip32AccountIndex = account.zip32AccountIndex,
                    account.vendor == .zcash
                else {
                    // Same boundary as Flexa (MOB-1352): a hardware account has no local
                    // seed to sign with — the bridge's Keystone story is the PCZT flow, later.
                    return .send(.bridge(.present(
                        BridgeRequest.State(phase: .refused(message: String(bridge: .bridgeRefusedKeystone)))
                    )))
                }

                let displayOrigin = request.origin == "popup:" ? "" : request.origin
                let network = zcashSDKEnvironment.network().networkType

                return .run { send in
                    // BR-7: a Tier-1 pointer replaces the page bytes entirely or the
                    // request is refused — never a silent downgrade to Tier 2.
                    var uri = request.uri
                    var tier = BridgeRequest.State.Tier.pageEmbedded
                    if let requestSrc = request.requestSrc {
                        switch await bridgeVerifier.verify(requestSrc, request.origin) {
                        case .verified(let fetchedURI, let domain):
                            uri = fetchedURI
                            tier = .verified(domain: domain)
                        case .failed:
                            await send(.bridge(.present(
                                BridgeRequest.State(phase: .refused(message: String(bridge: .bridgeRefusedVerification)), origin: displayOrigin)
                            )))
                            return
                        }
                    }

                    // MOB-1348 mirror: parse, then sign only a single explicit
                    // recipient/amount/memo — never the raw URI, never payments[1...].
                    guard
                        let parsed = uriParser.checkRP(uri, network),
                        case .request(let paymentRequest) = parsed
                    else {
                        await send(.bridge(.present(
                            BridgeRequest.State(phase: .refused(message: String(bridge: .bridgeRefusedInvalid)), tier: tier, origin: displayOrigin)
                        )))
                        return
                    }
                    guard paymentRequest.payments.count == 1, let payment = paymentRequest.payments.first else {
                        await send(.bridge(.present(
                            BridgeRequest.State(phase: .refused(message: String(bridge: .bridgeRefusedMulti)), tier: tier, origin: displayOrigin)
                        )))
                        return
                    }

                    do {
                        var memoText = ""
                        if let memoBytes = payment.memo, let memo = try? Memo(bytes: [UInt8](memoBytes.memoData)) {
                            memoText = memo.toString() ?? ""
                        }
                        let recipient = try Recipient(payment.recipientAddress.value, network: network)
                        let memo: Memo? = memoText.isEmpty ? nil : try Memo(string: memoText)

                        var amount = Zatoshi(0)
                        let numberLocale = numberFormatter.convertUSToLocale(payment.amount?.toString() ?? "0") ?? ""
                        if let number = numberFormatter.number(numberLocale) {
                            amount = Zatoshi(NSDecimalNumber(
                                decimal: number.decimalValue * Decimal(Zatoshi.Constants.oneZecInZatoshi)
                            ).roundedZec.int64Value)
                        }

                        let proposal = try await sdkSynchronizer.proposeTransfer(account.id, recipient, amount, memo)

                        await send(.bridge(.present(
                            BridgeRequest.State(
                                tier: tier,
                                origin: displayOrigin,
                                address: payment.recipientAddress.value,
                                amount: amount,
                                memoText: memoText,
                                feeRequired: proposal.totalFeeRequired(),
                                proposal: proposal,
                                zip32AccountIndex: zip32AccountIndex
                            )
                        )))
                    } catch {
                        await send(.bridge(.present(
                            BridgeRequest.State(
                                phase: .refused(message: String(bridge: .bridgeRefusedProposal(error.localizedDescription))),
                                tier: tier,
                                origin: displayOrigin
                            )
                        )))
                    }
                }

            case .bridge(.present(let bridgeState)):
                state.bridgeRequestState = bridgeState
                return .none

            case .bridge(.child(.cancelTapped)), .bridge(.child(.closeTapped)):
                state.bridgeRequestState = nil
                return .none

            case .bridge:
                return .none

            default:
                return .none
            }
        }
    }
}
