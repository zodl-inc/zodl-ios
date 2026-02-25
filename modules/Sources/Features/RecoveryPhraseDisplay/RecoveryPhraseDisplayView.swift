//
//  RecoveryPhraseDisplayView.swift
//  Zashi
//
//  Created by Francisco Gindre on 10/26/21.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import MnemonicSwift
import Utils

public struct RecoveryPhraseDisplayView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    enum Constants {
        static let blurValue = 6.0
        static let blurBDValue = 7.0
    }

    @Perception.Bindable var store: StoreOf<RecoveryPhraseDisplay>

    public init(store: StoreOf<RecoveryPhraseDisplay>) {
        self.store = store
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if let _ = store.phrase?.words {
                    Text(L10n.RecoveryPhraseDisplay.title)

                    Text(L10n.RecoveryPhraseDisplay.description)
                        .zFont(size: 14, style: Design.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    
                    threeColumnSeed()
                        .padding(.top, 20)
                        .padding(.bottom, 8)

                    Spacer()
                    
                    if store.isRecoveryPhraseHidden {
                        ZashiButton(
                            L10n.RecoveryPhraseDisplay.reveal,
                            prefixView:
                                Asset.Assets.eyeOn.image
                                .zImage(size: 20, style: Design.Btns.Primary.fg)
                        ) {
                            store.send(.recoveryPhraseUnhideRequested, animation: .easeInOut)
                        }
                        .padding(.bottom, 24)
                    } else {
                        if store.isWalletBackup {
                            ZashiButton(
                                L10n.RecoveryPhraseDisplay.Button.remindMeLater,
                                type: .ghost
                            ) {
                                store.send(.remindMeLaterTapped)
                            }
                            .padding(.bottom, 8)
                            
                            ZashiButton(
                                L10n.RecoveryPhraseDisplay.Button.wroteItDown
                            ) {
                                store.send(.seedSavedTapped)
                            }
                            .padding(.bottom, 24)
                        } else {
                            ZashiButton(
                                L10n.RecoveryPhraseDisplay.hide,
                                prefixView:
                                    Asset.Assets.eyeOff.image
                                    .zImage(size: 20, style: Design.Btns.Primary.fg)
                            ) {
                                store.send(.recoveryPhraseTapped, animation: .easeInOut)
                            }
                            .padding(.bottom, 20)
                        }
                    }
                } else {
                    Text(L10n.RecoveryPhraseDisplay.noWords)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .padding(.top, 40)
                        .multilineTextAlignment(.center)
                }
            }
            .onAppear { store.send(.onAppear) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                store.send(.hideEverything)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                store.send(.hideEverything)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                store.send(.hideEverything)
            }
            .alert($store.scope(state: \.alert, action: \.alert))
            .zashiBack()
            .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                helpSheetContent()
            }
            .navigationBarItems(
                trailing:
                    Button {
                        store.send(
                            store.isRecoveryPhraseHidden || !store.isWalletBackup
                            ? .helpSheetRequested
                            : .recoveryPhraseTapped,
                            animation: .easeInOut
                        )
                    } label: {
                        if store.isRecoveryPhraseHidden || !store.isWalletBackup {
                            Asset.Assets.Icons.help.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(Design.Spacing.navBarButtonPadding)
                        } else {
                            Asset.Assets.eyeOff.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(Design.Spacing.navBarButtonPadding)
                        }
                    }
            )
        }
        .padding(.horizontal, 20)
        .applyScreenBackground()
        .screenTitle(L10n.RecoveryPhraseDisplay.screenTitle.uppercased())
    }
    
    @ViewBuilder func threeColumnSeed() -> some View {
        if let words = store.phrase?.words {
            VStack(spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(0..<8, id: \.self) { j in
                        GridRow {
                            ForEach(0..<3, id: \.self) { i in
                                HStack(spacing: 4) {
                                    Text("\(j * 3 + i + 1)")
                                        .zFont(.medium, size: 12, style: Design.Text.tertiary)
                                        .fixedSize()
                                        .lineLimit(1)
                                        .frame(minWidth: 18)

                                    Text("\(words[j * 3 + i].data)")
                                        .zFont(size: 16, style: Design.Text.primary)
                                        .minimumScaleFactor(0.5)
                                        .lineLimit(1)
                                        .blur(radius: store.isRecoveryPhraseHidden ? Constants.blurValue : 0)
                                    
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                                .padding(8)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                                }
                            }
                        }
                    }
                }
                .id("threeList")

                birthday()
            }
        }
    }
    
    @ViewBuilder func twoColumnSeed() -> some View {
        if let words = store.phrase?.words {
            VStack(spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(0..<12, id: \.self) { j in
                        GridRow {
                            ForEach(0..<2, id: \.self) { i in
                                HStack(spacing: 4) {
                                    Text("\(j * 2 + i + 1)")
                                        .zFont(.medium, size: 12, style: Design.Text.tertiary)
                                        .fixedSize()
                                        .lineLimit(1)
                                        .frame(minWidth: 18)

                                    Text("\(words[j * 2 + i].data)")
                                        .zFont(size: 16, style: Design.Text.primary)
                                        .fixedSize()
                                        .lineLimit(1)
                                        .blur(radius: store.isRecoveryPhraseHidden ? Constants.blurValue : 0)
                                    
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                                .padding(8)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                                }
                            }
                        }
                    }
                }
                .id("twoList")

                birthday()
            }
        }
    }

    @ViewBuilder func birthday() -> some View {
        if let birthdayValue = store.birthdayValue {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.RecoveryPhraseDisplay.birthdayTitle)
                    .zFont(.medium, size: 14, style: Design.Inputs.Filled.text)

                HStack {
                    Text("\(birthdayValue)")
                        .zFont(.medium, size: 16, style: Design.Inputs.Filled.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .blur(radius: store.isRecoveryPhraseHidden ? Constants.blurBDValue : 0)
                    
                    Spacer()
                }
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                }
                .padding(.top, 6)
            }
            .padding(.top, 24)
        }
    }
    
    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(spacing: 0) {
            Text(L10n.RestoreWallet.Help.title)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)
            
            infoContent(text: L10n.RestoreWallet.Help.phrase)
                .padding(.bottom, 12)
            
            infoContent(text: L10n.RestoreWallet.Help.birthday)
                .padding(.bottom, 32)
            
            ZashiButton(L10n.General.ok.uppercased()) {
                store.send(.helpSheetRequested)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func infoContent(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoCircle.image
                .zImage(size: 20, style: Design.Text.primary)
            
            if let attrText = try? AttributedString(
                markdown: text,
                including: \.zashiApp
            ) {
                ZashiText(withAttributedString: attrText, colorScheme: colorScheme)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    NavigationView {
        RecoveryPhraseDisplayView(
            store:
                StoreOf<RecoveryPhraseDisplay>(
                    initialState: RecoveryPhraseDisplay.State(
                        birthdayValue: nil,
                        phrase: .placeholder
                    )
                ) {
                    RecoveryPhraseDisplay()
                }
        )
    }
}

// MARK: Placeholders

extension RecoveryPhraseDisplay.State {
    public static let initial = RecoveryPhraseDisplay.State(
        birthday: nil,
        phrase: nil
    )
}

extension RecoveryPhraseDisplay {
    public static let placeholder = StoreOf<RecoveryPhraseDisplay>(
        initialState: .initial
    ) {
        RecoveryPhraseDisplay()
    }
}
