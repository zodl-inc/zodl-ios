//
//  SendCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-18.
//

import ComposableArchitecture
import ZcashLightClientKit

import Generated
import AudioServices

import AddressBook
import Scan
import SendConfirmation
import SendForm
import TransactionDetails

extension SendCoordFlow {
    public func coordinatorReduce() -> Reduce<SendCoordFlow.State, SendCoordFlow.Action> {
        Reduce { state, action in
            switch action {
                // MARK: - Address Book
                
            case let .path(.element(id: _, action: .addressBook(.editId(address, id)))):
                state.path.removeAll()
                audioServices.systemSoundVibrate()
                return .send(.sendForm(.addressUpdated(address.redacted)))

            case .path(.element(id: _, action: .addressBook(.walletAccountTapped(let contact)))):
                if let address = contact.unifiedAddress {
                    state.path.removeAll()
                    audioServices.systemSoundVibrate()
                    return .send(.sendForm(.addressUpdated(address.redacted)))
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
                state.path.removeAll()
                return .none

            case .path(.element(id: _, action: .requestZecConfirmation(.sendRequested))):
                for element in state.path {
                    if case .requestZecConfirmation(let sendConfirmationState) = element {
                        state.path.append(.sending(sendConfirmationState))
                        break
                    }
                }
                return .none
                
            case .path(.element(id: _, action: .requestZecConfirmation(.sendFailed))):
                state.path.removeAll()
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
                // Handling of scan inside address book
                for element in state.path {
                    if element.is(\.addressBook) {
                        var addressBookState = AddressBook.State.initial
                        addressBookState.address = address.data
                        addressBookState.isValidZcashAddress = true
                        addressBookState.isNameFocused = true
                        addressBookState.context = .send
                        state.path.append(.addressBookContact(addressBookState))
                        audioServices.systemSoundVibrate()
                        return .none
                    }
                }
                // handling of scan for the send form
                let _ = state.path.popLast()
                audioServices.systemSoundVibrate()
                return .send(.sendForm(.addressUpdated(address)))

            case .path(.element(id: _, action: .scan(.foundRequestZec(let requestPayment)))):
                let _ = state.path.popLast()
                return .send(.sendForm(.requestZec(requestPayment)))

            case .path(.element(id: _, action: .scan(.cancelTapped))):
                let _ = state.path.popLast()
                return .none

                // MARK: - Send
                
            case .sendForm(.addressBookTapped):
                var addressBookState = AddressBook.State.initial
                addressBookState.isInSelectMode = true
                addressBookState.context = .send
                state.path.append(.addressBook(addressBookState))
                return .none
                
            case .sendForm(.addNewContactTapped(let address)):
                var addressBookState = AddressBook.State.initial
                addressBookState.isNameFocused = true
                addressBookState.address = address.data
                addressBookState.isValidZcashAddress = true
                addressBookState.context = .send
                state.path.append(.addressBookContact(addressBookState))
                return .none

            case .sendForm(.scanTapped):
                var scanState = Scan.State.initial
                scanState.checkers = [.zcashAddressScanChecker, .requestZecScanChecker]
                state.path.append(.scan(scanState))
                return .none
                
            case .sendForm(.confirmationRequired(let confirmationType)):
                var sendConfirmationState = SendConfirmation.State.initial
                sendConfirmationState.amount = state.sendFormState.amount
                sendConfirmationState.address = state.sendFormState.address.data
                sendConfirmationState.proposal = state.sendFormState.proposal
                sendConfirmationState.feeRequired = state.sendFormState.feeRequired
                sendConfirmationState.message = state.sendFormState.message
                let currencyAmount = state.sendFormState.currencyConversion?.convert(state.sendFormState.amount).redacted ?? .empty
                sendConfirmationState.currencyAmount = currencyAmount
                
                if confirmationType == .send {
                    state.path.append(.sendConfirmation(sendConfirmationState))
                } else if confirmationType == .requestPayment {
                    state.path.append(.requestZecConfirmation(sendConfirmationState))
                }
                return .none
                
            case let .sendForm(.sendFailed(_, confirmationType)):
                if confirmationType == .requestPayment {
                    state.path.removeAll()
                }
                return .none
                
                // MARK: - Send Confirmation

            case .path(.element(id: _, action: .sendConfirmation(.cancelTapped))):
                let _ = state.path.popLast()
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
                state.path.removeAll()
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

                // MARK: - Self

            case .backToHomeTapped:
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
                    if let index = state.transactions.index(id: txid) {
                        var transactionDetailsState = TransactionDetails.State.initial
                        transactionDetailsState.transaction = state.transactions[index]
                        transactionDetailsState.isCloseButtonRequired = true
                        state.path.append(.transactionDetails(transactionDetailsState))
                    }
                }
                return .none
                
                // MARK: - Transaction Details
                
            case .path(.element(id: _, action: .transactionDetails(.saveAddressTapped))):
                var addressBookState = AddressBook.State.initial
                addressBookState.address = state.sendFormState.address.data
                addressBookState.isNameFocused = true
                addressBookState.isValidZcashAddress = true
                addressBookState.context = .send
                state.path.append(.addressBookContact(addressBookState))
                return .none

            case .path(.element(id: _, action: .transactionDetails(.sendAgainTapped))):
                state.path.removeAll()
                return .none

            default: return .none
            }
        }
    }
}
