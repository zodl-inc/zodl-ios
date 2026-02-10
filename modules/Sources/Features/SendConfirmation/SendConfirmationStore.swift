//
//  SendConfirmationStore.swift
//  
//
//  Created by Lukáš Korba on 13.05.2024.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit
import AudioServices
import Utils
import MnemonicClient
import SDKSynchronizer
import WalletStorage
import ZcashSDKEnvironment
import UIComponents
import Models
import Generated
import BalanceFormatter
import WalletBalances
import LocalAuthenticationHandler
import AddressBookClient
import MessageUI
import SupportDataGenerator
import KeystoneHandler
import TransactionDetails
import AddressBook

@Reducer
public struct SendConfirmation {
    enum Constants {
        static let delay = 1.0
    }
    
    @ObservableState
    public struct State: Equatable {
        public enum Result: Equatable {
            case failure
            case pending
            case success
        }
        
        /// Type of transaction, main purpose is to distinguish copies based on a type.
        public enum TransactionType: Equatable {
            /// 3rd party swap transaction - pay path
            case pay
            /// Regular Zcash Transaction
            case regular
            /// 3rd party swap transaction - pay path
            case swap
        }

        public var address: String
        @Shared(.inMemory(.addressBookContacts)) public var addressBookContacts: AddressBookContacts = .empty
        public var alias: String?
        @Presents public var alert: AlertState<Action>?
        public var amount: Zatoshi
        public var canSendMail = false
        public var currencyAmount: RedactableString
        public var failedCode: Int?
        public var failedDescription: String?
        public var failedPcztMsg: String?
        @Shared(.inMemory(.featureFlags)) public var featureFlags: FeatureFlags = .initial
        public var feeRequired: Zatoshi
        public var isAddressExpanded = false
        public var isKeystoneCodeFound = false
        public var isSending = false
        public var isShielding = false
        public var isTransparentAddress = false
        public var message: String
        public var messageToBeShared: String?
        public var partialFailureTxIds: [String] = []
        public var partialFailureStatuses: [String] = []
        public var pczt: Pczt?
        public var pcztForUI: Pczt?
        public var pcztWithProofs: Pczt?
        public var pcztWithSigs: Pczt?
        public var proposal: Proposal?
        public var randomSuccessIconIndex = 0
        public var randomFailureIconIndex = 0
        public var randomResubmissionIconIndex = 0
        public var redactedPcztForSigner: Pczt?
        public var rejectSendRequest = false
        public var result: Result?
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        public var scanFailedDuringScanBinding = false
        public var scanFailedPreScanBinding = false
        public var sendingScreenOnAppearTimestamp: TimeInterval = 0
        public var supportData: SupportData?
        public var type: TransactionType = .regular
        public var txIdToExpand: String?
        @Shared(.inMemory(.walletAccounts)) public var walletAccounts: [WalletAccount] = []
        @Shared(.inMemory(.zashiWalletAccount)) public var zashiWalletAccount: WalletAccount? = nil

        public var pcztToShare: Pczt?

        public var addressToShow: String {
            isTransparentAddress
            ? address
            : isAddressExpanded
            ? address
            : address.zip316
        }
        
        public var successIlustration: Image {
            switch randomSuccessIconIndex {
            case 1: return Asset.Assets.Illustrations.success1.image
            default: return Asset.Assets.Illustrations.success2.image
            }
            
        }

        public var failureIlustration: Image {
            switch randomFailureIconIndex {
            case 1: return Asset.Assets.Illustrations.failure1.image
            case 2: return Asset.Assets.Illustrations.failure2.image
            default: return Asset.Assets.Illustrations.failure3.image
            }
        }

        public var resubmissionIlustration: Image {
            switch randomResubmissionIconIndex {
            case 1: return Asset.Assets.Illustrations.resubmission1.image
            default: return Asset.Assets.Illustrations.resubmission2.image
            }
        }

        public init(
            address: String,
            amount: Zatoshi,
            currencyAmount: RedactableString = .empty,
            feeRequired: Zatoshi,
            isSending: Bool = false,
            message: String,
            proposal: Proposal?
        ) {
            self.address = address
            self.amount = amount
            self.currencyAmount = currencyAmount
            self.feeRequired = feeRequired
            self.isSending = isSending
            self.message = message
            self.proposal = proposal
        }
    }
    
