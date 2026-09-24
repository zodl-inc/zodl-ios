//
//  SwapAndPayCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-14.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension SwapAndPayCoordFlow {
    func coordinatorReduce() -> Reduce< SwapAndPayCoordFlow.State,  SwapAndPayCoordFlow.Action> {
        Reduce { state, action in
            switch action {

                // MARK: - Address Book

            case let .path(.element(id: _, action: .addressBook(.editId(_, id)))):
                let _ = state.path.popLast()
                audioServices.systemSoundVibrate()
                return .send(.swapAndPay(.addressBookContactSelected(id)))

            case .path(.element(id: _, action: .addressBook(.addManualButtonTapped))):
                var addressBookState = AddressBook.State.initial
                addressBookState.isAddressFocused = true
                addressBookState.context = .swap
                state.path.append(.addressBookContact(addressBookState))
                return .none

            case .path(.element(id: _, action: .addressBook(.scanButtonTapped))):
                var scanState = Scan.State.initial
                scanState.checkers = [.swapStringScanChecker]
                state.path.append(.scan(scanState))
                return .none

                // MARK: - Address Book Contact

            case .path(.element(id: _, action: .addressBookContact(.dismissAddContactRequired))):
                for element in state.path {
                    if element.is(\.scan) {
                        let _ = state.path.popLast()
                        break
                    }
                }
                let _ = state.path.popLast()
                if state.path.ids.isEmpty {
                    return .send(.swapAndPay(.checkSelectedContact))
                } else if let last = state.path.ids.last {
                    return .send(.path(.element(id: last, action: .swapAndPayForm(.checkSelectedContact))))
                }
                return .none

                // MARK: - CrossPay
                
            case .swapAndPay(.crossPayConfirmationRequired):
                state.path.append(.crossPayConfirmation(state.swapAndPayState))
                return .none
                
            case .path(.element(id: _, action: .crossPayConfirmation(.backFromConfirmationTapped))):
                let _ = state.path.popLast()
                return .send(.swapAndPay(.backFromConfirmationTapped))

                // MARK: - Keystone
                
            case .swapAndPay(.confirmWithKeystoneTapped),
                    .path(.element(id: _, action: .crossPayConfirmation(.confirmWithKeystoneTapped))):
                var sendConfirmationState = SendConfirmation.State.initial
                sendConfirmationState.proposal = state.swapAndPayState.proposal
                sendConfirmationState.type = state.swapAndPayState.isSwapExperienceEnabled ? .swap : .pay
                state.path.append(.confirmWithKeystone(sendConfirmationState))
                if let last = state.path.ids.last {
                    return .send(.path(.element(id: last, action: .confirmWithKeystone(.resolvePCZT))))
                }
                return .none

                // MARK: - Ledger

            // MOB-2020: fires from the quote sheet in `SwapForm` or `CrossPayForm`, which
            // `SwapAndPay` closes on this same action (`isQuotePresented = false`) -- iOS cannot
            // present the Ledger sheet while that sheet is still animating out, so this only
            // stages the state and waits for `.swapAndPay(.quoteSheetDismissed)` below.
            case .swapAndPay(.confirmWithLedgerTapped):
                state.ledgerConfirmationState = .initial
                state.ledgerConfirmationState.proposal = state.swapAndPayState.proposal
                state.ledgerConfirmationState.type = state.swapAndPayState.isSwapExperienceEnabled ? .swap : .pay
                state.isLedgerConfirmationAwaitingQuoteDismissal = true
                return .none

            case .swapAndPay(.quoteSheetDismissed):
                guard state.isLedgerConfirmationAwaitingQuoteDismissal else {
                    return .none
                }
                state.isLedgerConfirmationAwaitingQuoteDismissal = false
                return .send(.ledgerConfirmation(.confirmWithLedgerTapped))

            // MOB-2020: fires from a pushed screen with no sheet up, so the Ledger sheet can
            // present immediately -- no quote-dismissal wait needed.
            case .path(.element(id: _, action: .crossPayConfirmation(.confirmWithLedgerTapped))):
                state.ledgerConfirmationState = .initial
                state.ledgerConfirmationState.proposal = state.swapAndPayState.proposal
                state.ledgerConfirmationState.type = state.swapAndPayState.isSwapExperienceEnabled ? .swap : .pay
                return .send(.ledgerConfirmation(.confirmWithLedgerTapped))

            case .path(.element(id: _, action: .confirmWithKeystone(.getSignatureTapped))):
                var scanState = Scan.State.initial
                scanState.checkers = [.keystonePCZTScanChecker]
                state.path.append(.scan(scanState))
                return .none

            case .path(.element(id: _, action: .scan(.foundPCZT(let pcztWithSigs)))):
                for (id, element) in zip(state.path.ids, state.path) {
                    if case .confirmWithKeystone(let sendConfirmationState) = element {
                        state.path.append(.sending(sendConfirmationState))
                        return .send(.path(.element(id: id, action: .confirmWithKeystone(.foundPCZT(pcztWithSigs)))))
                    }
                }
                return .none

            // MOB-2020: the Ledger twin of both `.scan(.foundPCZT)` (push `.sending`) and
            // `.confirmWithKeystone(.keystoneFirmwareAccepted)` (the swap-metadata write) above,
            // collapsed into one arm -- a Ledger signature has no firmware gate splitting those
            // two moments apart, and `ledgerConfirmationState` is a scoped child (not a path
            // element), so by the time this runs it already holds the signed PCZT and has started
            // the submit.
            case .ledgerConfirmation(.ledgerSigning(.signed)):
                let depositAddress = state.swapAndPayState.quote?.depositAddress ?? state.swapAndPayState.address
                let crosspay = state.swapAndPayState.isSwapExperienceEnabled

                if let provider = state.swapAndPayState.selectedAsset?.provider {
                    let totalFees = state.swapAndPayState.totalFees
                    let totalUSDFees = state.swapAndPayState.totalUSDFees
                    userMetadataProvider.markTransactionAsSwapFor(
                        depositAddress,
                        provider,
                        totalFees,
                        totalUSDFees,
                        state.swapAndPayState.zecAsset?.id ?? "",
                        state.swapAndPayState.selectedAsset?.id ?? "",
                        !crosspay,
                        SwapConstants.pendingDeposit,
                        state.swapAndPayState.zecToBeSpendInQuoteUSFormat
                    )
                    if let account = state.selectedWalletAccount?.account {
                        try? userMetadataProvider.store(account)
                    }
                }

                state.path.append(.sending(state.ledgerConfirmationState))
                return .none

            case .path(.element(id: _, action: .confirmWithKeystone(.updateResult(let result)))):
                for (_, element) in zip(state.path.ids, state.path) {
                    if case .confirmWithKeystone(let sendConfirmationState) = element {
                        return .run { send in
                            await send(.updateTxIdToExpand(sendConfirmationState.txIdToExpand))
                            await send(
                                .updateFailedData(
                                    sendConfirmationState.failedCode,
                                    sendConfirmationState.failedDescription ?? "",
                                    sendConfirmationState.failedPcztMsg
                                )
                            )
                            await send(.updatePartialFailureData(
                                sendConfirmationState.partialFailureTxIds,
                                sendConfirmationState.partialFailureStatuses
                            ))
                            await send(.updatePendingDescription(sendConfirmationState.pendingDescription))

                            switch result {
                            case .success:
                                await send(.updateResult(.success))
                            case .pending:
                                await send(.updateResult(.pending))
                            case .failure:
                                await send(.updateResult(.failure))
                            default: return
                            }
                        }
                    }
                }
                return .none

            case .ledgerConfirmation(.updateResult(let result)):
                let sendConfirmationState = state.ledgerConfirmationState
                return .run { send in
                    await send(.updateTxIdToExpand(sendConfirmationState.txIdToExpand))
                    await send(
                        .updateFailedData(
                            sendConfirmationState.failedCode,
                            sendConfirmationState.failedDescription ?? "",
                            sendConfirmationState.failedPcztMsg
                        )
                    )
                    await send(.updatePartialFailureData(
                        sendConfirmationState.partialFailureTxIds,
                        sendConfirmationState.partialFailureStatuses
                    ))
                    await send(.updatePendingDescription(sendConfirmationState.pendingDescription))

                    switch result {
                    case .success:
                        await send(.updateResult(.success))
                    case .pending:
                        await send(.updateResult(.pending))
                    case .failure:
                        await send(.updateResult(.failure))
                    default: return
                    }
                }

            case .path(.element(id: _, action: .confirmWithKeystone(.pcztSendFailed(let error)))):
                for element in state.path.reversed() {
                    if element.is(\.sending) {
                        for (id, element2) in zip(state.path.ids, state.path) {
                            if element2.is(\.confirmWithKeystone) {
                                return .send(.path(.element(id: id, action: .confirmWithKeystone(.sendFailed(error?.toZcashError(), true)))))
                            }
                        }
                        break
                    } else if element.is(\.scan) || element.is(\.confirmWithKeystone) {
                        for element2 in state.path {
                            if case .confirmWithKeystone(let sendConfirmationState) = element2 {
                                state.path.append(.preSendingFailure(sendConfirmationState))
                            }
                        }
                        break
                    }
                }
                return .none

            case .ledgerConfirmation(.pcztSendFailed(let error)):
                if state.path.contains(where: { $0.is(\.sending) }) {
                    return .send(.ledgerConfirmation(.sendFailed(error?.toZcashError(), true)))
                }
                state.path.append(.preSendingFailure(state.ledgerConfirmationState))
                return .none

            // MOB-1510: pop to `confirmWithKeystone` first so this only ever applies once (`break`)
            // and drops the stale `.scan`/`.sending` pushed underneath before the append.
            case .path(.element(id: _, action: .confirmWithKeystone(.keystoneFirmwareUpdateRequired))):
                for (id, element) in zip(state.path.ids, state.path) {
                    if case .confirmWithKeystone(let sendConfirmationState) = element {
                        state.path.pop(to: id)
                        state.path.append(.keystoneFirmwareUpdate(sendConfirmationState))
                        break
                    }
                }
                return .none

            // MOB-1510: deferred until the firmware gate accepts — writing this any earlier (from
            // `.scan(.foundPCZT)`) would record a swap for a transaction the gate is about to
            // block, and `UserMetadataProviderInterface` has no unmark/remove API to undo that.
            case .path(.element(id: _, action: .confirmWithKeystone(.keystoneFirmwareAccepted))):
                let depositAddress = state.swapAndPayState.quote?.depositAddress ?? state.swapAndPayState.address
                let crosspay = state.swapAndPayState.isSwapExperienceEnabled

                if let provider = state.swapAndPayState.selectedAsset?.provider {
                    let totalFees = state.swapAndPayState.totalFees
                    let totalUSDFees = state.swapAndPayState.totalUSDFees
                    userMetadataProvider.markTransactionAsSwapFor(
                        depositAddress,
                        provider,
                        totalFees,
                        totalUSDFees,
                        state.swapAndPayState.zecAsset?.id ?? "",
                        state.swapAndPayState.selectedAsset?.id ?? "",
                        !crosspay,
                        SwapConstants.pendingDeposit,
                        state.swapAndPayState.zecToBeSpendInQuoteUSFormat
                    )
                    if let account = state.selectedWalletAccount?.account {
                        try? userMetadataProvider.store(account)
                    }
                }
                return .none

            // Reset `confirmWithKeystone` here (not in its own reducer) so a fresh scan after a
            // firmware update isn't silently dropped by the `isKeystoneCodeFound` guard in `foundPCZT`.
            case .path(.element(id: _, action: .keystoneFirmwareUpdate(.keystoneFirmwareUpdateCloseTapped))):
                for (id, element) in zip(state.path.ids, state.path) {
                    if element.is(\.confirmWithKeystone) {
                        state.path.pop(to: id)
                        state.path[id: id, case: \.confirmWithKeystone]?.detectedKeystoneFirmware = nil
                        state.path[id: id, case: \.confirmWithKeystone]?.isKeystoneCodeFound = false
                        break
                    }
                }
                keystoneHandler.resetQRDecoder()
                return .none

                // MARK: - Scan
                
            case .path(.element(id: _, action: .scan(.foundString(let address)))):
                // handle direct scan from the form
                if state.path.count == 1 {
                    let _ = state.path.removeLast()
                    audioServices.systemSoundVibrate()
                    state.swapAndPayState.address = address
                } else {
                    // handle scan inside add a new contact flow
                    audioServices.systemSoundVibrate()
                    var addressBookState = AddressBook.State.initial
                    addressBookState.address = address
                    addressBookState.isNameFocused = true
                    addressBookState.context = .swap
                    state.path.append(.addressBookContact(addressBookState))
                }
                return .none

            case .path(.element(id: _, action: .scan(.cancelTapped))):
                let _ = state.path.popLast()
                return .none
                
                // MARK: - Send Confirmation
                
            case .path(.element(id: _, action: .sending(.sendingScreenOnAppear))):
                state.sendingScreenOnAppearTimestamp = Date().timeIntervalSince1970
                return .none

            case .path(.element(id: _, action: .sendResultSuccess(.checkStatusTapped))),
                    .path(.element(id: _, action: .sendResultFailure(.checkStatusTapped))),
                    .path(.element(id: _, action: .sendResultPending(.checkStatusTapped))):
                if let txid = state.txIdToExpand {
                    if let index = state.transactions.index(id: txid) {
                        var transactionDetailsState = TransactionDetails.State.initial
                        transactionDetailsState.transaction = state.transactions[index]
                        transactionDetailsState.isCloseButtonRequired = true
                        state.path.append(.transactionDetails(transactionDetailsState))
                    }
                }
                return .none

                // MARK: - Self

            case .storeLastUsedAsset:
                guard state.swapAndPayState.isSwapToZecExperienceEnabled else {
                    return .none
                }
                guard let selectedAsset = state.swapAndPayState.selectedAsset else {
                    return .none
                }
                userMetadataProvider.addLastUsedSwapAsset(selectedAsset.id)
                if let account = state.selectedWalletAccount?.account {
                    try? userMetadataProvider.store(account)
                }
                return .none
                
            case .swapAndPay(.enableSwapExperience):
                state.isSwapExperience.toggle()
                return .none
                
            case .swapAndPay(.enableSwapToZecExperience):
                state.isSwapToZecExperience.toggle()
                return .none

            case let .updateFailedData(code, desc, pcztMsg):
                state.failedCode = code
                state.failedDescription = desc
                #if DEBUG
                state.failedPcztMsg = pcztMsg
                #endif
                return .none

            case let .updatePartialFailureData(txIds, statuses):
                state.partialFailureTxIds = txIds
                state.partialFailureStatuses = statuses
                return .none

            case let .updatePendingDescription(description):
                state.pendingDescription = description
                return .none

            case .swapAndPay(.addressBookTapped),
                    .path(.element(id: _, action: .swapAndPayForm(.addressBookTapped))):
                var addressBookState = AddressBook.State.initial
                addressBookState.context = .swap
                addressBookState.isInSelectMode = true
                state.path.append(.addressBook(addressBookState))
                return .none

            case .swapAndPay(.notInAddressBookButtonTapped(let address)),
                    .path(.element(id: _, action: .swapAndPayForm(.notInAddressBookButtonTapped(let address)))):
                var addressBookState = AddressBook.State.initial
                addressBookState.context = .swap
                addressBookState.address = address
                addressBookState.isNameFocused = true
                state.path.append(.addressBookContact(addressBookState))
                return .none

            case .backButtonTapped:
                return .send(.swapAndPay(.backButtonTapped(state.isSwapInFlight)))
                
            case .swapAndPay(.scanTapped),
                    .path(.element(id: _, action: .swapAndPayForm(.scanTapped))):
                var scanState = Scan.State.initial
                scanState.checkers = [.swapStringScanChecker]
                state.path.append(.scan(scanState))
                return .none

            case .swapAndPay(.confirmToZecButtonTapped):
                state.path.append(.swapToZecSummary(state.swapAndPayState))
                return .none

            case .swapAndPay(.confirmButtonTapped),
                    .path(.element(id: _, action: .crossPayConfirmation(.confirmButtonTapped))),
                    .path(.element(id: _, action: .swapAndPayForm(.confirmButtonTapped))):
                return .run { send in
                    guard await localAuthentication.authenticate() else {
                        await send(.stopSending)
                        return
                    }
                    
                    await send(.swapRequested)
                }

            case .swapRequested:
                guard let proposal = state.swapAndPayState.proposal else {
                    // `false`: nothing was created or submitted, so there is no transaction in the
                    // wallet the pending screen could be waiting for (matches SendConfirmation).
                    return .send(.sendFailed("missing proposal".toZcashError(), false))
                }
                // MOB-2020: defense in depth — a Ledger account has no ZIP 32 index, so the guard
                // below already bails, but this makes the rule explicit: software signing derives
                // a spending key from the wallet's seed, a path a Ledger account never has.
                guard state.selectedWalletAccount?.vendor == .zcash else {
                    return .send(.sendFailed("software signing is only available for the Zodl account".toZcashError(), false))
                }
                guard let zip32AccountIndex = state.selectedWalletAccount?.zip32AccountIndex else {
                    return .none
                }
                
                // present sending screen
                state.failedCode = nil
                state.failedDescription = ""
                state.failedPcztMsg = nil
                state.partialFailureTxIds = []
                state.partialFailureStatuses = []
                state.pendingDescription = nil
                state.txIdToExpand = nil
                var sendConfirmationState = SendConfirmation.State.initial
                sendConfirmationState.address = state.swapAndPayState.quote?.depositAddress ?? state.swapAndPayState.address
                sendConfirmationState.proposal = state.swapAndPayState.proposal
                sendConfirmationState.type = state.swapAndPayState.isSwapExperienceEnabled ? .swap : .pay
                state.path.append(.sending(sendConfirmationState))

                if let provider = state.swapAndPayState.selectedAsset?.provider {
                    let totalFees = state.swapAndPayState.totalFees
                    let totalUSDFees = state.swapAndPayState.totalUSDFees
                    userMetadataProvider.markTransactionAsSwapFor(
                        sendConfirmationState.address,
                        provider,
                        totalFees,
                        totalUSDFees,
                        state.swapAndPayState.zecAsset?.id ?? "",
                        state.swapAndPayState.selectedAsset?.id ?? "",
                        sendConfirmationState.type == .swap,
                        SwapConstants.pendingDeposit,
                        state.swapAndPayState.zecToBeSpendInQuoteUSFormat
                    )
                    if let account = state.selectedWalletAccount?.account {
                        try? userMetadataProvider.store(account)
                    }
                }

                // make the transaction
                let depositAddress = state.swapAndPayState.quote?.depositAddress
                return .run { send in
                    do {
                        let storedWallet = try walletStorage.exportWallet()
                        let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                        let network = zcashSDKEnvironment.network().networkType
                        let spendingKey = try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, network)

                        let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal, spendingKey)

                        switch result {
                        case let .grpcFailure(txIds, reason):
                            let pendingDescription: String?
                            switch reason {
                            case .timeout: pendingDescription = String(localizable: .sendPendingTimeoutInfo)
                            case .guardBusy: pendingDescription = String(localizable: .sendPendingGuardBusyInfo)
                            case nil: pendingDescription = nil
                            }
                            await send(.updatePendingDescription(pendingDescription))
                            await send(.updateTxIdToExpand(txIds.last))
                            let isTxIdPresentInTheDB = try await sdkSynchronizer.txIdExists(txIds.last)
                            await send(.sendFailed("sdkSynchronizer.createAndSubmitProposedTransactions-grpcFailure".toZcashError(), isTxIdPresentInTheDB))
                        case let .failure(txIds, code, description):
                            await send(.updateFailedData(code, description, ""))
                            await send(.updateTxIdToExpand(txIds.last))
                            let isTxIdPresentInTheDB = try await sdkSynchronizer.txIdExists(txIds.last)
                            await send(.sendFailed("sdkSynchronizer.createAndSubmitProposedTransactions-failure \(code) \(description)".toZcashError(), isTxIdPresentInTheDB))
                        case let .partial(txIds: txIds, statuses: statuses):
                            await send(.updateTxIdToExpand(txIds.first))
                            await send(.sendPartial(txIds, statuses))
                        case .success(let txIds):
                            await send(.updateTxIdToExpand(txIds.last))
                            await send(.sendDone)
                            if let txId = txIds.last, let depositAddress {
                                // inform service to speed up the transaction processing
                                try? await swapAndPay.submitDepositTxId(txId, depositAddress)
                            }
                        }
                    } catch {
                        await send(.sendFailed(error.toZcashError(), false))
                    }
                }

            case .sendDone:
                let diffTime = Date().timeIntervalSince1970 - state.sendingScreenOnAppearTimestamp
                let waitTimeToPresentScreen = diffTime > 2.0 ? 0.01 : 2.0 - diffTime
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(waitTimeToPresentScreen))
                    await send(.updateResult(.success))
                }
                
            case let .sendFailed(error, isTxIdPresentInTheDB):
                state.failedDescription = error?.localizedDescription ?? ""
                let diffTime = Date().timeIntervalSince1970 - state.sendingScreenOnAppearTimestamp
                let waitTimeToPresentScreen = diffTime > 2.0 ? 0.01 : 2.0 - diffTime
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(waitTimeToPresentScreen))
                    await send(.updateResult(isTxIdPresentInTheDB ? .pending : .failure))
                }

            case let .sendPartial(txIds, statuses):
                state.failedCode = -999
                state.failedDescription = statuses.joined(separator: ", ")
                state.partialFailureTxIds = txIds
                state.partialFailureStatuses = statuses
                let diffTime = Date().timeIntervalSince1970 - state.sendingScreenOnAppearTimestamp
                let waitTimeToPresentScreen = diffTime > 2.0 ? 0.01 : 2.0 - diffTime
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(waitTimeToPresentScreen))
                    await send(.updateResult(.failure))
                }

            case let .updateResult(result):
                var sendConfirmationState = SendConfirmation.State.initial
                sendConfirmationState.address = state.swapAndPayState.quote?.depositAddress ?? state.swapAndPayState.address
                sendConfirmationState.proposal = state.swapAndPayState.proposal
                sendConfirmationState.type = state.swapAndPayState.isSwapExperienceEnabled ? .swap : .pay
                sendConfirmationState.failedCode = state.failedCode
                sendConfirmationState.failedDescription = state.failedDescription
                sendConfirmationState.failedPcztMsg = state.failedPcztMsg
                sendConfirmationState.partialFailureTxIds = state.partialFailureTxIds
                sendConfirmationState.partialFailureStatuses = state.partialFailureStatuses
                sendConfirmationState.pendingDescription = state.pendingDescription
                sendConfirmationState.txIdToExpand = state.txIdToExpand
                switch result {
                case .failure:
                    state.path.append(.sendResultFailure(sendConfirmationState))
                case .pending:
                    state.path.append(.sendResultPending(sendConfirmationState))
                case .success:
                    state.path.append(.sendResultSuccess(sendConfirmationState))
                default: break
                }
                return .send(.storeLastUsedAsset)

            // MARK: - Self Opt-in
                
            case .swapAndPay(.skipOptInTapped):
                state.swapAndPayState.optionOneChecked = false
                state.swapAndPayState.optionTwoChecked = false
                state.path.append(.swapAndPayOptInForced(state.swapAndPayState))
                return .none

            case .swapAndPay(.confirmOptInTapped):
                state.path.append(.swapAndPayForm(state.swapAndPayState))
                return .send(.swapAndPay(.refreshSwapAssets))

            case .path(.element(id: _, action: .swapAndPayOptInForced(.confirmForcedOptInTapped))):
                state.path.append(.swapAndPayForm(state.swapAndPayState))
                return .send(.swapAndPay(.refreshSwapAssets))

            case .path(.element(id: _, action: .swapAndPayOptInForced(.goBackForcedOptInTapped))):
                let _ = state.path.popLast()
                return .none

            case .path(.element(id: _, action: .swapAndPayForm(.internalBackButtonTapped))):
                return .send(.swapAndPay(.backButtonTapped(state.isSwapInFlight)))

            // MARK: - Swap to ZEC Summary
                
            case .path(.element(id: _, action: .swapToZecSummary(.sentTheFundsButtonTapped))):
                return .send(.storeLastUsedAsset)

            case .path(.element(id: _, action: .swapToZecSummary(.customBackRequired))):
                let _ = state.path.popLast()
                return .send(.storeLastUsedAsset)

            default: return .none
            }
        }
    }
}
