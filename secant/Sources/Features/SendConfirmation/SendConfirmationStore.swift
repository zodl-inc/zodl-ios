//
//  SendConfirmationStore.swift
//  
//
//  Created by Lukáš Korba on 13.05.2024.
//

import SwiftUI
import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit
#if canImport(MessageUI)
import MessageUI
#endif

@Reducer
struct SendConfirmation {
    enum Constants {
        static let delay = 1.0
    }
    
    @ObservableState
    struct State: Equatable {
        enum Result: Equatable {
            case failure
            case pending
            case success
        }
        
        /// Type of transaction, main purpose is to distinguish copies based on a type.
        enum TransactionType: Equatable {
            /// 3rd party swap transaction - pay path
            case pay
            /// Regular Zcash Transaction
            case regular
            /// 3rd party swap transaction - pay path
            case swap
        }

        var address: String
        @Shared(.inMemory(.addressBookContacts)) var addressBookContacts: AddressBookContacts = .empty
        var alias: String?
        @Presents var alert: AlertState<Action>?
        var amount: Zatoshi
        var canSendMail = false
        var currencyAmount: RedactableString
        /// MOB-1510: firmware version detected on the most recent `foundPCZT` scan that failed the
        /// minimum-firmware gate — `nil` when the scan carried no version stamp at all (firmware
        /// older than the stamping feature). Drives the copy on `KeystoneFirmwareUpdateView`.
        var detectedKeystoneFirmware: KeystoneDisplayFirmwareVersion?
        var failedCode: Int?
        var failedDescription: String?
        var isAnchorError = false
        var failedPcztMsg: String?
        @Shared(.inMemory(.featureFlags)) var featureFlags: FeatureFlags = .initial
        var feeRequired: Zatoshi
        var isAddressExpanded = false
        var isKeystoneCodeFound = false
        var isOrchardWarningPresented = false
        var isQRCodeEnlarged = false
        var isSending = false
        var isShielding = false
        var isTransparentAddress = false
        var message: String
        var messageToBeShared: String?
        var orchardWarningShown = false
        var partialFailureTxIds: [String] = []
        var partialFailureStatuses: [String] = []
        var pczt: Pczt?
        var pcztForUI: Pczt?
        var pcztWithProofs: Pczt?
        var pcztWithSigs: Pczt?
        var pendingCancelFromOrchardWarning = false
        var pendingDescription: String?
        var proposal: Proposal?
        var randomSuccessIconIndex = 0
        var randomFailureIconIndex = 0
        var randomResubmissionIconIndex = 0
        var redactedPcztForSigner: Pczt?
        var rejectSendRequest = false
        var result: Result?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var scanFailedDuringScanBinding = false
        var scanFailedPreScanBinding = false
        var sendingScreenOnAppearTimestamp: TimeInterval = 0
        var supportData: SupportData?
        var type: TransactionType = .regular
        var txIdToExpand: String?
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        @Shared(.inMemory(.zashiWalletAccount)) var zashiWalletAccount: WalletAccount? = nil

        var pcztToShare: Pczt?

        var addressToShow: String {
            isTransparentAddress
            ? address
            : isAddressExpanded
            ? address
            : address.zip316
        }
        
        var successIlustration: Image {
            switch randomSuccessIconIndex {
            case 1: return Asset.Assets.Illustrations.success1.image
            default: return Asset.Assets.Illustrations.success2.image
            }
            
        }

        var failureIlustration: Image {
            switch randomFailureIconIndex {
            case 1: return Asset.Assets.Illustrations.failure1.image
            case 2: return Asset.Assets.Illustrations.failure2.image
            default: return Asset.Assets.Illustrations.failure3.image
            }
        }

        var resubmissionIlustration: Image {
            switch randomResubmissionIconIndex {
            case 1: return Asset.Assets.Illustrations.resubmission1.image
            default: return Asset.Assets.Illustrations.resubmission2.image
            }
        }