    public enum Action: BindableAction, Equatable {
        case alert(PresentationAction<Action>)
        case backFromFailureTapped
        case binding(BindingAction<SendConfirmation.State>)
        case cancelTapped
        case closeTapped
        case confirmWithKeystoneTapped
        case getSignatureTapped
        case goBackTappedFromRequestZec
        case onAppear
        case rejectRequestCanceled
        case rejectRequested
        case rejectTapped
        case reportTapped
        case saveAddressTapped(RedactableString)
        case sendDone
        case sendFailed(ZcashError?, Bool)
        case sendingScreenOnAppear
        case sendPartial([String], [String])
        case sendRequested
        case sendSupportMailFinished
        case sendTapped
        case sendTriggered
        case shareFinished
        case showHideButtonTapped
        case stopSending
        case updateFailedData(Int, String, String)
        case updateResult(State.Result?)
        case updateTxIdToExpand(String?)
        case viewTransactionTapped
        
        // PCZT
        case addProofsToPczt
        case backFromPCZTFailureTapped
        case createTransactionFromPCZT
        case foundPCZT(Pczt)
        case pcztResolved(Pczt)
        case pcztSendFailed(ZcashError?)
        case pcztWithProofsResolved(Pczt)
        case redactedPCZTForSigner(Pczt)
        case redactPCZTForSigner
        case resetPCZTs
        case resolvePCZT
        case sharePCZT
        
        // Swap
        case checkStatusTapped
    }

