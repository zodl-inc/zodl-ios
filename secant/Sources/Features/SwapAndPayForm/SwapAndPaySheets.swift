//
//  SwapAndPaySheets.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-05-26.
//

import UIKit
import SwiftUI
import ComposableArchitecture

extension SwapAndPayForm {
    @ViewBuilder func assetsLoadingComposition(_ colorScheme: ColorScheme) -> some View {
        List {
            WithPerceptionTracking {
                ForEach(0..<15) { _ in
                    NoTransactionPlaceholder(true)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Asset.Colors.background.color)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .disabled(true)
        .padding(.vertical, 1)
        .background(Asset.Colors.background.color)
        .listStyle(.plain)
    }
    
    @ViewBuilder func assetsEmptyComposition(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<5) { _ in
                        NoTransactionPlaceholder()
                    }
                    
                    Spacer()
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: .clear, location: 0.0),
                            Gradient.Stop(color: Asset.Colors.background.color, location: 0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                
                VStack(spacing: 0) {
                    Asset.Assets.Illustrations.emptyState.image
                        .resizable()
                        .frame(width: 164, height: 164)
                        .padding(.bottom, 20)
                    
                    Text(localizable: .swapAndPayEmptyAssetsTitle)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .padding(.bottom, 8)
                    
                    Text(localizable: .swapAndPayEmptyAssetsSubtitle)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .padding(.bottom, 20)
                }
                .padding(.top, 40)
            }
        }
    }
    
    @ViewBuilder func assetsFailureComposition(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<5) { _ in
                        NoTransactionPlaceholder()
                    }
                    
                    Spacer()
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: .clear, location: 0.0),
                            Gradient.Stop(color: Asset.Colors.background.color, location: 0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                
                VStack(alignment: .center, spacing: 0) {
                    Asset.Assets.Illustrations.cone.image
                        .zImage(size: 164, style: Design.Text.primary)
                        .padding(.bottom, 20)
                    
                    Text(localizable: .swapAndPayFailureWrong)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .padding(.bottom, 8)
                    
                    Text(localizable: .swapAndPayFailureWrongDesc)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .padding(.bottom, 20)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .screenHorizontalPadding()
                    
                    if let retryFailure = store.swapAssetFailedWithRetry, retryFailure {
                        ZashiButton(
                            String(localizable: .swapAndPayFailureTryAgain),
                            type: .tertiary,
                            infinityWidth: false
                        ) {
                            store.send(.trySwapsAssetsAgainTapped)
                        }
                    }
                }
            }
        }
    }
    /// The sub-$300 refund warning (MOB-1889). One sheet serves all three surfaces; only the
    /// noun in the body changes, and which suppression flag Continue writes is decided in the
    /// reducer.
    @ViewBuilder func refundWarningSheetContent(_ colorScheme: ColorScheme) -> some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Icons.alertTriangle.image
                    .zImage(size: 20, style: Design.Utility.WarningYellow._500)
                    .background {
                        Circle()
                            .fill(Design.Utility.WarningYellow._50.color(colorScheme))
                            .frame(width: 44, height: 44)
                    }
                    .padding(.top, 48)
                    .padding(.leading, 12)

                Text(localizable: .swapAndPayRefundWarningTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                Text(
                    store.refundWarningSurface == .crossPay
                    ? String(localizable: .swapAndPayRefundWarningPayMessage)
                    : String(localizable: .swapAndPayRefundWarningSwapMessage)
                )
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .padding(.bottom, 20)

                ZashiToggle(
                    isOn: $store.refundWarningDontShowAgain,
                    label: String(localizable: .swapAndPayRefundWarningDontShowAgain)
                )
                .accessibilityIdentifier(AccessibilityID.RefundWarning.dontShowAgainToggle)
                .padding(.bottom, 24)

                ZashiButton(
                    String(localizable: .generalCancel),
                    type: .secondary
                ) {
                    store.send(.refundWarningCancelTapped)
                }
                .accessibilityIdentifier(AccessibilityID.RefundWarning.cancelButton)
                .padding(.bottom, 8)

                ZashiButton(String(localizable: .generalContinue)) {
                    store.send(.refundWarningContinueTapped)
                }
                .accessibilityIdentifier(AccessibilityID.RefundWarning.continueButton)
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
    }
}

struct FocusableTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    var placeholder: String = ""
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField()
        textField.delegate = context.coordinator
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: UIColor(Design.Switcher.selectedText.color(colorScheme)),
                .font: FontFamily.Inter.medium.font(size: 16)
            ]
        )
        textField.textAlignment = .center
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.keyboardType = .decimalPad
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        textField.font = FontFamily.Inter.medium.font(size: 16)
        textField.textColor = UIColor(Design.Switcher.selectedText.color(colorScheme))

        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        uiView.text = text

        if isFirstResponder && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFirstResponder: $isFirstResponder)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        @Binding var isFirstResponder: Bool

        init(text: Binding<String>, isFirstResponder: Binding<Bool>) {
            _text = text
            _isFirstResponder = isFirstResponder
        }

        @objc func textDidChange(_ textField: UITextField) {
            text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isFirstResponder = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isFirstResponder = false
        }
    }

}
