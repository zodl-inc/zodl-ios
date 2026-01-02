//
//  TransactionDetailsView.swift
//  Zashi
//
//  Created by Lukáš Korba on 01-08-2024
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import Models
import ZcashLightClientKit

struct CustomRoundedRectangle: Shape {
    var corners: UIRectCorner
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

public struct TransactionDetailsView: View {
    enum RowAppereance {
        case bottom
        case full
        case middle
        case top
        
        var corners: UIRectCorner {
            switch self {
            case .bottom:
                return [.bottomLeft, .bottomRight]
            case .full:
                return [.allCorners]
            case .middle:
                return []
            case .top:
                return [.topLeft, .topRight]
            }
        }
    }

    @Environment(\.colorScheme) var colorScheme

    @FocusState var isAnnotationFocused

    @Perception.Bindable var store: StoreOf<TransactionDetails>
    let tokenName: String

    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false
    @Shared(.inMemory(.walletStatus)) public var walletStatus: WalletStatus = .none

    public init(store: StoreOf<TransactionDetails>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if store.transaction.isNonZcashActivity {
                    headerViewSwapToZec()
                        .screenHorizontalPadding()
                } else {
                    headerView()
                        .screenHorizontalPadding()
                }
                
                ScrollView {
                    if store.isSwap {
                        swapAssetsView()
                            .padding(.bottom, 12)
                    }

                    if store.transaction.isSentTransaction {
                        transactionDetailsList()
                            .padding(.bottom, store.isSwap ? 0 : 20)
                            .screenHorizontalPadding()
                        
                        if store.areMessagesResolved && !store.transaction.isShieldingTransaction {
                            if !store.memos.isEmpty {
                                messageViews()
                                    .screenHorizontalPadding()
                            } else if !store.transaction.isTransparentRecipient {
                                noMessageView()
                                    .padding(.bottom, 20)
                                    .screenHorizontalPadding()
                            }
                        }
                    } else {
                        if store.areMessagesResolved {
                            if !store.transaction.isTransparentRecipient && !store.transaction.isShieldingTransaction && !store.transaction.hasTransparentOutputs {
                                if store.memos.isEmpty {
                                    noMessageView()
                                        .padding(.bottom, 20)
                                        .screenHorizontalPadding()
                                } else {
                                    messageViews()
                                        .padding(.bottom, 20)
                                        .screenHorizontalPadding()
                                }
                            }
                        }

                        transactionDetailsList()
                            .screenHorizontalPadding()
                    }

                    if store.isSwap && store.swapStatus == .refunded {
                        swapRefundInfoView()
                    }
                }
                .padding(.vertical, 1)
                
                Spacer()
                
                if let retryFailure = store.swapAssetFailedWithRetry, store.transaction.isNonZcashActivity {
                    VStack(alignment: .center, spacing: 0) {
                        Asset.Assets.infoOutline.image
                            .zImage(size: 16, style: Design.Text.error)
                            .padding(.bottom, 8)
                            .padding(.top, 32)
                        
                        Text(retryFailure
                             ? L10n.SwapAndPay.Failure.retryTitle
                             : L10n.SwapAndPay.Failure.laterTitle
                        )
                        .zFont(.medium, size: 14, style: Design.Text.error)
                        .padding(.bottom, 8)
                        
                        Text(retryFailure
                             ? L10n.SwapAndPay.Failure.retryDesc
                             : L10n.SwapAndPay.Failure.laterDesc
                        )
                        .zFont(size: 14, style: Design.Text.error)
                        .padding(.bottom, 24)
                        
                        if retryFailure {
                            ZashiButton(
                                L10n.SwapAndPay.Failure.tryAgain,
                                type: .destructive1
                            ) {
                                store.send(.trySwapsAssetsAgainTapped)
                            }
                            .padding(.bottom, 24)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .screenHorizontalPadding()
                } else if !store.transaction.isSwapToZec {
                    HStack(spacing: 12) {
                        ZashiButton(
                            store.annotation.isEmpty
                            ? L10n.Annotation.addArticle
                            : L10n.Annotation.edit,
                            type: .tertiary
                        ) {
                            store.send(.noteButtonTapped)
                        }
                        
                        if store.transaction.isSentTransaction && !store.transaction.isShieldingTransaction && !store.isSwap {
                            if store.alias == nil {
                                ZashiButton(L10n.TransactionHistory.saveAddress) {
                                    store.send(.saveAddressTapped)
                                }
                            } else {
                                ZashiButton(L10n.TransactionHistory.sendAgain) {
                                    store.send(.sendAgainTapped)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                    .screenHorizontalPadding()
                }
            }
            .zashiBack(hidden: store.isCloseButtonRequired) {
                store.send(.closeDetailTapped)
            }
            .zashiBackV2(hidden: !store.isCloseButtonRequired) {
                store.send(.closeDetailTapped)
            }
            .navigationBarItems(
                trailing:
                    HStack(spacing: 0) {
                        hideBalancesButton()
                        bookmarkButton()
                    }
            )
            .onAppear { store.send(.onAppear) }
            .onDisappear { store.send(.onDisappear) }
            .zashiSheet(isPresented: $store.annotationRequest) {
                annotationContent(store.isEditMode)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyDefaultGradientScreenBackground()
    }
}

extension TransactionDetailsView {
    @ViewBuilder func bookmarkButton() -> some View {
        Button {
            store.send(.bookmarkTapped)
        } label: {
            if store.isBookmarked {
                Asset.Assets.Icons.bookmarkCheck.image
                    .zImage(size: 32, style: Design.Text.primary)
                    .padding(4)
                    .tint(Asset.Colors.primary.color)
            } else {
                Asset.Assets.Icons.bookmark.image
                    .zImage(size: 32, style: Design.Text.primary)
                    .padding(4)
                    .tint(Asset.Colors.primary.color)
            }
        }
    }
}

// Header
extension TransactionDetailsView {
    func transationIcon() -> Image {
        store.transaction.transationIcon
    }
    
    @ViewBuilder func headerView() -> some View {
        VStack(alignment: .center, spacing: 0) {
            HStack(spacing: 0) {
                Circle()
                    .frame(width: 48, height: 48)
                    .zForegroundColor(Design.Surfaces.brandPrimary)
                    .overlay {
                        Circle()
                            .frame(width: 51, height: 51)
                            .offset(x: 42)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .overlay {
                        ZcashSymbol()
                            .frame(width: 34, height: 34)
                            .foregroundColor(Asset.Colors.secondary.color)
                    }
                
                RoundedRectangle(cornerRadius: Design.Radius._4xl)
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                    .frame(width: 48, height: 48)
                    .overlay {
                        transationIcon()
                            .zImage(size: 24, style: Design.Text.primary)
                    }
                    .offset(x: -4)
            }
            .offset(x: 2)
            .padding(.top, 24)

            Text(store.transaction.title)
                .zFont(.medium, size: 18, style: Design.Text.tertiary)
                .padding(.top, 10)
            
            Group {
                if store.isSensitiveContentHidden {
                    Text(L10n.General.hideBalancesMost)
                } else if store.transaction.isSwapToZec {
                    if let amount = store.swapAmountOut {
                        Text(amount)
                        + Text(" \(tokenName)")
                            .foregroundColor(Design.Text.quaternary.color(colorScheme))
                    } else {
                        unknownAmount()
                            .padding(.vertical, 2)
                    }
                } else {
                    Text(store.transaction.netValue)
                    + Text(" \(tokenName)")
                        .foregroundColor(Design.Text.quaternary.color(colorScheme))
                }
            }
            .zFont(.semiBold, size: 40, style: Design.Text.primary)
            .minimumScaleFactor(0.1)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }
    
    @ViewBuilder func headerViewSwapToZec() -> some View {
        VStack(alignment: .center, spacing: 0) {
            HStack(spacing: 0) {
                // FROM asset
                if let swapFromAsset = store.swapFromAsset {
                    swapFromAsset.tokenIcon
                        .resizable()
                        .frame(width: 48, height: 48)
                        .overlay {
                            Circle()
                                .frame(width: 51, height: 51)
                                .offset(x: 42)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                } else {
                    unknownAsset()
                        .overlay {
                            Circle()
                                .frame(width: 51, height: 51)
                                .offset(x: 42)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }

                // SWAP icon
                RoundedRectangle(cornerRadius: Design.Radius._4xl)
                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Circle()
                            .frame(width: 51, height: 51)
                            .offset(x: 42)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .overlay {
                        store.transaction.transationIcon
                        //Asset.Assets.Icons.swapTransaction.image
                            .zImage(size: 24, style: Design.Text.primary)
                    }
                    .offset(x: -4)

                // TO asset
                if let swapToAsset = store.swapToAsset {
                    swapToAsset.tokenIcon
                        .resizable()
                        .frame(width: 48, height: 48)
                        .offset(x: -8)
                } else {
                    unknownAsset()
                        .offset(x: -8)
                }
                
//                // ZEC icon
//                Asset.Assets.Brandmarks.brandmarkMax.image
//                    .zImage(size: 48, style: Design.Surfaces.brandPrimary)
//                    .offset(x: -8)
            }
            .offset(x: 4)
            .padding(.top, 24)

//            if let swapTitle = store.swapToZecTitle, (store.transaction.type == .swapToZec || store.transaction.type == .swapFromZec) {
            if !store.transaction.title.isEmpty {
                Text(store.transaction.title)
                    .zFont(.medium, size: 18, style: Design.Text.tertiary)
                    .padding(.top, 10)
            } else {
                unknownValue()
                    .padding(.top, 10)
            }
            
//            Group {
//                if store.isSensitiveContentHidden {
//                    Text(L10n.General.hideBalancesMost)
//                } else {
//                    if let amount = store.swapAmountOut {
//                        Text(amount)
//                        + Text(" \(tokenName)")
//                            .foregroundColor(Design.Text.quaternary.color(colorScheme))
//                    } else {
//                        unknownAmount()
//                            .padding(.vertical, 2)
//                    }
//                }
//            }
            Group {
                if store.isSensitiveContentHidden {
                    Text(L10n.General.hideBalancesMost)
                } else if store.transaction.isSwapToZec {
                    if let amount = store.swapAmountOut {
                        Text(amount)
                        + Text(" \(tokenName)")
                            .foregroundColor(Design.Text.quaternary.color(colorScheme))
                    } else {
                        unknownAmount()
                            .padding(.vertical, 2)
                    }
                } else {
                    Text(store.transaction.netValue)
                    + Text(" \(tokenName)")
                        .foregroundColor(Design.Text.quaternary.color(colorScheme))
                }
            }
            .zFont(.semiBold, size: 40, style: Design.Text.primary)
            .minimumScaleFactor(0.1)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }

    @ViewBuilder func transactionDetailsTitle() -> some View {
        HStack(spacing: 0) {
            Text(
                store.transaction.isSwapToZec
                ? L10n.SwapToZec.swapDetails
                : L10n.TransactionHistory.details
            )
            .zFont(.medium, size: 14, style: Design.Text.tertiary)
            .padding(.bottom, 8)
            
            Spacer()
            
            if store.transaction.isSentTransaction && !store.transaction.isShieldingTransaction {
                if store.areDetailsExpanded {
                    ZashiButton(
                        L10n.General.less,
                        type: .tertiary,
                        infinityWidth: false,
                        fontSize: 14,
                        horizontalPadding: 12,
                        verticalPadding: 8,
                        accessoryView:
                            Asset.Assets.chevronDown.image
                            .zImage(size: 20, style: Design.Btns.Tertiary.fg)
                            .rotationEffect(Angle(degrees: 180))
                    ) {
                        store.send(.showHideButtonTapped, animation: .easeInOut)
                    }
                } else {
                    ZashiButton(
                        L10n.General.more,
                        type: .tertiary,
                        infinityWidth: false,
                        fontSize: 14,
                        horizontalPadding: 12,
                        verticalPadding: 8,
                        accessoryView:
                            Asset.Assets.chevronDown.image
                            .zImage(size: 20, style: Design.Btns.Tertiary.fg)
                    ) {
                        store.send(.showHideButtonTapped, animation: .easeInOut)
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder func transactionDetailsList() -> some View {
        WithPerceptionTracking {
            LazyVStack(alignment: .leading, spacing: 0) {
                transactionDetailsTitle()

                if store.isSwap {
                    detailAnyView(
                        title: L10n.SwapAndPay.status,
                        rowAppereance: .top
                    ) {
                        if let status = store.swapStatus {
                            SwapBadge(status)
                        } else {
                            RoundedRectangle(cornerRadius: Design.Radius._sm)
                                .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                                .shimmer(true).clipShape(RoundedRectangle(cornerRadius: Design.Radius._sm))
                                .frame(width: 72, height: 20)
                        }
                    }
                }

                if store.transaction.isSentTransaction && !store.transaction.isShieldingTransaction {
                    detailView(
                        title: store.transaction.isSwapToZec
                        ? L10n.SwapToZec.depositTo
                        : L10n.TransactionHistory.sentTo,
                        value: isSensitiveContentHidden
                        ? L10n.General.hideBalancesMost
                        : store.alias ?? store.transaction.address.zip316,
                        icon: Asset.Assets.copy.image,
                        rowAppereance: store.isSwap
                        ? (
                            (!store.annotation.isEmpty || !store.areDetailsExpanded) ? .bottom : .middle
                        )
                        : (!store.annotation.isEmpty || store.areDetailsExpanded) ? .top : .full
                    )
                    .onTapGesture {
                        store.send(.addressTapped)
                    }
                }

                if store.areDetailsExpanded || !store.transaction.isSentTransaction {
                    if let recipient = store.swapRecipient, store.isSwap {
                        detailView(
                            title: L10n.SwapAndPay.recipient,
                            value: isSensitiveContentHidden
                            ? L10n.General.hideBalancesMost
                            : recipient.zip316,
                            icon: Asset.Assets.copy.image,
                            rowAppereance: .middle
                        )
                        .onTapGesture {
                            store.send(.swapRecipientTapped)
                        }
                    }
                    
                    if !store.transaction.isSwapToZec {
                        detailView(
                            title: L10n.TransactionList.transactionId,
                            value: isSensitiveContentHidden
                            ? L10n.General.hideBalancesMost
                            : store.transaction.id.truncateMiddle,
                            icon: Asset.Assets.copy.image,
                            rowAppereance: (store.transaction.isSentTransaction && !store.transaction.isShieldingTransaction) ? .middle : .top
                        )
                        .onTapGesture {
                            store.send(.transactionIdTapped)
                        }
                    }

                    if store.transaction.isSentTransaction {
                        if store.isSensitiveContentHidden {
                            detailView(
                                title: L10n.Send.feeSummary,
                                value: L10n.General.hideBalancesMost,
                                rowAppereance: .middle
                            )
                        } else {
                            if store.transaction.isSwapToZec {
                                detailAnyView(
                                    title: L10n.SwapAndPay.totalFees,
                                    rowAppereance: .middle
                                ) {
                                    if let fee = store.totalSwapToZecFee, let assetName = store.totalSwapToZecFeeAssetName {
                                        Text("~\(fee) \(assetName)")
                                            .zFont(.medium, size: 14, style: Design.Text.primary)
                                            .frame(height: 20)
                                    } else {
                                        RoundedRectangle(cornerRadius: Design.Radius._sm)
                                            .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                                            .shimmer(true).clipShape(RoundedRectangle(cornerRadius: Design.Radius._sm))
                                            .frame(width: 86, height: 20)
                                    }
                                }
                            } else {
                                if let totalFeesStr = store.totalFeesStr {
                                    detailView(
                                        title: L10n.SwapAndPay.totalFees,
                                        value: "\(totalFeesStr) \(tokenName)",
                                        rowAppereance: .middle
                                    )
                                } else {
                                    if store.transaction.fee == nil {
                                        detailView(
                                            title: L10n.Send.feeSummary,
                                            value: "\(L10n.General.feeShort(store.feeStr)) \(tokenName)",
                                            rowAppereance: .middle
                                        )
                                    } else {
                                        detailView(
                                            title: L10n.Send.feeSummary,
                                            value: "\(store.feeStr) \(tokenName)",
                                            rowAppereance: .middle
                                        )
                                    }
                                }
                            }
                        }
                    }
                    
                    if store.isSwap {
                        detailAnyView(
                            title: store.swapStatus == .success
                            ? L10n.SwapAndPay.executedSlippage
                            : L10n.SwapAndPay.maxSlippageTitle,
                            rowAppereance: .middle
                        ) {
                            if let slippage = store.swapSlippage {
                                Text(slippage)
                                    .zFont(.medium, size: 14, style: Design.Text.primary)
                                    .frame(height: 20)
                            } else {
                                RoundedRectangle(cornerRadius: Design.Radius._sm)
                                    .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                                    .shimmer(true).clipShape(RoundedRectangle(cornerRadius: Design.Radius._sm))
                                    .frame(width: 86, height: 20)
                            }
                        }
                        
                        if store.swapStatus == .refunded {
                            detailAnyView(
                                title: L10n.SwapAndPay.refundedAmount,
                                rowAppereance: .middle
                            ) {
                                if let refundedAmount = store.refundedAmount {
                                    Text("\(refundedAmount) \(tokenName)")
                                        .zFont(.medium, size: 14, style: Design.Text.primary)
                                        .frame(height: 20)
                                } else {
                                    RoundedRectangle(cornerRadius: Design.Radius._sm)
                                        .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                                        .shimmer(true).clipShape(RoundedRectangle(cornerRadius: Design.Radius._sm))
                                        .frame(width: 86, height: 20)
                                }
                            }
                        }
                    }

                    detailView(
                        title: L10n.TransactionHistory.timestamp,
                        value: isSensitiveContentHidden
                        ? L10n.General.hideBalancesMost
                        : store.transaction.listDateYearString ?? L10n.TransactionHistory.pending,
                        rowAppereance: store.annotation.isEmpty ? .bottom : .middle
                    )
                }
                
                noteView()
            }
        }
    }

    @ViewBuilder func noteView() -> some View {
        if !store.annotation.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.Annotation.title)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .padding(.bottom, 4)
                
                Text(store.annotation)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .screenHorizontalPadding()
            .background {
                CustomRoundedRectangle(corners: RowAppereance.bottom.corners, radius: 12)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
            }
        }
    }

    @ViewBuilder func detailView(
        title: String,
        value: String,
        icon: Image? = nil,
        rowAppereance: RowAppereance = .full
    ) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .zFont(size: 14, style: Design.Text.tertiary)
            
            Spacer()
            
            Text(value)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            
            if let icon {
                icon
                    .zImage(size: 20, style: Design.Text.primary)
                    .padding(.leading, 6)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background {
            CustomRoundedRectangle(corners: rowAppereance.corners, radius: 12)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
        .padding(.bottom, rowAppereance == .full || rowAppereance == .bottom ? 0 : 1)
    }

    @ViewBuilder func detailAnyView(
        title: String,
        rowAppereance: RowAppereance = .full,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .zFont(size: 14, style: Design.Text.tertiary)
            
            Spacer()
            
            content()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background {
            CustomRoundedRectangle(corners: rowAppereance.corners, radius: 12)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
        .padding(.bottom, rowAppereance == .full || rowAppereance == .bottom ? 0 : 1)
    }

    @ViewBuilder func messageViews() -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Send.message)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .padding(.bottom, 8)

                ForEach(0..<store.memos.count, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 0) {
                        if index < store.messageStates.count && store.messageStates[index] == .longExpanded {
                            Text("\(store.memos[index].prefix(TransactionDetails.State.Constants.messageExpandThreshold))...")
                                .zFont(size: 14, style: Design.Text.primary)
                        } else {
                            Text(store.memos[index])
                                .textSelection(.enabled)
                                .zFont(size: 14, style: Design.Text.primary)
                        }

                        if index < store.messageStates.count && store.messageStates[index] != .short {
                            HStack(spacing: 6) {
                                Text(index < store.messageStates.count && store.messageStates[index] == .longExpanded
                                     ? L10n.TransactionHistory.viewMore
                                     : L10n.TransactionHistory.viewLess
                                )
                                .zFont(.medium, size: 14, style: Design.Text.primary)
                                
                                
                                if index < store.messageStates.count && store.messageStates[index] == .longExpanded {
                                    Asset.Assets.chevronUp.image
                                        .zImage(size: 16, style: Design.Text.primary)
                                } else {
                                    Asset.Assets.chevronDown.image
                                        .zImage(size: 16, style: Design.Text.primary)
                                }
                            }
                            .padding(.top, 12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                            .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    }
                    .onTapGesture {
                        store.send(.messageTapped(index), animation: .easeInOut)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder func noMessageView() -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Send.message)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .padding(.bottom, 8)

                HStack(spacing: 0) {
                    Asset.Assets.Icons.noMessage.image
                        .zImage(size: 20, style: Design.Text.support)
                        .padding(.trailing, 8)
                    
                    Text(L10n.TransactionHistory.noMessage)
                        .zFont(size: 14, style: Design.Text.support)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder func hideBalancesButton() -> some View {
        Button {
            $isSensitiveContentHidden.withLock { $0.toggle() }
        } label: {
            let image = isSensitiveContentHidden ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image
            image
                .zImage(size: 24, color: Asset.Colors.primary.color)
                .padding(8)
        }
    }
}

// MARK: - Previews

#Preview {
    TransactionDetailsView(store: TransactionDetails.initial, tokenName: "ZEC")
}

// MARK: - Store

extension TransactionDetails {
    public static var initial = StoreOf<TransactionDetails>(
        initialState: .initial
    ) {
        TransactionDetails()
    }
}

// MARK: - Placeholders

extension TransactionDetails.State {
    public static let initial = TransactionDetails.State(transaction: .placeholder())
}