        init(
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
    
    enum Action: BindableAction, Equatable {
        case alert(PresentationAction<Action>)
        case backFromFailureTapped
        case binding(BindingAction<SendConfirmation.State>)
        case cancelTapped
        case closeTapped
        case confirmationScreenAppeared
        case confirmWithKeystoneTapped
        case enlargeQRCodeTapped
        case getSignatureTapped
        case goBackTappedFromRequestZec
        case onAppear
        case orchardWarningCancelTapped
        case orchardWarningContinueTapped
        case orchardWarningDismissed
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
        case updatePendingDescription(String?)
        case updateResult(State.Result?)
        case updateTxIdToExpand(String?)
        case viewTransactionTapped
        
        // PCZT
        case addProofsToPczt
        case backFromPCZTFailureTapped
        case createTransactionFromPCZT
        case foundPCZT(Pczt)
        // MOB-1510: Keystone minimum-firmware gate — `keystoneFirmwareUpdateRequired` fires from
        // `foundPCZT` in place of scheduling `createTransactionFromPCZT` when the signed PCZT's
        // firmware is unstamped or below `KeystoneDisplayFirmwareVersion.minimumSupported`; on an accepted
        // firmware, `foundPCZT` fires `keystoneFirmwareAccepted` for the coordinators to observe.
        // `keystoneFirmwareUpdateCloseTapped` is `KeystoneFirmwareUpdateView`'s Close button.
        case keystoneFirmwareAccepted
        case keystoneFirmwareUpdateCloseTapped
        case keystoneFirmwareUpdateRequired
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

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                // NB: do NOT reset `pcztForUI` here. It is produced once by `.resolvePCZT` and cleared
                // only by `.resetPCZTs` (reject / completion). macOS re-fires `onAppear` on a window
                // minimize/restore; clearing it here wiped the live Keystone signing QR mid-flow (the
                // screen fell back to a spinner). Each flow already enters with a fresh `.initial` state
                // (pcztForUI == nil), so the reset was redundant for fresh entry anyway.
                state.partialFailureTxIds = []
                state.partialFailureStatuses = []
                state.pendingDescription = nil
                state.rejectSendRequest = false
                state.txIdToExpand = nil
                state.randomSuccessIconIndex = Int.random(in: 1...2)
                state.randomFailureIconIndex = Int.random(in: 1...3)
                state.randomResubmissionIconIndex = Int.random(in: 1...2)
                state.isTransparentAddress = derivationTool.isTransparentAddress(state.address, zcashSDKEnvironment.network().networkType)
                // TCA Store is @MainActor; reducer body always runs on main.
                state.canSendMail = MailSupport.canSendMail()
                state.alias = nil
                for contact in state.addressBookContacts.contacts {
                    if contact.address == state.address {
                        state.alias = contact.name
                        break
                    }
                }
                return .none

            case .confirmationScreenAppeared:
                // Deliberately separate from `.onAppear`: this reducer is also shared by screens
                // that never attach the warning sheet (e.g. the SwapAndPay flow pushing
                // `confirmWithKeystone` with a fresh state), which must never trip or burn this
                // one-shot latch just because `.onAppear` fired.
                if state.proposal?.spendsLegacyOrchardFunds == true && !state.orchardWarningShown {
                    state.isOrchardWarningPresented = true
                    state.orchardWarningShown = true
                }
                return .none

            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .binding:
                return .none

            case .enlargeQRCodeTapped:
                state.isQRCodeEnlarged = true
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

            case .orchardWarningCancelTapped:
                state.isOrchardWarningPresented = false
                state.pendingCancelFromOrchardWarning = true
                return .none

            case .orchardWarningContinueTapped:
                state.isOrchardWarningPresented = false
                return .none

            case .orchardWarningDismissed:
                // Pop-back must happen only after the sheet finished dismissing (this action is
                // sent from the sheet's `onDismiss`), otherwise SwiftUI would pop a screen that
                // still presents a sheet.
                if state.pendingCancelFromOrchardWarning {
                    state.pendingCancelFromOrchardWarning = false
                    return .send(.cancelTapped)
                }
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
                    // macOS: the Secure-Enclave seed decrypt in `.sendTriggered` is itself the biometric
                    // gate, so an app-level prompt here would be a redundant SECOND auth — defer to it
                    // (`authenticateForSeedDecrypt` returns true without prompting on macOS). iOS prompts.
                    guard await localAuthentication.authenticateForSeedDecrypt(for: .sendFunds) else {
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
                        let storedWallet = try await walletStorage.exportWallet(AuthenticationContext.sendFunds.localizedReason)
                        let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                        let network = zcashSDKEnvironment.network().networkType
                        let spendingKey = try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, network)

                        let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal, spendingKey)

                        switch result {
                        case let .grpcFailure(txIds, reason):
                            await send(.updatePendingDescription(
                                reason == .timeout ? String(localizable: .sendPendingTimeoutInfo) : nil
                            ))
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
                // MOB-385: rustCreateToAddress is the typed SDK case for Rust creation failures.
                // The anchor string comes from Rust (zcash_client_sqlite) — no typed sub-code exists yet.
                // If the SDK ever adds one, replace the string check with it and drop the comment.
                if case let .rustCreateToAddress(rustError) = error {
                    state.isAnchorError = rustError.localizedCaseInsensitiveContains("Unable to compute anchor")
                } else {
                    state.isAnchorError = false
                }
                state.isSending = false
                let diffTime = Date().timeIntervalSince1970 - state.sendingScreenOnAppearTimestamp
                let waitTimeToPresentScreen = diffTime > 2.0 ? 0.01 : 2.0 - diffTime
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(waitTimeToPresentScreen))
                    await send(.updateResult(isTxIdPresentInTheDB ? .pending : .failure))
                }

