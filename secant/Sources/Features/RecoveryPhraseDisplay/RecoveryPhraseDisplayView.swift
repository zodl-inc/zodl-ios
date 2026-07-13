//
//  RecoveryPhraseDisplayView.swift
//  Zashi
//
//  Created by Francisco Gindre on 10/26/21.
//

import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import MnemonicSwift
#if os(macOS)
import AppKit
#endif

struct RecoveryPhraseDisplayView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    enum Constants {
        static let blurValue = 6.0
        static let blurBDValue = 7.0
        /// Stands in for seed words and the birthday before local authentication succeeds,
        /// so no real seed material exists in the view hierarchy (accessibility tree,
        /// snapshots, view inspection) until the phrase is revealed.
        static let hiddenWordPlaceholder = "•••••"
    }

    @PlatformBindable var store: StoreOf<RecoveryPhraseDisplay>

    init(store: StoreOf<RecoveryPhraseDisplay>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .recoveryPhraseDisplayTitle)
                #if os(macOS)
                    .padding(.top, 24)
                #endif
                
                Text(localizable: .recoveryPhraseDisplayDescription)
                    .zFont(size: 14, style: Design.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                threeColumnSeed()
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                Spacer()

                if store.isRecoveryPhraseHidden {
                    if store.isSeedUnavailable {
                        Text(localizable: .recoveryPhraseDisplayNoWords)
                            .zFont(.medium, size: 14, style: Design.Text.primary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 24)
                    } else {
                        ZashiButton(
                            String(localizable: .recoveryPhraseDisplayReveal),
                            prefixView:
                                Asset.Assets.eyeOn.image
                                .zImage(size: 20, style: Design.Btns.Primary.fg)
                        ) {
                            store.send(.recoveryPhraseUnhideRequested, animation: .easeInOut)
                        }
                        .padding(.bottom, 24)
                    }
                } else {
                    if store.isWalletBackup {
                        ZashiButton(
                            String(localizable: .recoveryPhraseDisplayButtonRemindMeLater),
                            type: .ghost
                        ) {
                            store.send(.remindMeLaterTapped)
                        }
                        .padding(.bottom, 8)

                        ZashiButton(
                            String(localizable: .recoveryPhraseDisplayButtonWroteItDown)
                        ) {
                            store.send(.seedSavedTapped)
                        }
                        .accessibilityIdentifier(AccessibilityID.RecoveryPhrase.confirmButton)
                        .padding(.bottom, 24)
                    } else {
                        ZashiButton(
                            String(localizable: .recoveryPhraseDisplayHide),
                            prefixView:
                                Asset.Assets.eyeOff.image
                                .zImage(size: 20, style: Design.Btns.Primary.fg)
                        ) {
                            store.send(.hideEverything, animation: .easeInOut)
                        }
                        .padding(.bottom, 20)
                    }
                }
            }
            .onAppear { store.send(.onAppear) }
#if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                store.send(.hideEverything)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                store.send(.hideEverything)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                store.send(.hideEverything)
            }
#elseif os(macOS)
            // macOS: hide the revealed phrase when the app loses focus (user switches away), matching the
            // iOS willResignActive purge so the seed isn't left on screen on focus loss (MOB-1363).
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                store.send(.hideEverything)
            }
#endif
            .alert($store.scope(state: \.alert, action: \.alert))
            .zashiBack()
            .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                helpSheetContent()
            }
            .zashiNavigationBarItems(
                trailing:
                    Button {
                        store.send(
                            store.isRecoveryPhraseHidden || !store.isWalletBackup
                            ? .helpSheetRequested
                            : .hideEverything,
                            animation: .easeInOut
                        )
                    } label: {
#if os(macOS)
                        // RULE #3: plain SF symbols → clean circular glass capsule (no forced zImage size).
                        Image(systemName: (store.isRecoveryPhraseHidden || !store.isWalletBackup) ? "info.circle" : "eye.slash")
                            .zashiToolbarIconPadding()
#else
                        if store.isRecoveryPhraseHidden || !store.isWalletBackup {
                            Asset.Assets.Icons.help.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(Design.Spacing.navBarButtonPadding)
                        } else {
                            Asset.Assets.eyeOff.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(Design.Spacing.navBarButtonPadding)
                        }
#endif
                    }
            )
        }
        .padding(.horizontal, 20)
        .applyScreenBackground(scrollable: true)
        .screenTitle(String(localizable: .recoveryPhraseDisplayScreenTitle).uppercased())
    }
    
    /// The word shown at the given seed position. Real seed words exist in the view
    /// hierarchy only after local authentication populated `store.phrase`; before
    /// that (and after every hide) only placeholders are rendered.
    private func word(at index: Int) -> String {
        guard let words = store.phrase?.words, index < words.count else {
            return Constants.hiddenWordPlaceholder
        }

        return words[index].data
    }

    @ViewBuilder func threeColumnSeed() -> some View {
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

                                Text(word(at: j * 3 + i))
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

    @ViewBuilder func birthday() -> some View {
        // The birthday row is always part of the layout and mirrors the seed grid:
        // masked dots while hidden, the real height after a successful reveal. Gating
        // visibility on `birthdayValue` would make the row vanish on reveal for a
        // wallet whose stored birthday height is nil.
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .recoveryPhraseDisplayBirthdayTitle)
                .zFont(.medium, size: 14, style: Design.Inputs.Filled.text)

            HStack {
                Text(store.birthdayValue ?? Constants.hiddenWordPlaceholder)
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
    
    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(spacing: 0) {
            Text(localizable: .restoreWalletHelpTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)
            
            infoContent(text: String(localizable: .restoreWalletHelpPhrase))
                .padding(.bottom, 12)
            
            infoContent(text: String(localizable: .walletBirthdayHelpDescRecovery))
                .padding(.bottom, 32)
            
            ZashiButton(String(localizable: .generalOk).uppercased()) {
                store.send(.helpSheetRequested)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func infoContent(text: String) -> some View {
        HintBox(text, style: .markdown)
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
    static var initial: RecoveryPhraseDisplay.State {
        RecoveryPhraseDisplay.State(birthday: nil, phrase: nil)
    }
}

extension RecoveryPhraseDisplay {
    @MainActor static let placeholder = StoreOf<RecoveryPhraseDisplay>(
        initialState: .initial
    ) {
        RecoveryPhraseDisplay()
    }
}