    @Dependency(\.addressBook) var addressBook
    @Dependency(\.audioServices) var audioServices
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.keystoneHandler) var keystoneHandler
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                state.pcztForUI = nil
                state.rejectSendRequest = false
                state.txIdToExpand = nil
                state.randomSuccessIconIndex = Int.random(in: 1...2)
                state.randomFailureIconIndex = Int.random(in: 1...3)
                state.randomResubmissionIconIndex = Int.random(in: 1...2)
                state.isTransparentAddress = derivationTool.isTransparentAddress(state.address, zcashSDKEnvironment.network.networkType)
                state.canSendMail = MFMailComposeViewController.canSendMail()
                state.alias = nil
                for contact in state.addressBookContacts.contacts {
                    if contact.address == state.address {
                        state.alias = contact.name
                        break
                    }
                }
                return .none

            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .binding:
                return .none

            case .saveAddressTapped:
                return .none

            case .showHideButtonTapped:
                state.isAddressExpanded.toggle()
                return .none

            case .goBackTappedFromRequestZec:
                return .none

            case .cancelTapped:
                return .none

            case .viewTransactionTapped:
                return .none
                
            case .closeTapped, .backFromFailureTapped:
                return .none

            case .stopSending:
                state.isSending = false
                return .none

            case .sendTapped:
                state.isSending = true
                return .run { send in
                    guard await localAuthentication.authenticate() else {
                        await send(.stopSending)
                        return
                    }
                    
                    await send(.sendRequested)
                }

            case .sendRequested:
                return .run { send in
                    // delay here is necessary because we've just pushed the sending screen
                    // and we need it to finish the presentation on screen before the send logic is triggered.
                    // If the logic fails immediately, failed screen would try to be presented while
                    // sending screen is still presenting, resulting in a navigational bug.
                    try? await mainQueue.sleep(for: .seconds(Constants.delay))
                    await send(.sendTriggered)
                }
                
            case .sendTriggered:
                guard let proposal = state.proposal else {
                    return .send(.sendFailed("missing proposal".toZcashError(), false))
                }
                guard let zip32AccountIndex = state.selectedWalletAccount?.zip32AccountIndex else {
                    return .none
                }
                return .run { send in
                    do {
                        let storedWallet = try walletStorage.exportWallet()
                        let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                        let network = zcashSDKEnvironment.network.networkType
                        let spendingKey = try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, network)

                        let result = try await sdkSynchronizer.createProposedTransactions(proposal, spendingKey)

                        switch result {
                        case .grpcFailure(let txIds):
                            await send(.updateTxIdToExpand(txIds.last))
                            let isTxIdPresentInTheDB = try await sdkSynchronizer.txIdExists(txIds.last)
                            await send(.sendFailed("sdkSynchronizer.createProposedTransactions-grpcFailure".toZcashError(), isTxIdPresentInTheDB))
                        case let .failure(txIds, code, description):
                            await send(.updateFailedData(code, description, ""))
                            await send(.updateTxIdToExpand(txIds.last))
                            let isTxIdPresentInTheDB = try await sdkSynchronizer.txIdExists(txIds.last)
                            await send(.sendFailed("sdkSynchronizer.createProposedTransactions-failure \(code) \(description)".toZcashError(), isTxIdPresentInTheDB))
                        case let .partial(txIds: txIds, statuses: statuses):
                            await send(.updateTxIdToExpand(txIds.last))
                            await send(.sendPartial(txIds, statuses))
                        case .success(let txIds):
                            await send(.updateTxIdToExpand(txIds.last))
                            await send(.sendDone)
                        }
                    } catch {
                        await send(.sendFailed(error.toZcashError(), false))
                    }
                }

            case .sendDone:
                state.isSending = false
                let diffTime = Date().timeIntervalSince1970 - state.sendingScreenOnAppearTimestamp
                let waitTimeToPresentScreen = diffTime > 2.0 ? 0.01 : 2.0 - diffTime
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(waitTimeToPresentScreen))
                    await send(.updateResult(.success))
                }

            case let .sendFailed(error, isTxIdPresentInTheDB):
                state.failedDescription = error?.localizedDescription ?? ""
                state.isSending = false
                let diffTime = Date().timeIntervalSince1970 - state.sendingScreenOnAppearTimestamp
                let waitTimeToPresentScreen = diffTime > 2.0 ? 0.01 : 2.0 - diffTime
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(waitTimeToPresentScreen))
                    await send(.updateResult(isTxIdPresentInTheDB ? .pending : .failure))
                }

            case let .sendPartial(txIds, statuses):
                state.isSending = false
                state.partialFailureTxIds = txIds
                state.partialFailureStatuses = statuses
                return .send(.updateResult(.pending))

            case .updateTxIdToExpand(let txId):
                state.txIdToExpand = txId
                return .none

            case .updateResult(let result):
                state.result = result
                if let result {
                    if result == .success {
                        audioServices.systemSoundVibrate()
                        return .none
                    } else {
                        return .run { _ in
                            audioServices.systemSoundVibrate()
                            try? await mainQueue.sleep(for: .seconds(Constants.delay))
                            audioServices.systemSoundVibrate()
                        }
                    }
                } else {
                    return .none
                }
                
            case let .updateFailedData(code, desc, pcztMsg):
                state.failedCode = code
                state.failedDescription = desc
                #if DEBUG
                state.failedPcztMsg = pcztMsg
                #endif
                return .none

            case .reportTapped:
                var supportData = SupportDataGenerator.generate()
                supportData.message =
                """
                \(state.failedCode ?? -1000) \(state.failedDescription ?? "")
                
                \(supportData.message)
                
                \(state.failedPcztMsg ?? "")
                """
                if state.canSendMail {
                    state.supportData = supportData
                } else {
                    state.messageToBeShared = supportData.message
                }
                return .none
                
            case .sendSupportMailFinished:
                state.supportData = nil
                return .none
                
            case .shareFinished:
                state.messageToBeShared = nil
                state.pcztToShare = nil
                return .none
            
            case .sendingScreenOnAppear:
                state.sendingScreenOnAppearTimestamp = Date().timeIntervalSince1970
                return .none
                
            case .checkStatusTapped:
                return .none
                
                // MARK: - Keystone
                
            case .getSignatureTapped:
                state.isKeystoneCodeFound = false
                keystoneHandler.resetQRDecoder()
                return .none

            case .rejectRequestCanceled:
                state.rejectSendRequest = false
                return .none

            case .rejectRequested:
                state.rejectSendRequest = true
                return .none
                
            case .rejectTapped:
                state.rejectSendRequest = false
                return .send(.resetPCZTs)
                
            case .confirmWithKeystoneTapped:
                return .none

            case .foundPCZT(let pcztWithSigs):
                guard !state.scanFailedPreScanBinding && !state.scanFailedDuringScanBinding else {
                    return .none
                }
                if !state.isKeystoneCodeFound {
                    state.isKeystoneCodeFound = true
                    state.pcztWithSigs = pcztWithSigs
                    return .run { send in
                        try? await mainQueue.sleep(for: .seconds(Constants.delay))
                        await send(.createTransactionFromPCZT)
                    }
                }
                return .none

            case .resolvePCZT:
                guard let proposal = state.proposal, let account = state.selectedWalletAccount else {
                    return .run { send in
                        try? await mainQueue.sleep(for: .seconds(Constants.delay))
                        await send(.updateFailedData(-899, "resolvePCZT failed to start the process", ""))
                        await send(.pcztSendFailed("resolvePCZT failed to start the process".toZcashError()))
                    }
                }
                return .run { send in
                    do {
                        let pczt = try await sdkSynchronizer.createPCZTFromProposal(account.id, proposal)
                        await send(.pcztResolved(pczt))
                    } catch {
                        try? await mainQueue.sleep(for: .seconds(Constants.delay))
                        await send(.updateFailedData(-898, error.toZcashError().detailedMessage, ""))
                        await send(.pcztSendFailed("resolvePCZT createPCZTFromProposal failed".toZcashError()))
                    }
                }
                
            case .pcztResolved(let pczt):
                state.pczt = pczt
                return .merge(
                    .send(.redactPCZTForSigner),
                    .send(.addProofsToPczt)
                )
                
            case .redactPCZTForSigner:
                guard let pczt = state.pczt else {
                    return .run { send in
                        try? await mainQueue.sleep(for: .seconds(Constants.delay))
                        await send(.updateFailedData(-797, "redactPCZTForSigner failed to start the process", ""))
                        await send(.pcztSendFailed("redactPCZTForSigner failed to start the process".toZcashError()))
                    }
                }
                return .run { send in
                    do {
                        let redactedPczt = try await sdkSynchronizer.redactPCZTForSigner(Pczt(pczt))
                        await send(.redactedPCZTForSigner(redactedPczt))
                    } catch {
                        try? await mainQueue.sleep(for: .seconds(Constants.delay))
                        await send(.updateFailedData(-796, error.toZcashError().detailedMessage, ""))
                        await send(.pcztSendFailed("redactPCZTForSigner failed".toZcashError()))
                    }
                }
                
            case .redactedPCZTForSigner(let redactedPczt):
                state.redactedPcztForSigner = redactedPczt
                state.pcztForUI = redactedPczt
                return .none

            case .addProofsToPczt:
                guard let pczt = state.pczt else {
                    return .run { send in
                        try? await mainQueue.sleep(for: .seconds(Constants.delay))
                        await send(.updateFailedData(-799, "addProofsToPczt failed to start the process", ""))
                        await send(.pcztSendFailed("addProofsToPczt failed to start the process".toZcashError()))
                    }
                }
                return .run { send in
                    do {
                        let pcztWithProofs = try await sdkSynchronizer.addProofsToPCZT(Pczt(pczt))
                        await send(.pcztWithProofsResolved(pcztWithProofs))
                    } catch {
                        try? await mainQueue.sleep(for: .seconds(Constants.delay))
                        await send(.updateFailedData(-798, error.toZcashError().detailedMessage, ""))
                        await send(.pcztSendFailed("addProofsToPczt failed".toZcashError()))
                    }
                }
                
            case .pcztWithProofsResolved(let pcztWithProofs):
                state.pcztWithProofs = pcztWithProofs
                return .send(.createTransactionFromPCZT)
                
            case .sharePCZT:
                state.pcztToShare = state.pczt
                return .none
                
            case .createTransactionFromPCZT:
                guard let pcztWithProofs = state.pcztWithProofs, let pcztWithSigs = state.pcztWithSigs else {
                    return .none
                }
                #if DEBUG
                let pcztMessage =
                """
                original pczt:
                \(state.pczt?.hexEncodedString() ?? "failed to unwrap")

                redactedPcztForSigner:
                \(state.redactedPcztForSigner?.hexEncodedString() ?? "failed to unwrap")
                
                pcztWithProofs:
                \(pcztWithProofs.hexEncodedString())
                
                pcztWithSigs:
                \(pcztWithSigs.hexEncodedString())
                """
                #else
                let pcztMessage = ""
                #endif
                return .run { send in
                    do {
                        let result = try await sdkSynchronizer.createTransactionFromPCZT(pcztWithProofs, pcztWithSigs)

                        await send(.resetPCZTs)

                        switch result {
                        case .grpcFailure(let txIds):
                            await send(.updateFailedData(-999, "grpcFailure", pcztMessage))
                            let txId = txIds.last
                            await send(.updateTxIdToExpand(txId))
                            let isTxIdPresentInTheDB = try await sdkSynchronizer.txIdExists(txId)
                            await send(.sendFailed("sdkSynchronizer.createProposedTransactions".toZcashError(), isTxIdPresentInTheDB))
                        case let .failure(txIds, code, description):
                            if description.isEmpty {
                                await send(.updateFailedData(-997, "result.failure \(txIds)", pcztMessage))
                            } else {
                                await send(.updateFailedData(code, description, pcztMessage))
                            }
                            let txId = txIds.last
                            await send(.updateTxIdToExpand(txId))
                            let isTxIdPresentInTheDB = try await sdkSynchronizer.txIdExists(txId)
                            await send(.sendFailed("sdkSynchronizer.createProposedTransactions".toZcashError(), isTxIdPresentInTheDB))
                        case let .partial(txIds: txIds, statuses: statuses):
                            await send(.updateTxIdToExpand(txIds.last))
                            await send(.sendPartial(txIds, statuses))
                        case .success(let txIds):
                            await send(.updateTxIdToExpand(txIds.last))
                            await send(.sendDone)
                        }
                    } catch {
                        await send(.resetPCZTs)
                        await send(.updateFailedData(-998, error.toZcashError().detailedMessage, pcztMessage))
                        await send(.sendFailed(error.toZcashError(), false))
                    }
                }

            case .pcztSendFailed:
                state.isSending = false
                return .none

            case .backFromPCZTFailureTapped:
                return .none
                
            case .resetPCZTs:
                state.pczt = nil
                state.pcztWithProofs = nil
                state.pcztWithSigs = nil
                state.pcztToShare = nil
                state.proposal = nil
                state.redactedPcztForSigner = nil
                return .none
            }
        }
    }
}