            case let .sendPartial(txIds, statuses):
                state.failedCode = -999
                state.failedDescription = statuses.joined(separator: ", ")
                state.isSending = false
                state.partialFailureTxIds = txIds
                state.partialFailureStatuses = statuses
                let diffTime = Date().timeIntervalSince1970 - state.sendingScreenOnAppearTimestamp
                let waitTimeToPresentScreen = diffTime > 2.0 ? 0.01 : 2.0 - diffTime
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(waitTimeToPresentScreen))
                    await send(.updateResult(.failure))
                }

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

            case let .updatePendingDescription(description):
                state.pendingDescription = description
                return .none

            case .reportTapped:
                var supportData = SupportDataGenerator.generate()
                let partialFailureMessage = state.partialFailureStatuses.isEmpty
                    ? ""
                    : """

                    Partial transaction statuses:
                    \(state.partialFailureStatuses.joined(separator: "\n"))
                    """
                supportData.message =
                """
                \(state.failedCode ?? -1000) \(state.failedDescription ?? "")
                \(partialFailureMessage)

                \(supportData.message)

                \(state.failedPcztMsg ?? "")
                """
#if os(macOS)
                // macOS has no in-app composer; UIMailDialogView opens the default mail client via a
                // `mailto:` URL and MailSupport.canSendMail() is always true here. The failure screen is a
                // separate CoordFlow destination that never runs the confirmation screen's canSendMail probe,
                // so route the report straight to mail. iOS keeps its canSendMail-gated share fallback.
                state.supportData = supportData
#else
                if state.canSendMail {
                    state.supportData = supportData
                } else {
                    state.messageToBeShared = supportData.message
                }
