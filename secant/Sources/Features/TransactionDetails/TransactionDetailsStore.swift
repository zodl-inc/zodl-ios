//
//  TransactionDetailsStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 01-08-2024
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit
import MessageUI

@Reducer
struct TransactionDetails {
    @ObservableState
    struct State: Equatable {
        var CancelId = UUID()
        var SwapDetailsCancelId = UUID()

        enum Constants {
            static let messageExpandThreshold: Int = 130
            static let annotationMaxLength: Int = 90
        }
        
        enum MessageState: Equatable {
            case longCollapsed
            case longExpanded
            case short
        }
        
        enum FooterState: Equatable {
            case addNote
            case contactSupport
            case depositInfo
            case none
            case providerFailure
        }
        
        struct IncompleteSwap: Equatable {
            let date: String
            let missingFunds: String
            let tokenName: String
        }
        
        @Shared(.inMemory(.addressBookContacts)) var addressBookContacts: AddressBookContacts = .empty
        var alias: String?
        var annotation = ""
        var annotationOrigin = ""
        var annotationRequest = false
        var annotationToInput = ""
        var areMessagesResolved = false
        var areDetailsExpanded = false
        var canSendMail = false
        var hasInteractedWithBookmark = false
        var isBookmarked = false
        var isCloseButtonRequired = false
        var isEditMode = false
        var isReportSwapSheetEnabled = false
        @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
        var isSwap = false
        var messageStates: [MessageState] = []
        var messageToBeShared: String?
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        var supportData: SupportData?
        @Shared(.inMemory(.swapAssets)) var swapAssets: IdentifiedArrayOf<SwapAsset> = []
        var swapAssetFailedWithRetry: Bool? = nil
        var swapDetails: SwapDetails?
        var umSwapId: UMSwapId?
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil
        var transaction: TransactionState
        @Shared(.inMemory(.transactionMemos)) var transactionMemos: [String: [String]] = [:]
        @Shared(.inMemory(.transactions)) var transactions: IdentifiedArrayOf<TransactionState> = []
        @Shared(.inMemory(.zashiWalletAccount)) var zashiWalletAccount: WalletAccount? = nil
        
        var incompleteSwapData: IncompleteSwap? {
            guard let swapDetails else {
                return nil
            }
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            guard let date = formatter.date(from: swapDetails.deadline) else {
                return nil
            }

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, YYYY '\(String(localizable: .filterAt))' h:mm a"
            let dateStr = dateFormatter.string(from: date)
            
            return IncompleteSwap(
                date: dateStr,
                missingFunds: missingFunds ?? "",
                tokenName: swapFromAsset?.token ?? ""
            )
        }
        
        var isProcessingTooLong: Bool {
            guard swapStatus == .processing else {
                return false
            }
            
            guard let swapDetails else {
                return false
            }
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            guard let date = formatter.date(from: swapDetails.whenInitiated) else {
                return false
            }

            let diff = Date().timeIntervalSince1970 - date.timeIntervalSince1970
            
            return diff > 3600
        }
        
        var footerState: FooterState {
            // Highest priority is a provider failed, no other footer is allowed to appear
            if let _ = swapAssetFailedWithRetry, transaction.isNonZcashActivity {
                return .providerFailure
            }

            // Contact support button in unsuccessful cases
            if swapStatus == .refunded || swapStatus == .expired || swapStatus == .failed {
                return .contactSupport
            }

            // Contact support button in unsuccessful cases
            if swapStatus == .processing && isProcessingTooLong {
                return .contactSupport
            }

            // Regular buttons (Add note and save address)
            if (!transaction.isSwapToZec && swapStatus == .success) || !isSwap {
                return .addNote
            }

            // Nothing happened so far and pending deposit is the state
            if swapDetails?.status == .pendingDeposit {
                return .depositInfo
            }

            return .none
        }

        var isShielded: Bool {
            guard let swapDetails else {
                return false
            }
            
            @Dependency(\.derivationTool) var derivationTool
            @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
            
            let address = swapDetails.addressToCheckShield
            let network = zcashSDKEnvironment.network.networkType
            
            return !derivationTool.isTransparentAddress(address, network)
        }
        
        var isAnnotationModified: Bool {
            annotationToInput.trimmingCharacters(in: .whitespaces) != annotationOrigin
        }
        
