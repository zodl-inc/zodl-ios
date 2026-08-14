//
//  RootDestination.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.12.2022.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

import SwiftUI

/// In this file is a collection of helpers that control all state and action related operations
/// for the `Root` with a connection to the UI navigation.
extension Root {
    struct DestinationState {
        enum Destination {
            case deeplinkWarning
            case ironwoodAnnouncement
            case notEnoughFreeSpace
            case onboarding
            case osStatusError
            case home
            case welcome
        }
        
        var internalDestination: Destination = .welcome
        var preNotEnoughFreeSpaceDestination: Destination?
        var previousDestination: Destination?

        var destination: Destination {
            get { internalDestination }
            set {
                previousDestination = internalDestination
                internalDestination = newValue
            }
        }
    }
    
    enum DestinationAction {
        case deeplink(URL)
        case deeplinkHome
        case deeplinkSend(Zatoshi, String, String)
        case deeplinkFailed(URL, ZcashError)
        case updateDestination(Root.DestinationState.Destination)
        case serverSwitch
    }

    // swiftlint:disable:next cyclomatic_complexity
    func destinationReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case let .destination(.updateDestination(destination)):
                guard (state.destinationState.destination != .deeplinkWarning)
                        || (state.destinationState.destination == .deeplinkWarning && destination == .home) else {
                    return .none
                }
                state.destinationState.destination = destination

                // See `presentStaleWalletHealedAlertEffect` (RootStore.swift) for why this is
                // deferred and shared with the `.phraseDisplay(.finishedTapped)` /
                // `.onboarding(.newWalletSuccessfulyCreated)` transition in RootInitialization.swift.
                if destination == .home && state.isStaleWalletHealedAlertPending {
                    return presentStaleWalletHealedAlertEffect(cancelId: state.staleWalletHealedAlertCancelId)
                }

                return .none

            case .destination(.deeplink(let url)):
                if let _ = uriParser.checkRP(url.absoluteString, zcashSDKEnvironment.network().networkType) {
                    // The deeplink is some zip321, we ignore it and let users know in a warning screen
                    return .send(.destination(.updateDestination(.deeplinkWarning)))
                }
                return .none

            case .destination(.deeplinkHome):
                return .none

            case .destination(.deeplinkSend):
                return .none

            case let .destination(.deeplinkFailed(url, error)):
                state.alert = AlertState.failedToProcessDeeplink(url, error)
                return .none

            case .destination(.serverSwitch):
                // Mirror the smart-banner entry (RootCoordinator .serverSwitchRequested): reset the
                // long-lived serverSetupState so each open re-benchmarks instead of showing a stale
                // "Fastest servers" ranking and reusing a stale recommendedSyncServer on an Automatic Save.
                state.serverSetupState = .initial
#if os(macOS)
                // macOS: present full-window via the path (MacSplitView `.serverSwitch?`), exactly like
                // the smart-banner entry above. The serverSetupViewBinding → zashiFullScreenCover route
                // renders a raw native .sheet on macOS, which is banned for app content (MODALS Rule #5a).
                state.path = .serverSwitch
#else
                state.serverSetupViewBinding = true
#endif
                return .none

            case .splashRemovalRequested:
                return .run { send in
                    try await mainQueue.sleep(for: .seconds(0.01))
                    await send(.splashFinished)
                }
            
            case .splashFinished:
                state.splashAppeared = true
                state.$lastAuthenticationTimestamp.withLock { $0 = Int(Date().timeIntervalSince1970) }
                return .none

