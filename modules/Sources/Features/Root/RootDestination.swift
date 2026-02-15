//
//  RootDestination.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.12.2022.
//

import Foundation
import ComposableArchitecture
import ZcashLightClientKit
import Deeplink
import DerivationTool
import Generated

import SwiftUI

/// In this file is a collection of helpers that control all state and action related operations
/// for the `Root` with a connection to the UI navigation.
extension Root {
    public struct DestinationState {
        public enum Destination {
            case deeplinkWarning
            case notEnoughFreeSpace
            case onboarding
            case osStatusError
            //case phraseDisplay
            case startup
            case home
            case welcome
            case zodlAnnouncement
        }
        
        public var internalDestination: Destination = .welcome
        public var preNotEnoughFreeSpaceDestination: Destination?
        public var previousDestination: Destination?

        public var destination: Destination {
            get { internalDestination }
            set {
                previousDestination = internalDestination
                internalDestination = newValue
            }
        }
    }
    
    public enum DestinationAction {
        case deeplink(URL)
        case deeplinkHome
        case deeplinkSend(Zatoshi, String, String)
        case deeplinkFailed(URL, ZcashError)
        case updateDestination(Root.DestinationState.Destination)
        case serverSwitch
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func destinationReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
            case let .destination(.updateDestination(destination)):
                guard (state.destinationState.destination != .deeplinkWarning)
                        || (state.destinationState.destination == .deeplinkWarning && destination == .home) else {
                    return .none
                }
                state.destinationState.destination = destination
                return .none

            case .destination(.deeplink(let url)):
                if let _ = uriParser.checkRP(url.absoluteString, zcashSDKEnvironment.network.networkType) {
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
                state.serverSetupViewBinding = true
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
                return .run { send in
                    do {
                        if await !localAuthentication.authenticate() {
                            return
                        }

                        // get a proposal
                        let recipient = try Recipient(transaction.address, network: zcashSDKEnvironment.network.networkType)
                        let proposal = try await sdkSynchronizer.proposeTransfer(account.id, recipient, transaction.amount, nil)

                        // make the actual send
                        let storedWallet = try walletStorage.exportWallet()
                        let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                        let network = zcashSDKEnvironment.network.networkType
                        let spendingKey = try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, network)
                        
                        let result = try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)
                        
                        switch result {
                        case .partial:
                            await send(.flexaTransactionFailed(L10n.Partners.Flexa.transactionFailedMessage))
                        case .success(let txIds), .grpcFailure(let txIds), .failure(let txIds, _, _):
                            if let txId = txIds.last, try await sdkSynchronizer.txIdExists(txId) {
                                flexaHandler.transactionSent(transaction.commerceSessionId, txId)
                            }
                        }
                    } catch {
                        await send(.flexaTransactionFailed(error.localizedDescription))
                    }
                }
                
            case .flexaTransactionFailed(let message):
                flexaHandler.flexaAlert(L10n.Partners.Flexa.transactionFailedTitle, message)
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
        let deeplink = try deeplink.resolveDeeplinkURL(url, zcashSDKEnvironment.network.networkType, derivationTool)
        
        switch deeplink {
        case .home:
            return .destination(.deeplinkHome)
        case let .send(amount, address, memo):
            return .destination(.deeplinkSend(Zatoshi(Int64(amount)), address, memo))
        }
    }
}

extension StoreOf<Root> {
    public func goToDestination(_ destination: Root.DestinationState.Destination) {
        send(.destination(.updateDestination(destination)))
    }
    
    public func goToDeeplink(_ deeplink: URL) {
        send(.destination(.deeplink(deeplink)))
    }
}

// MARK: Placeholders

extension Root.DestinationState {
    public static var initial: Self {
        .init()
    }
}