        var feeStr: String {
            transaction.fee?.decimalString() ?? String(localizable: .transactionHistoryDefaultFee)
        }
        
        var memos: [String] {
            transactionMemos[transaction.id] ?? []
        }

        var totalFeesStr: String? {
            guard let totalFees = umSwapId?.totalFees else {
                return nil
            }
            
            return Zatoshi(totalFees).decimalString()
        }
        
        var swapToZecTitle: String? {
            guard let swapDetails else {
                return nil
            }
            
            switch swapDetails.status {
            case .pending: return String(localizable: .swapToZecSwapPending)
            case .refunded: return String(localizable: .swapToZecSwapRefunded)
            case .success: return String(localizable: .swapToZecSwapCompleted)
            case .failed: return String(localizable: .swapToZecSwapFailed)
            case .pendingDeposit: return String(localizable: .swapToZecSwapPending)
            case .incompleteDeposit: return String(localizable: .swapToZecSwapIncomplete)
            case .processing: return String(localizable: .swapToZecSwapProcessing)
            case .expired: return String(localizable: .swapToZecSwapExpired)
            }
        }
        
        init(
            transaction: TransactionState
        ) {
            self.transaction = transaction
        }
    }
    
    enum Action: BindableAction, Equatable {
        case addNoteTapped
        case addressTapped
        case binding(BindingAction<TransactionDetails.State>)
        case bookmarkTapped
        case checkSwapAssets
        case checkSwapStatus
        case closeDetailTapped
        case compareAndUpdateMetadataOfSwap
        case contactSupportTapped
        case deleteNoteTapped
        case memosLoaded([Memo])
        case messageTapped(Int)
        case noteButtonTapped
        case onAppear
        case onDisappear
        case observeTransactionChange
        case reportSwapTapped
        case reportSwapRequested
        case resolveMemos
        case saveAddressTapped
        case saveNoteTapped
        case sendAgainTapped
        case sendSupportMailFinished
        case shareFinished
        case showHideButtonTapped
        case swapAssetsFailedWithRetry(Bool)
        case swapAssetsLoaded(IdentifiedArrayOf<SwapAsset>)
        case swapDetailsLoaded(SwapDetails?)
        case swapRecipientTapped
        case transactionIdTapped
        case transactionsUpdated
        case trySwapsAssetsAgainTapped
    }