#endif
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

                    // MOB-1510: firmware >= 2.4.6 stamps its version into every signed PCZT, two
                    // releases before the minimum this gate enforces — an unstamped PCZT is
                    // therefore necessarily below minimum, never merely "unknown".
                    let firmwareStamp = pcztWithSigs.keystoneFirmwareStamp()
                    let detectedFirmware = firmwareStamp.map { KeystoneDisplayFirmwareVersion.fromStamp($0) }
                    // Both numberings, because they differ: the device stamps its internal major,
                    // which is 10 higher than the version shown on its own screen.
                    let firmwareGateLog = """
                        Keystone firmware gate: raw stamp \(firmwareStamp?.rawString ?? "absent"), \
                        reads as \(detectedFirmware?.versionString ?? "unknown"), \
                        minimum \(KeystoneDisplayFirmwareVersion.minimumSupported.versionString)
                        """
                    guard let detectedFirmware, detectedFirmware >= KeystoneDisplayFirmwareVersion.minimumSupported else {
                        LoggerProxy.warn("\(firmwareGateLog), blocked")
                        state.detectedKeystoneFirmware = detectedFirmware
                        return .send(.keystoneFirmwareUpdateRequired)
                    }
                    LoggerProxy.info("\(firmwareGateLog), allowed")

                    state.pcztWithSigs = pcztWithSigs
                    return .merge(
                        .send(.keystoneFirmwareAccepted),
                        .run { send in
                            try? await mainQueue.sleep(for: .seconds(Constants.delay))
                            await send(.createTransactionFromPCZT)
                        }
                    )
                }
                return .none

            case .keystoneFirmwareAccepted:
                return .none

            case .keystoneFirmwareUpdateRequired:
                return .none

            case .keystoneFirmwareUpdateCloseTapped:
                // Handled by the coordinators: they pop this path element before this reducer would
                // see the action, same shape as `backFromPCZTFailureTapped`.
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
                        let result = try await sdkSynchronizer.createAndSubmitTransactionFromPCZT(pcztWithProofs, pcztWithSigs)

                        await send(.resetPCZTs)

                        switch result {
                        case let .grpcFailure(txIds, reason):
                            await send(.updatePendingDescription(
                                reason == .timeout ? String(localizable: .sendPendingTimeoutInfo) : nil
                            ))
                            await send(.updateFailedData(-999, "grpcFailure", pcztMessage))
                            await send(.updateTxIdToExpand(txIds.last))
                            let isTxIdPresentInTheDB = try await sdkSynchronizer.txIdExists(txIds.last)
                            await send(.sendFailed(
                                "sdkSynchronizer.createAndSubmitTransactionFromPCZT-grpcFailure".toZcashError(),
                                isTxIdPresentInTheDB
                            ))
                        case let .failure(txIds, code, description):
                            await send(.updateFailedData(code, description, pcztMessage))
                            await send(.updateTxIdToExpand(txIds.last))
                            let isTxIdPresentInTheDB = try await sdkSynchronizer.txIdExists(txIds.last)
                            await send(.sendFailed(
                                "sdkSynchronizer.createAndSubmitTransactionFromPCZT-failure \(code) \(description)".toZcashError(),
                                isTxIdPresentInTheDB
                            ))
                        case let .partial(txIds: txIds, statuses: statuses):
                            await send(.updateFailedData(-999, statuses.joined(separator: ", "), pcztMessage))
                            await send(.updateTxIdToExpand(txIds.first))
                            await send(.sendPartial(txIds, statuses))
                        case .success(let txIds):
                            await send(.updateTxIdToExpand(txIds.last))
                            await send(.sendDone)
                        }
                    } catch {
                        await send(.resetPCZTs)
                        await send(.updateFailedData(-996, error.toZcashError().detailedMessage, pcztMessage))
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
    var sendingInfo: String {
        isShielding
        ? String(localizable: .sendShieldingInfo)
        : type == .regular
        ? String(localizable: .sendSendingInfo)
        : String(localizable: .swapAndPaySendingInfo)
    }
    
    var successInfo: String {
        isShielding
        ? String(localizable: .sendSuccessShieldingInfo)
        : type == .regular
        ? String(localizable: .sendSuccessInfo)
        : type == .swap
        ? String(localizable: .swapAndPaySuccessSwapInfo)
        : String(localizable: .swapAndPaySuccessPayInfo)
    }
    
    var pendingInfo: String {
        pendingDescription
        ?? (isShielding
        ? String(localizable: .sendPendingShieldingInfo)
        : type == .regular
        ? String(localizable: .sendPendingInfo)
        : type == .swap
        ? String(localizable: .swapAndPayPendingSwapInfo)
        : String(localizable: .swapAndPayPendingPayInfo))
    }
    
    var pendingTitle: String {
        isShielding
        ? String(localizable: .sendPendingShieldingTitle)
        : type == .regular
        ? String(localizable: .sendPendingTitle)
        : type == .swap
        ? String(localizable: .swapAndPayPendingSwapTitle)
        : String(localizable: .swapAndPayPendingPayTitle)
    }
    

    var failureInfo: String {
        if !partialFailureTxIds.isEmpty {
            return String(localizable: .sendPartialFailureInfo)
        }

        if isAnchorError {
            return String(localizable: .sendFailureAnchorInfo)
        }

        return isShielding
        ? String(localizable: .sendFailureShieldingInfo)
        : type == .regular
        ? String(localizable: .sendFailureInfo)
        : type == .swap
        ? String(localizable: .swapAndPayFailureSwapInfo)
        : String(localizable: .swapAndPayFailurePayInfo)
    }
}

// MARK: Alerts

extension AlertState where Action == SendConfirmation.Action {
    static func sendFailure(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .sendAlertFailureTitle))
        } message: {
            TextState(String(localizable: .sendAlertFailureMessage(error.detailedMessage)))
        }
    }
}

extension Pczt {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