extension SendConfirmation.State {
    public var sendingInfo: String {
        isShielding
        ? L10n.Send.shieldingInfo
        : type == .regular
        ? L10n.Send.sendingInfo
        : L10n.SwapAndPay.sendingInfo
    }
    
    public var successInfo: String {
        isShielding
        ? L10n.Send.successShieldingInfo
        : type == .regular
        ? L10n.Send.successInfo
        : type == .swap
        ? L10n.SwapAndPay.successSwapInfo
        : L10n.SwapAndPay.successPayInfo
    }
    
    public var pendingInfo: String {
        isShielding
        ? L10n.Send.pendingShieldingInfo
        : type == .regular
        ? L10n.Send.pendingInfo
        : type == .swap
        ? L10n.SwapAndPay.pendingSwapInfo
        : L10n.SwapAndPay.pendingPayInfo
    }
    
    public var pendingTitle: String {
        isShielding
        ? L10n.Send.pendingShieldingTitle
        : type == .regular
        ? L10n.Send.pendingTitle
        : type == .swap
        ? L10n.SwapAndPay.pendingSwapTitle
        : L10n.SwapAndPay.pendingPayTitle
    }
    
    public var failureInfo: String {
        isShielding
        ? L10n.Send.failureShieldingInfo
        : type == .regular
        ? L10n.Send.failureInfo
        : type == .swap
        ? L10n.SwapAndPay.failureSwapInfo
        : L10n.SwapAndPay.failurePayInfo
    }
}

// MARK: Alerts

extension AlertState where Action == SendConfirmation.Action {
    public static func sendFailure(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(L10n.Send.Alert.Failure.title)
        } message: {
            TextState(L10n.Send.Alert.Failure.message(error.detailedMessage))
        }
    }
}

extension Pczt {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