            case .flexaOnTransactionRequest(let transaction):
                guard let transaction else {
                    return .none
                }
                guard let account = state.selectedWalletAccount, let zip32AccountIndex = account.zip32AccountIndex else {
                    return .none
                }
                flexaHandler.clearTransactionRequest()
                // SECURITY (MOB-1352): Flexa signs with a LOCAL spending key derived from the device
                // seed, which only exists for Zodl (local-seed) accounts. A Keystone (hardware) account
                // has no local seed, so this path must never run for it — block and prompt the user to
                // switch to a Zodl account rather than signing with the wrong key.
                guard account.vendor == .zcash else {
                    return .send(.flexaTransactionFailed(String(localizable: .partnersFlexaKeystoneNotSupportedMessage)))
                }
                return .run { send in
                    do {
                        // macOS: the SE seed decrypt below is the single biometric gate
                        // (see `authenticateForSeedDecrypt`); iOS prompts here.
                        if await !localAuthentication.authenticateForSeedDecrypt(for: .sendFunds) {
                            return
                        }

                        // get a proposal
                        let recipient = try Recipient(transaction.address, network: zcashSDKEnvironment.network().networkType)
                        let proposal = try await sdkSynchronizer.proposeTransfer(account.id, recipient, transaction.amount, nil)

                        // make the actual send — defensive backstop: the vendor guard above already
                        // blocks non-Zodl accounts; re-assert before touching the seed so a future
                        // refactor can't reintroduce signing a Keystone payment with the local seed.
                        guard account.vendor == .zcash else {
                            assertionFailure("Flexa reached spending-key derivation for a non-Zodl account")
                            return
                        }
                        let storedWallet = try await walletStorage.exportWallet(AuthenticationContext.sendFunds.localizedReason)
                        let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                        let network = zcashSDKEnvironment.network().networkType
                        let spendingKey = try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, network)

                        let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal, spendingKey)

                        switch result {
                        case .failure, .partial:
                            // Flexa is binary: a commerce session is either paid (reported via
                            // `transactionSent`) or it isn't. `.failure` is a definitive rejection and
                            // `.partial` an incomplete payment, so both map to a failure alert — and
                            // neither runs the `txIdExists` "may still settle, report as sent" path below,
                            // on purpose: that recovery only makes sense when a single txId unambiguously
                            // represents the whole payment (success / grpcFailure).
                            await send(.flexaTransactionFailed(String(localizable: .partnersFlexaTransactionFailedMessage)))
                        case .grpcFailure(let txIds, _):
                            // Transport-level failure is not definitive: the SDK recorded a retry
                            // plan before any network attempt and keeps rebroadcasting until the
                            // transaction mines or expires, so it may still settle. Report it as
                            // sent so Flexa tracks the txId instead of prompting the user to pay
                            // again — a "failed" alert here risks a double payment.
                            if let txId = txIds.last, try await sdkSynchronizer.txIdExists(txId) {
                                flexaHandler.transactionSent(transaction.commerceSessionId, txId)
                            } else {
                                await send(.flexaTransactionFailed(String(localizable: .partnersFlexaTransactionFailedMessage)))
                            }
                        case .success(let txIds):
                            if let txId = txIds.last, try await sdkSynchronizer.txIdExists(txId) {
                                flexaHandler.transactionSent(transaction.commerceSessionId, txId)
                            } else {
                                await send(.flexaTransactionFailed(String(localizable: .partnersFlexaTransactionFailedMessage)))
                            }
                        }
                    } catch {
                        await send(.flexaTransactionFailed(error.localizedDescription))
                    }
                }
                
            case .flexaTransactionFailed(let message):
                flexaHandler.flexaAlert(String(localizable: .partnersFlexaTransactionFailedTitle), message)
                return .none

            default:
                return .none
            }
        }
    }
}

private extension Root {
    func process(
        url: URL,
        deeplink: DeeplinkClient,
        derivationTool: DerivationToolClient
    ) async throws -> Root.Action {
        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
        let deeplink = try deeplink.resolveDeeplinkURL(url, zcashSDKEnvironment.network().networkType, derivationTool)
        
        switch deeplink {
        case .home:
            return .destination(.deeplinkHome)
        case let .send(amount, address, memo):
            return .destination(.deeplinkSend(Zatoshi(Int64(amount)), address, memo))
        }
    }
}

extension StoreOf<Root> {
    func goToDestination(_ destination: Root.DestinationState.Destination) {
        send(.destination(.updateDestination(destination)))
    }
    
    func goToDeeplink(_ deeplink: URL) {
        send(.destination(.deeplink(deeplink)))
    }
}

// MARK: Placeholders

extension Root.DestinationState {
    static var initial: Self {
        .init()
    }
}