    @Dependency(\.addressBook) var addressBook
    @Dependency(\.mainQueue) var mainQueue
    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.swapAndPay) var swapAndPay
    @Dependency(\.userMetadataProvider) var userMetadataProvider

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.canSendMail = MFMailComposeViewController.canSendMail()
                state.messageToBeShared = nil
                state.supportData = nil
                state.isSwap = userMetadataProvider.isSwapTransaction(state.transaction.zAddress ?? "")
                state.umSwapId = userMetadataProvider.swapDetailsForTransaction(state.transaction.zAddress ?? "")
                state.hasInteractedWithBookmark = false
                state.areDetailsExpanded = state.transaction.isShieldingTransaction
                state.messageStates = []
                state.alias = nil
                if !state.isSwap {
                    for contact in state.addressBookContacts.contacts {
                        if contact.address == state.transaction.address {
                            state.alias = contact.name
                            break
                        }
                    }
                }
                state.areMessagesResolved = false
                state.isBookmarked = userMetadataProvider.isBookmarked(state.transaction.id)
                state.annotation = userMetadataProvider.annotationFor(state.transaction.id) ?? ""
                state.annotationOrigin = state.annotation
                state.areMessagesResolved = !state.memos.isEmpty
                if state.memos.isEmpty {
                    return .merge(
                        .send(.resolveMemos),
                        .send(.observeTransactionChange)
                    )
                }
                return .send(.observeTransactionChange)
                
            case .onDisappear:
                // __LD2 TESTED
                if state.hasInteractedWithBookmark {
                    if let account = state.selectedWalletAccount?.account {
                        try? userMetadataProvider.store(account)
                    }
                }
                return .merge(
                    .cancel(id: state.CancelId),
                    .cancel(id: state.SwapDetailsCancelId)
                )
                
            case .swapAssetsFailedWithRetry(let retry):
                state.swapAssetFailedWithRetry = retry
                return .none
                
            case .trySwapsAssetsAgainTapped:
                return .send(.checkSwapAssets)
                
            case .observeTransactionChange:
                if state.transaction.isPending {
                    return .merge(
                        .publisher {
                            state.$transactions.publisher
                                .map { _ in
                                    TransactionDetails.Action.transactionsUpdated
                                }
                        }
                            .cancellable(id: state.CancelId, cancelInFlight: true),
                        .send(.checkSwapAssets)
                    )
                }
                return .send(.checkSwapAssets)
                
            case .checkSwapAssets:
                guard state.swapAssets.isEmpty else {
                    return .send(.checkSwapStatus)
                }
                return .run { send in
                    do {
                        let swapAssets = try await swapAndPay.swapAssets()
                        await send(.swapAssetsLoaded(swapAssets))
                    } catch let error as NetworkError {
                        await send(.swapAssetsFailedWithRetry(error.allowsRetry))
                    } catch { }
                }
                
            case .swapAssetsLoaded(let swapAssets):
                state.swapAssetFailedWithRetry = nil
                // exclude all tokens with price == 0
                let filteredSwapAssets = swapAssets.filter { $0.usdPrice != 0 }

                state.$swapAssets.withLock { $0 = filteredSwapAssets }
                return .send(.checkSwapStatus)
                
            case .checkSwapStatus:
                //return .none
                guard state.isSwap else {
                    return .none
                }
                return .run { [address = state.transaction.address, isSwapToZec = state.transaction.isSwapToZec] send in
                    let swapDetails = try? await swapAndPay.status(address, isSwapToZec)
                    await send(.swapDetailsLoaded(swapDetails))
                    
                    // fire another check if not done
                    if let status = swapDetails?.status, status.isPending {
                        try? await mainQueue.sleep(for: .seconds(10))
                        await send(.checkSwapStatus)
                    }
                }
                .cancellable(id: state.SwapDetailsCancelId, cancelInFlight: true)
                
            case .swapDetailsLoaded(let swapDetails):
                state.swapDetails = swapDetails
                return .send(.compareAndUpdateMetadataOfSwap)
                
            case .transactionsUpdated:
                if let index = state.transactions.index(id: state.transaction.id) {
                    let transaction = state.transactions[index]
                    if state.transaction != transaction {
                        state.transaction = transaction
                    }
                    if !transaction.isPending {
                        return .cancel(id: state.CancelId)
                    }
                }
                return .none
                
            case .binding(\.annotation):
                if state.annotation.count > TransactionDetails.State.Constants.annotationMaxLength {
                    state.annotation = String(state.annotation.prefix(TransactionDetails.State.Constants.annotationMaxLength))
                }
                return .none
                
            case .binding:
                return .none
                
            case .closeDetailTapped:
                return .none
                
            case .deleteNoteTapped:
                userMetadataProvider.deleteAnnotationFor(state.transaction.id)
                state.annotation = userMetadataProvider.annotationFor(state.transaction.id) ?? ""
                state.annotationRequest = false
                if let account = state.selectedWalletAccount?.account {
                    try? userMetadataProvider.store(account)
                }
                return .none
                
            case .saveNoteTapped, .addNoteTapped:
                userMetadataProvider.addAnnotationFor(state.annotationToInput, state.transaction.id)
                state.annotation = userMetadataProvider.annotationFor(state.transaction.id) ?? ""
                state.annotationOrigin = ""
                state.annotationRequest = false
                if let account = state.selectedWalletAccount?.account {
                    try? userMetadataProvider.store(account)
                }
                return .none
                
            case .resolveMemos:
                if let rawID = state.transaction.rawID {
                    return .run { send in
                        if let memos = try? await sdkSynchronizer.getMemos(rawID) {
                            await send(.memosLoaded(memos))
                        }
                    }
                }
                state.areMessagesResolved = true
                return .none
                
            case .memosLoaded(let memos):
                state.areMessagesResolved = true
                state.$transactionMemos.withLock {
                    $0[state.transaction.id] = memos.compactMap { $0.toString() }
                }
                state.messageStates = state.memos.map {
                    $0.count < State.Constants.messageExpandThreshold ? .short : .longCollapsed
                }
                return .none
                
            case .noteButtonTapped:
                state.isEditMode = !state.annotation.isEmpty
                state.annotationOrigin = state.annotation
                state.annotationToInput = state.annotation
                state.annotationRequest = true
                return .none
                
            case .bookmarkTapped:
                state.hasInteractedWithBookmark = true
                userMetadataProvider.toggleBookmarkFor(state.transaction.id)
                state.isBookmarked = userMetadataProvider.isBookmarked(state.transaction.id)
                return .none
                
            case .messageTapped(let index):
                if index < state.messageStates.count && state.messageStates[index] != .short {
                    if state.messageStates[index] == .longExpanded {
                        state.messageStates[index] = .longCollapsed
                    } else {
                        state.messageStates[index] = .longExpanded
                    }
                }
                return .none
                
            case .saveAddressTapped:
                return .none
                
            case .sendAgainTapped:
                return .none
                
                //            case .sentToRowTapped:
                //                state.areDetailsExpanded.toggle()
                //                return .none
                
            case .addressTapped:
                pasteboard.setString(state.transaction.address.redacted)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                return .none
                
            case .transactionIdTapped:
                pasteboard.setString(state.transaction.id.redacted)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                return .none
                
            case .swapRecipientTapped:
                if let recipient = state.swapRecipient {
                    pasteboard.setString(recipient.redacted)
                    state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                }
                return .none
                
            case .showHideButtonTapped:
                state.areDetailsExpanded.toggle()
                return .none
                
            case .compareAndUpdateMetadataOfSwap:
                guard let umSwapId = state.umSwapId, let swapDetails = state.swapDetails else {
                    return .none
                }
                
                var needsUpdate = false
                
                // from asset
                if let fromAsset = state.swapAssets.filter({ $0.assetId == swapDetails.fromAsset }).first {
                    if umSwapId.fromAsset != fromAsset.id {
                        needsUpdate = true
                        state.umSwapId?.fromAsset = fromAsset.id
                    }
                }
                // to asset
                if let toAsset = state.swapAssets.filter({ $0.assetId == swapDetails.toAsset }).first {
                    if umSwapId.toAsset != toAsset.id {
                        needsUpdate = true
                        state.umSwapId?.toAsset = toAsset.id
                    }
                }
                // swap vs. pay update
                if umSwapId.exactInput != swapDetails.isSwap {
                    needsUpdate = true
                    state.umSwapId?.exactInput = swapDetails.isSwap
                }
                // amountOutFormatted
                if let amountOutFormattedValue = swapDetails.amountOutFormatted, swapDetails.isSwapToZec {
                    let amountOutFormatted = "\(amountOutFormattedValue)"
                    if umSwapId.amountOutFormatted != amountOutFormatted {
                        needsUpdate = true
                        state.umSwapId?.amountOutFormatted = amountOutFormatted
                        if let localeString = amountOutFormatted.localeString {
                            state.transaction.swapToZecAmount = localeString
                        }
                    }
                }
                // status
                if umSwapId.status != swapDetails.status.rawName {
                    needsUpdate = true
                    state.umSwapId?.status = swapDetails.status.rawName
                }
                // update of metadata needed
                if let account = state.selectedWalletAccount?.account, let umSwapId = state.umSwapId, needsUpdate {
                    userMetadataProvider.update(umSwapId)
                    try? userMetadataProvider.store(account)
                    state.transaction.checkAndUpdateWith(umSwapId)
                    state.$transactions.withLock { $0[id: state.transaction.id] = state.transaction }
                    return .none
                }
                return .none
                
            case .contactSupportTapped:
                state.isReportSwapSheetEnabled = true
                return .none
                
            case .reportSwapTapped:
                state.isReportSwapSheetEnabled = false
                return .run { send in
                    try? await Task.sleep(for: .seconds(0.3))
                    await send(.reportSwapRequested)
                }
                
            case .reportSwapRequested:
                var prefixMessage = "\(String(localizable: .reportSwapPlease))\n\n\n"
                prefixMessage += "\(String(localizable: .reportSwapSwapDetails))\n"
                prefixMessage += "\(String(localizable: .reportSwapDepositAddress)) \(state.transaction.address)\n"
                prefixMessage += String(localizable: .reportSwapSourceAsset(state.swapFromAsset?.token ?? "", state.swapFromAsset?.chainName ?? ""))
                prefixMessage += String(localizable: .reportSwapTargetAsset(state.swapToAsset?.token ?? "", state.swapToAsset?.chainName ?? ""))

                if state.canSendMail {
                    state.supportData = SupportDataGenerator.generate(prefixMessage)
                    return .none
                } else {
                    let sharePrefix =
                    """
                    ===
                    \(String(localizable: .sendFeedbackShareNotAppleMailInfo)) \(SupportDataGenerator.Constants.email)
                    ===
                    
                    \(prefixMessage)
                    """
                    let supportData = SupportDataGenerator.generate(sharePrefix)
                    state.messageToBeShared = supportData.message
                }
                return .none
                
            case .sendSupportMailFinished:
                state.supportData = nil
                return .none

            case .shareFinished:
                state.messageToBeShared = nil
                return .none
            }
        }
    }
}

