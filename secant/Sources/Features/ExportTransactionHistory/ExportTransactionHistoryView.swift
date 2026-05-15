//
//  ExportTransactionHistoryView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-13.
//

import SwiftUI
import ComposableArchitecture

struct ExportTransactionHistoryView: View {
    @Perception.Bindable var store: StoreOf<ExportTransactionHistory>

    init(store: StoreOf<ExportTransactionHistory>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                Text(localizable: .taxExportTaxFile)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 40)
                
                Text(localizable: .taxExportDesc(store.accountName))
                    .zFont(size: 14, style: Design.Text.primary)
                    .padding(.top, 12)
                
                Spacer()
                
                if store.isExportingData {
                    ZashiButton(
                        String(localizable: .taxExportDownload),
                        accessoryView: ProgressView()
                    ) {
                        store.send(.exportRequested)
                    }
                    .disabled(true)
                    .padding(.bottom, 24)
                } else {
                    ZashiButton(String(localizable: .taxExportDownload)) {
                        store.send(.exportRequested)
                    }
                    .disabled(!store.isExportPossible)
                    .padding(.bottom, 24)
                }
            }
            .zashiBack()

            shareLogsView()
        }
        .navigationBarTitleDisplayMode(.inline)
        .screenHorizontalPadding()
        .applyScreenBackground()
        .screenTitle(String(localizable: .taxExportTitle))
    }
}

private extension ExportTransactionHistoryView {
    @ViewBuilder func shareLogsView() -> some View {
        if store.exportBinding {
            UIShareDialogView(activityItems:
                [ShareableURL(
                    url: store.dataURL,
                    title: String(localizable: .taxExportTaxFile),
                    desc: String(localizable: .taxExportShareDesc(store.accountName))
                )]
            ) {
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
    ExportTransactionHistoryView(store: .initial)
}

// MARK: - Store

extension StoreOf<ExportTransactionHistory> {
    static var initial = StoreOf<ExportTransactionHistory>(
        initialState: .initial
    ) {
        ExportTransactionHistory()
    }
}

// MARK: - Placeholders

extension ExportTransactionHistory.State {
    static let initial = ExportTransactionHistory.State()
}
