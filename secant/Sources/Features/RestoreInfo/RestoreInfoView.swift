//
//  RestoreInfoView.swift
//  Zashi
//
//  Created by Lukáš Korba on 06-03-2024
//

import SwiftUI
import Combine
import ComposableArchitecture

struct RestoreInfoView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @PlatformBindable var store: StoreOf<RestoreInfo>
    
    init(store: StoreOf<RestoreInfo>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Asset.Assets.Illustrations.connect.image
                    .resizable()
                    .frame(width: 132, height: 90)
                    .padding(.top, 40)
                    .padding(.bottom, 24)

                Text(localizable: .restoreInfoTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.bottom, 8)

                Text(
                    localizable: store.isKeystoneFlow
                    ? .keepZodlOpenSubtitleHWWallet
                    : store.isResyncFlow
                    ? .keepZodlOpenSubtitleResync
                    : .keepZodlOpenSubtitleRestore
                )
                .zFont(.medium, size: 16, style: Design.Text.primary)
                .padding(.bottom, 16)

                Text(
                    localizable: store.isKeystoneFlow
                    ? .keepZodlOpenInstructionsHWWallet
                    : store.isResyncFlow
                    ? .keepZodlOpenInstructionsResyncing
                    : .keepZodlOpenInstructionsRestoring
                )
                .zFont(size: 14, style: Design.Text.primary)
                .padding(.bottom, 16)

#if os(macOS)
                bulletpoint(String(localizable: .restoreInfoTip1Mac))
                bulletpoint(String(localizable: .restoreInfoTip2Mac))
                    .padding(.bottom, Design.Spacing._lg)
#else
                bulletpoint(String(localizable: .restoreInfoTip1))
                bulletpoint(String(localizable: .restoreInfoTip2))
                    .padding(.bottom, Design.Spacing._lg)
#endif

                if let attrText = try? AttributedString(
                    markdown: String(
                        localizable: store.isKeystoneFlow
                        ? .keepZodlOpenWarningHWWallet
                        : store.isResyncFlow
                        ? .keepZodlOpenWarningResync
                        : .keepZodlOpenWarningRestore
                    ),
                    including: \.zashiApp
                ) {
                    ZashiText(withAttributedString: attrText, colorScheme: colorScheme, textColor: Design.Utility.WarningYellow._900.color(colorScheme))
                        .zFont(size: 14, style: Design.Utility.WarningYellow._900)
                        .padding(.vertical, Design.Spacing._xl)
                        .padding(.horizontal, Design.Spacing._2xl)
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._3xl)
                                .fill(Design.Utility.WarningYellow._50.color(colorScheme))
                            
                        }
                }
                
                Spacer()

                HStack {
                    ZashiToggle(
                        isOn: $store.isAcknowledged,
                        label: String(
                            localizable: store.isKeystoneFlow
                            ? .keepScreenOnSyncing
                            : store.isResyncFlow
                            ? .keepScreenOnResyncing
                            : .keepScreenOnRestoring
                        ),
                        textSize: 16
                    )
                    
                    Spacer()
                }
                .padding(.leading, 1)

                // [B4-4 class] In the Keystone flow, OK triggers the import behind this
                // screen (engine stop → drain → anchor fetch → import → restart —
                // seconds). Show the wait (spinner + disabled) instead of a dead button
                // that ignores clicks; re-entry is blocked by `.disabled(true)`.
                if store.isProcessing {
                    ZashiButton(
                        (store.isKeystoneFlow || store.isResyncFlow)
                        ? String(localizable: .generalOk).uppercased()
                        : String(localizable: .restoreInfoGotIt),
                        accessoryView: ZashiSpinner(macTint: .buttonAccessory)
                    ) {
                        store.send(.gotItTapped)
                    }
                    .disabled(true)
                    .padding(.vertical, 24)
                } else {
                    ZashiButton((store.isKeystoneFlow || store.isResyncFlow)
                                ? String(localizable: .generalOk).uppercased()
                                : String(localizable: .restoreInfoGotIt)
                    ) {
                        store.send(.gotItTapped)
                    }
                    .padding(.vertical, 24)
                }
            }
            .zashiBack(hidden: true)
        }
        .zashiNavBarTitleDisplayMode(.inline)
        .screenHorizontalPadding()
        .applyScreenBackground()
    }
    
    @ViewBuilder
    private func bulletpoint(_ text: String) -> some View {
        HStack(alignment: .top) {
            Circle()
                .frame(width: 4, height: 4)
                .padding(.top, 7)
                .padding(.leading, 8)

            Text(text)
                .zFont(size: 14, style: Design.Text.primary)
        }
        .padding(.bottom, 5)
    }
}

// MARK: - Previews

#Preview {
    RestoreInfoView(store: RestoreInfo.initial)
}

// MARK: - Store

extension RestoreInfo {
    @MainActor static var initial = StoreOf<RestoreInfo>(
        initialState: .initial
    ) {
        RestoreInfo()
    }
}

// MARK: - Placeholders

extension RestoreInfo.State {
    static var initial: RestoreInfo.State { RestoreInfo.State() }
}
