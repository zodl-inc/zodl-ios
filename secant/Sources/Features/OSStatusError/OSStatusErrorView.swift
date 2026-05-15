//
//  OSStatusErrorView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-20.
//

import SwiftUI
import ComposableArchitecture

struct OSStatusErrorView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<OSStatusError>
    
    init(store: StoreOf<OSStatusError>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()
                
                Asset.Assets.infoCircle.image
                    .zImage(size: 28, style: Design.Utility.ErrorRed._700)
                    .padding(18)
                    .background {
                        Circle()
                            .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                    }
                    .rotationEffect(.degrees(180))

                Text(localizable: .osStatusErrorTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Text(localizable: .osStatusErrorMessage)
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.bottom, 12)

                Text(localizable: .osStatusErrorError(String(format: "%d", store.osStatus)))
                    .zFont(.medium, size: 14, style: Design.Text.primary)
                    .padding(.bottom, 100)

                Spacer()
                
                ZashiButton(String(localizable: .errorPageActionContactSupport)) {
                    store.send(.sendSupportMail)
                }
                .padding(.bottom, 24)
                
                if let supportData = store.supportData {
                    UIMailDialogView(
                        supportData: supportData,
                        completion: {
                            store.send(.sendSupportMailFinished)
                        }
                    )
                    // UIMailDialogView only wraps MFMailComposeViewController presentation
                    // so frame is set to 0 to not break SwiftUI's layout
                    .frame(width: 0, height: 0)
                }
                
                shareMessageView()
            }
            .frame(maxWidth: .infinity)
            .onAppear { store.send(.onAppear) }
            .screenHorizontalPadding()
            .applyErredScreenBackground()
        }
    }
}

private extension OSStatusErrorView {
    @ViewBuilder func shareMessageView() -> some View {
        if store.isExportingData {
            UIShareDialogView(activityItems: [store.message]) {
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
    NavigationView {
        OSStatusErrorView(
            store:
                StoreOf<OSStatusError>(
                    initialState: OSStatusError.State(
                        message: "",
                        osStatus: errSecSuccess
                    )
                ) {
                    OSStatusError()
                }
        )
    }
}

// MARK: Placeholders

extension OSStatusError.State {
    static let initial = OSStatusError.State(
        message: "",
        osStatus: errSecSuccess
    )
}

extension OSStatusError {
    static let placeholder = StoreOf<OSStatusError>(
        initialState: .initial
    ) {
        OSStatusError()
    }
}
