//
//  OSStatusErrorView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-20.
//

import SwiftUI
import Combine
import ComposableArchitecture
import Foundation

struct OSStatusErrorView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @PlatformBindable var store: StoreOf<OSStatusError>
    
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

                Text(localizable: store.secureEnclaveUnavailable ? .osStatusErrorSecureEnclaveTitle : .osStatusErrorTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Text(localizable: store.secureEnclaveUnavailable ? .osStatusErrorSecureEnclaveMessage : .osStatusErrorMessage)
                    .zFont(size: 14, style: Design.Text.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.bottom, store.secureEnclaveUnavailable ? 100 : 12)

                // A keychain OSStatus code and Contact Support are meaningless for a missing-hardware case,
                // so the Secure-Enclave-unavailable screen is purely informational (no code, no button).
                if !store.secureEnclaveUnavailable {
                    Text(localizable: .osStatusErrorError(String(format: "%d", store.osStatus)))
                        .zFont(.medium, size: 14, style: Design.Text.primary)
                        .padding(.bottom, 100)
                }

                Spacer()

                if !store.secureEnclaveUnavailable {
                    ZashiButton(String(localizable: .errorPageActionContactSupport)) {
                        store.send(.sendSupportMail)
                    }
                    .padding(.bottom, 24)

                    #if os(macOS)
                    // Failed-relocation recovery (MOB-1485): relaunching retries the keychain
                    // migration automatically, but if the state is genuinely stuck this is the
                    // reset escape hatch — Root confirms via the wipeRequest alert, then runs
                    // the standard resetZashi flow (wipes both keychains + SDK data).
                    ZashiButton(String(localizable: .settingsDeleteZashi), type: .destructive1) {
                        store.send(.startOverTapped)
                    }
                    .padding(.bottom, 24)
                    #endif
                }
                
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
    static var initial: OSStatusError.State {
        OSStatusError.State(message: "", osStatus: errSecSuccess)
    }
}

extension OSStatusError {
    @MainActor static let placeholder = StoreOf<OSStatusError>(
        initialState: .initial
    ) {
        OSStatusError()
    }
}
