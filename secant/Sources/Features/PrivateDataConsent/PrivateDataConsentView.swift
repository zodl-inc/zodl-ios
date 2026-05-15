//
//  PrivateDataConsentView.swift
//  Zashi
//
//  Created by Lukáš Korba on 01.10.2023.
//

import SwiftUI
import ComposableArchitecture

struct PrivateDataConsentView: View {
    @Perception.Bindable var store: StoreOf<PrivateDataConsent>

    init(store: StoreOf<PrivateDataConsent>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .privateDataConsentTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)
                
                Text(localizable: .privateDataConsentMessage1)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                
                Text(localizable: .privateDataConsentMessage2)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 8)
                
                Text(localizable: .privateDataConsentMessage3)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 8)
                
                Text(localizable: .privateDataConsentMessage4)
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 8)
                
                Spacer()
                
                ZashiToggle(
                    isOn: $store.isAcknowledged,
                    label: String(localizable: .privateDataConsentConfirmation)
                )
                .padding(.vertical, 24)
                .padding(.leading, 1)
                
                if store.isExportingData {
                    ZashiButton(
                        String(localizable: .settingsExportPrivateData),
                        type: .secondary,
                        accessoryView: ProgressView()
                    ) {
                        store.send(.exportRequested)
                    }
                    .disabled(true)
                    .padding(.bottom, 8)
                } else {
                    ZashiButton(
                        String(localizable: .settingsExportPrivateData),
                        type: .secondary
                    ) {
                        store.send(.exportRequested)
                    }
                    .disabled(!store.isExportPossible)
                    .padding(.bottom, 8)
                }
                
#if DEBUG
                if store.isExportingLogs {
                    ZashiButton(
                        String(localizable: .settingsExportLogsOnly),
                        accessoryView: ProgressView()
                    ) {
                        store.send(.exportLogsRequested)
                    }
                    .disabled(true)
                    .padding(.bottom, 20)
                } else {
                    ZashiButton(
                        String(localizable: .settingsExportLogsOnly)
                    ) {
                        store.send(.exportLogsRequested)
                    }
                    .disabled(!store.isExportPossible)
                    .padding(.bottom, 20)
                }
#endif
            }
            .zashiBack()
            .onAppear { store.send(.onAppear)}

            shareLogsView()
        }
        .navigationBarTitleDisplayMode(.inline)
        .screenHorizontalPadding()
        .applyScreenBackground()
        .screenTitle(String(localizable: .privateDataConsentScreenTitle).uppercased())
    }
}

private extension PrivateDataConsentView {
    @ViewBuilder func shareLogsView() -> some View {
        if store.exportBinding {
            UIShareDialogView(activityItems: store.exportURLs) {
                store.send(.shareFinished)
            }
            // UIShareDialogView only wraps UIActivityViewController presentation
            // so frame is set to 0 to not break SwiftUI's layout
            .frame(width: 0, height: 0)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Previews

#Preview {
    PrivateDataConsentView(store: .demo)
}

// MARK: - Store

extension StoreOf<PrivateDataConsent> {
    static var demo = StoreOf<PrivateDataConsent>(
        initialState: .initial
    ) {
        PrivateDataConsent()
    }
}

// MARK: - Placeholders

extension PrivateDataConsent.State {
    static let initial = PrivateDataConsent.State(
        dataDbURL: [],
        exportBinding: false,
        exportLogsState: .initial
    )
}
