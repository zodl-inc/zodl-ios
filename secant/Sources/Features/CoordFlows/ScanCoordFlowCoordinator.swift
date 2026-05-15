//
//  ScanCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-19.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import ZcashPaymentURI

extension ScanCoordFlow {
    func coordinatorReduce() -> Reduce<ScanCoordFlow.State, ScanCoordFlow.Action> {
        Reduce { state, action in
            switch action {

                // MARK: - Address Book
                
            case let .path(.element(id: _, action: .addressBook(.editId(address, _)))):
                let _ = state.path.removeLast()
                audioServices.systemSoundVibrate()
                if let first = state.path.ids.first {
                    return .send(.path(.element(id: first, action: .sendForm(.addressUpdated(address.redacted)))))
                }
                return .none

            case .path(.element(id: _, action: .addressBook(.walletAccountTapped(let contact)))):
                if let address = contact.unifiedAddress {
                    let _ = state.path.removeLast()
                    audioServices.systemSoundVibrate()
                    if let first = state.path.ids.first {
                        return .send(.path(.element(id: first, action: .sendForm(.addressUpdated(address.redacted)))))
                    }
                }
                return .none
                
            case .path(.element(id: _, action: .addressBook(.addManualButtonTapped))):
                var addressBookState = AddressBook.State.initial
                addressBookState.isAddressFocused = true
                addressBookState.context = .send
                state.path.append(.addressBookContact(addressBookState))
                return .none

            case .path(.element(id: _, action: .addressBook(.scanButtonTapped))):
                var scanState = Scan.State.initial
                scanState.checkers = [.zcashAddressScanChecker]
                state.path.append(.scan(scanState))
                return .none

                // MARK: - Address Book Contact

            case .path(.element(id: _, action: .addressBookContact(.dismissAddContactRequired))):
                let _ = state.path.popLast()
                
                // handling the path in the transaction details
                for element in state.path {
                    if element.is(\.transactionDetails) {
                        return .none
                    }
                }

                // handling the path in send confirmation
                for element in state.path {
                    if element.is(\.sendConfirmation) {
                        return .none
                    }
                }

                // handling the path in send form
                for element in state.path {
                    if element.is(\.scan) {
                        let _ = state.path.popLast()
                        return .none
                    }
                }
                return .none
                
                // MARK: - Keystone
                
            case .path(.element(id: _, action: .sendConfirmation(.confirmWithKeystoneTapped))):
                for element in state.path {
                    if case .sendConfirmation(let sendConfirmationState) = element {
                        state.path.append(.confirmWithKeystone(sendConfirmationState))
                        if let last = state.path.ids.last {
                            return .send(.path(.element(id: last, action: .confirmWithKeystone(.resolvePCZT))))
                        }
                    }
                }
                return .none

            case .path(.element(id: _, action: .requestZecConfirmation(.confirmWithKeystoneTapped))):
                for element in state.path {
                    if case .requestZecConfirmation(let sendConfirmationState) = element {
                        state.path.append(.confirmWithKeystone(sendConfirmationState))
                        if let last = state.path.ids.last {
                            return .send(.path(.element(id: last, action: .confirmWithKeystone(.resolvePCZT))))
                        }
                    }
                }
                return .none

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

            case .path(.element(id: _, action: .confirmWithKeystone(.updateResult(let result)))):
                for element in state.path {
                    if case .confirmWithKeystone(let sendConfirmationState) = element {
                        return .send(.resolveSendResult(result, sendConfirmationState))
                    }
                }
                return .none
                
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
                
                // MARK: - Request ZEC Confirmation
                
            case .path(.element(id: _, action: .requestZecConfirmation(.goBackTappedFromRequestZec))):
                for (id, element) in zip(state.path.ids, state.path) {
                    if element.is(\.sendForm) {
                        state.path.pop(to: id)
                    }
                }
                return .none

            case .path(.element(id: _, action: .requestZecConfirmation(.sendRequested))):
                for element in state.path {
                    if case .requestZecConfirmation(let sendConfirmationState) = element {
                        state.path.append(.sending(sendConfirmationState))
                        break
                    }
                }
                return .none

            case .path(.element(id: _, action: .requestZecConfirmation(.saveAddressTapped(let address)))):
                var addressBookState = AddressBook.State.initial
                addressBookState.isNameFocused = true
                addressBookState.address = address.data
                addressBookState.isValidZcashAddress = true
                addressBookState.context = .send
                state.path.append(.addressBookContact(addressBookState))
                return .none
                
            case .path(.element(id: _, action: .requestZecConfirmation(.updateResult(let result)))):
                for element in state.path {
                    if case .requestZecConfirmation(let sendConfirmationState) = element {
                        return .send(.resolveSendResult(result, sendConfirmationState))
                    }
                }
                return .none
                
                // MARK: - Scan
                
            case .path(.element(id: _, action: .scan(.foundAddress(let address)))):
                for (id, element) in zip(state.path.ids, state.path) {
                    if element.is(\.sendForm) {
                        let _ = state.path.removeLast()
                        audioServices.systemSoundVibrate()
                        return .send(.path(.element(id: id, action: .sendForm(.addressUpdated(address)))))
                    }
                }
                return .none

            case .path(.element(id: _, action: .scan(.cancelTapped))):
                let _ = state.path.popLast()
                return .none
                
            case .path(.element(id: _, action: .scan(.foundRequestZec(let requestPayment)))):
                if case .legacy(let address) = requestPayment {
                    for (id, element) in zip(state.path.ids, state.path) {
                        if element.is(\.sendForm) {
                            let _ = state.path.removeLast()
                            audioServices.systemSoundVibrate()
                            state.path[id: id, case: \.sendForm]?.memoState.text = ""
                            return .merge(
                                .send(.path(.element(id: id, action: .sendForm(.zecAmountUpdated("".redacted))))),
                                .send(.path(.element(id: id, action: .sendForm(.addressUpdated(address.value.redacted)))))
                            )
                        }
                    }
                } else if case .request(let paymentRequest) = requestPayment {
                    return .send(.getProposal(paymentRequest))
                }
                return .none
                
                // MARK: - Self
                
            case .scan(.foundAddress(let address)):
                audioServices.systemSoundVibrate()
                state.path.append(.sendForm(SendForm.State.initial))
                if let first = state.path.ids.first {
                    return .send(.path(.element(id: first, action: .sendForm(.addressUpdated(address)))))
                }
                return .none

            case .scan(.foundRequestZec(let requestPayment)):
                if case .legacy(let address) = requestPayment {
                    return .send(.scan(.foundAddress(address.value.redacted)))
                } else if case .request(let paymentRequest) = requestPayment {
                    if let payment = paymentRequest.payments.first, payment.amount == nil {
                        return .send(.scan(.foundAddress(payment.recipientAddress.value.redacted)))
                    }
                    return .send(.getProposal(paymentRequest))
                }
                return .none
                
            case .getProposal(let paymentRequest):
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                
                do {
                    if let payment = paymentRequest.payments.first {
                        var textMemo = ""
                        if let memoBytes = payment.memo, let memo = try? Memo(bytes: [UInt8](memoBytes.memoData)) {
                            textMemo = memo.toString() ?? ""
                        }
                        let numberLocale = numberFormatter.convertUSToLocale(payment.amount?.toString() ?? "0") ?? ""
                        state.recipient = try Recipient(payment.recipientAddress.value, network: zcashSDKEnvironment.network.networkType)
                        state.memo = textMemo.isEmpty ? nil : try Memo(string: textMemo)
                        
                        if let number = numberFormatter.number(numberLocale) {
                            state.amount = Zatoshi(NSDecimalNumber(
                                decimal: number.decimalValue * Decimal(Zatoshi.Constants.oneZecInZatoshi)
                            ).roundedZec.int64Value)
                        }
                    }
                } catch {
                    return .send(.requestZecFailed)
                }
                
                return .run { [state] send in
                    guard let recipient = state.recipient else {
                        return
                    }
                    do {
                        let proposal = try await sdkSynchronizer.proposeTransfer(account.id, recipient, state.amount, state.memo)
                        await send(.proposalResolved(proposal))
                    } catch {
                        await send(.requestZecFailed)
                    }
                }
                
            case .proposalResolved(let proposal):
                if state.path.ids.isEmpty {
                    return .send(.proposalResolvedNoSendForm(proposal))
                }
                return .send(.proposalResolvedExistingSendForm(proposal))

            case .proposalResolvedExistingSendForm(let proposal):
                state.proposal = proposal
                
                guard let address = state.recipient?.stringEncoded else {
                    return .send(.requestZecFailed)
                }

                var sendConfirmationState = SendConfirmation.State.initial
                sendConfirmationState.amount = state.amount
                sendConfirmationState.address = address
                sendConfirmationState.proposal = proposal
                sendConfirmationState.feeRequired = proposal.totalFeeRequired()
                sendConfirmationState.message = state.memo?.toString() ?? ""
                sendConfirmationState.currencyAmount = state.currencyConversion?.convert(state.amount).redacted ?? .empty
                state.path.append(.requestZecConfirmation(sendConfirmationState))
                
                audioServices.systemSoundVibrate()
                
                if let first = state.path.ids.first {
                    state.path[id: first, case: \.sendForm]?.memoState.text = sendConfirmationState.message
                    return .merge(
                        .send(.path(.element(id: first, action: .sendForm(.zecAmountUpdated(state.amount.decimalString().redacted))))),
                        .send(.path(.element(id: first, action: .sendForm(.addressUpdated(address.redacted)))))
                    )
                }
                return .none

            case .proposalResolvedNoSendForm(let proposal):
                state.proposal = proposal
                
                guard let address = state.recipient?.stringEncoded else {
                    return .send(.requestZecFailed)
                }
                
                var sendFormState = SendForm.State.initial
                sendFormState.memoState.text = state.memo?.toString() ?? ""
                state.path.append(.sendForm(sendFormState))

                var sendConfirmationState = SendConfirmation.State.initial
                sendConfirmationState.amount = state.amount
                sendConfirmationState.address = address
                sendConfirmationState.proposal = proposal
                sendConfirmationState.feeRequired = proposal.totalFeeRequired()
                sendConfirmationState.message = sendFormState.memoState.text
                sendConfirmationState.currencyAmount = state.currencyConversion?.convert(state.amount).redacted ?? .empty
                state.path.append(.requestZecConfirmation(sendConfirmationState))
                
                audioServices.systemSoundVibrate()
                
                if let first = state.path.ids.first {
                    return .merge(
                        .send(.path(.element(id: first, action: .sendForm(.zecAmountUpdated(state.amount.decimalString().redacted))))),
                        .send(.path(.element(id: first, action: .sendForm(.addressUpdated(address.redacted)))))
                    )
                }
                return .none

            case .requestZecFailed:
                if state.path.ids.isEmpty {
                    return .send(.requestZecFailedNoSendForm)
                }
                return .send(.requestZecFailedExistingSendForm)

            case .requestZecFailedExistingSendForm:
                let _ = state.path.removeLast()
                for (id, element) in zip(state.path.ids, state.path) {
                    if element.is(\.sendForm) {
                        audioServices.systemSoundVibrate()
                        
                        let address = state.recipient?.stringEncoded ?? ""
                        let memo = state.memo?.toString() ?? ""
                        state.path[id: id, case: \.sendForm]?.memoState.text = memo
                        return .merge(
                            .send(.path(.element(id: id, action: .sendForm(.zecAmountUpdated(state.amount.decimalString().redacted))))),
                            .send(.path(.element(id: id, action: .sendForm(.addressUpdated(address.redacted)))))
                        )
                    }
                }
                return .none

            case .requestZecFailedNoSendForm:
                let address = state.recipient?.stringEncoded ?? ""
                var sendFormState = SendForm.State.initial
                sendFormState.memoState.text = state.memo?.toString() ?? ""
                state.path.append(.sendForm(sendFormState))
                
                audioServices.systemSoundVibrate()
                
                if let first = state.path.ids.first {
                    return .merge(
                        .send(.path(.element(id: first, action: .sendForm(.zecAmountUpdated(state.amount.decimalString().redacted))))),
                        .send(.path(.element(id: first, action: .sendForm(.addressUpdated(address.redacted)))))
                    )
                }
                return .none

            case let .resolveSendResult(result, sendConfirmationState):
                switch result {
                case .failure:
                    state.path.append(.sendResultFailure(sendConfirmationState))
                case .pending:
                    state.path.append(.sendResultPending(sendConfirmationState))
                case .success:
                    state.path.append(.sendResultSuccess(sendConfirmationState))
                default: break
                }
                return .none
                
            case .viewTransactionRequested(let sendConfirmationState):
                if let txid = sendConfirmationState.txIdToExpand {
                    var transactionDetailsState = TransactionDetails.State.initial
                    if let index = state.transactions.index(id: txid) {
                        transactionDetailsState.transaction = state.transactions[index]
                    } else {
                        transactionDetailsState.transaction = TransactionState(
                            pendingSendId: txid,
                            zecAmount: sendConfirmationState.amount
                        )
                    }
                    transactionDetailsState.isCloseButtonRequired = true
                    state.path.append(.transactionDetails(transactionDetailsState))
                }
                return .none
                
                // MARK: - Send

            case .path(.element(id: _, action: .sendForm(.addressBookTapped))):
                var addressBookState = AddressBook.State.initial
                addressBookState.isInSelectMode = true
                addressBookState.context = .send
                state.path.append(.addressBook(addressBookState))
                return .none
                
            case .path(.element(id: _, action: .sendForm(.addNewContactTapped(let address)))):
                var addressBookState = AddressBook.State.initial
                addressBookState.isNameFocused = true
                addressBookState.address = address.data
                addressBookState.isValidZcashAddress = true
                addressBookState.context = .send
                state.path.append(.addressBookContact(addressBookState))
                return .none

            case .path(.element(id: _, action: .sendForm(.scanTapped))):
                var scanState = Scan.State.initial
                scanState.checkers = [.zcashAddressScanChecker, .requestZecScanChecker]
                state.path.append(.scan(scanState))
                return .none
                
            case .path(.element(id: _, action: .sendForm(.confirmationRequired(let confirmationType)))):
                for element in state.path {
                    if case .sendForm(let sendFormState) = element {
                        var sendConfirmationState = SendConfirmation.State.initial
                        sendConfirmationState.amount = sendFormState.amount
                        sendConfirmationState.address = sendFormState.address.data
                        sendConfirmationState.proposal = sendFormState.proposal
                        sendConfirmationState.feeRequired = sendFormState.feeRequired
                        sendConfirmationState.message = sendFormState.message
                        let currencyAmount = sendFormState.currencyConversion?.convert(sendFormState.amount).redacted ?? .empty
                        sendConfirmationState.currencyAmount = currencyAmount

                        if confirmationType == .send {
                            state.path.append(.sendConfirmation(sendConfirmationState))
                        }
                    }
                }
                return .none

                // MARK: - Send Confirmation
                
            case .path(.element(id: _, action: .sendConfirmation(.cancelTapped))):
                let _ = state.path.removeLast()
                return .none

            case .path(.element(id: _, action: .sendConfirmation(.sendRequested))):
                for element in state.path {
                    if case .sendConfirmation(let sendConfirmationState) = element {
                        state.path.append(.sending(sendConfirmationState))
                        break
                    }
                }
                return .none
                
            case .path(.element(id: _, action: .sendConfirmation(.updateResult(let result)))):
                for element in state.path {
                    if case .sendConfirmation(let sendConfirmationState) = element {
                        return .send(.resolveSendResult(result, sendConfirmationState))
                    }
                }
                return .none

            case .path(.element(id: _, action: .preSendingFailure(.backFromPCZTFailureTapped))):
                for (id, element) in zip(state.path.ids, state.path) {
                    if element.is(\.sendForm) {
                        state.path.pop(to: id)
                    }
                }
                return .none

            case .path(.element(id: _, action: .sendResultSuccess(.viewTransactionTapped))),
                    .path(.element(id: _, action: .sendResultFailure(.viewTransactionTapped))),
                    .path(.element(id: _, action: .sendResultPending(.viewTransactionTapped))):
                for element in state.path.reversed() {
                    if case .sendConfirmation(let sendConfirmationState) = element {
                        return .send(.viewTransactionRequested(sendConfirmationState))
                    } else if case .requestZecConfirmation(let sendConfirmationState) = element {
                        return .send(.viewTransactionRequested(sendConfirmationState))
                    } else if case .confirmWithKeystone(let sendConfirmationState) = element {
                        return .send(.viewTransactionRequested(sendConfirmationState))
                    }
                }
                return .none

                // MARK: - Transaction Details
                
            case .path(.element(id: _, action: .transactionDetails(.saveAddressTapped))):
                for element in state.path {
                    if case .transactionDetails(let transactionDetailsState) = element {
                        var addressBookState = AddressBook.State.initial
                        addressBookState.address = transactionDetailsState.transaction.address
                        addressBookState.isNameFocused = true
                        addressBookState.isValidZcashAddress = true
                        addressBookState.context = .send
                        state.path.append(.addressBookContact(addressBookState))
                    }
                }
                return .none

            case .path(.element(id: _, action: .transactionDetails(.sendAgainTapped))):
                for (id, element) in zip(state.path.ids, state.path) {
                    if element.is(\.sendForm) {
                        state.path.pop(to: id)
                    }
                }
                return .none
 
            default: return .none
            }
        }
    }
}