extension TransactionDetails.State {
    var slippageFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale.current
        
        return formatter
    }
    
    var conversionFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 8
        formatter.usesGroupingSeparator = false
        formatter.locale = Locale.current
        
        return formatter
    }
    
    var swapStatus: SwapBadge.Status? {
        guard let status = swapDetails?.status else {
            return nil
        }
        
        switch status {
        case .pending: return .pending
        case .refunded: return .refunded
        case .success: return .success
        case .pendingDeposit: return .pendingDeposit
        case .incompleteDeposit: return .incompleteDeposit
        case .failed: return .failed
        case .processing: return .processing
        case .expired: return .expired
        }
    }

    var swapSlippage: String? {
        guard let slippage = swapDetails?.slippage else {
            return nil
        }
        
        let value = slippageFormatter.string(from: NSDecimalNumber(decimal: slippage)) ?? ""
        
        return "\(value)%"
    }
    
    var swapAmountIn: String? {
        guard let amountInFormatted = swapDetails?.amountInFormatted else {
            return nil
        }
        
        return conversionFormatter.string(from: NSDecimalNumber(decimal: amountInFormatted))
    }
    
    var swapAmountInUsd: String? {
        swapDetails?.amountInUsd?.localeUsd
    }
    
    var swapAmountOut: String? {
        guard let amountOutFormatted = swapDetails?.amountOutFormatted else {
            return nil
        }
        
        return conversionFormatter.string(from: NSDecimalNumber(decimal: amountOutFormatted))
    }
    
    var swapAmountOutUsd: String? {
        swapDetails?.amountOutUsd?.localeUsd
    }
    
    var swapIsSwap: Bool {
        swapDetails?.isSwap ?? false
    }
    
    var swapFromAsset: SwapAsset? {
        guard !swapAssets.isEmpty else {
            return nil
        }
        
        guard swapAmountOut != nil else {
            return nil
        }
        
        guard let swapDetailsFromAssetId = swapDetails?.fromAsset?.lowercased() else {
            return nil
        }
        
        return swapAssets.first { $0.assetId.lowercased() == swapDetailsFromAssetId }
    }
    
    var swapToAsset: SwapAsset? {
        guard !swapAssets.isEmpty else {
            return nil
        }
        
        guard swapAmountOut != nil else {
            return nil
        }
        
        guard let swapDetailsToAssetId = swapDetails?.toAsset?.lowercased() else {
            return nil
        }
        
        return swapAssets.first { $0.assetId.lowercased() == swapDetailsToAssetId }
    }
    
    var refundedAmount: String? {
        guard let refundedAmountFormatted = swapDetails?.refundedAmountFormatted else {
            return nil
        }
        
        return conversionFormatter.string(from: NSDecimalNumber(decimal: refundedAmountFormatted)) ?? ""
    }
    
    var swapRecipient: String? {
        swapDetails?.swapRecipient
    }
    
    var totalSwapToZecFee: String? {
        guard let amountIn = swapDetails?.amountInFormatted else {
            return nil
        }
        
        let fee = amountIn * 0.005
        
        return conversionFormatter.string(from: NSDecimalNumber(decimal: fee)) ?? ""
    }
    
    var totalSwapToZecFeeAssetName: String? {
        guard let toAssetId = swapDetails?.fromAsset else {
            return nil
        }
        
        let asset = swapAssets.first { $0.assetId == toAssetId }
        return asset?.token ?? nil
    }
    
    var swapToZecFeeInProgress: Bool {
        guard let swapStatus else {
            return true
        }
        
        return !(swapStatus == .success)
    }

    var missingFunds: String? {
        guard let amountInFormatted = swapDetails?.amountInFormatted else {
            return nil
        }

        guard let depositedAmountFormatted = swapDetails?.depositedAmountFormatted else {
            return nil
        }

        return conversionFormatter.string(from: NSDecimalNumber(decimal: amountInFormatted - depositedAmountFormatted))
    }
}
