//
//  KeystoneFirmwareUpdateView.swift
//  Zashi
//
//  MOB-1510's firmware gate failure screen; mirrors `PreSendingFailureView`'s structure.
//  `KeystoneFirmwareUpdateContent` below is split out (store-less) so a presentation without
//  its own `SendConfirmation` store can still reuse the same copy.
//

import SwiftUI
import ComposableArchitecture

struct KeystoneFirmwareUpdateView: View {
    @PlatformBindable var store: StoreOf<SendConfirmation>

    init(store: StoreOf<SendConfirmation>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()

                KeystoneFirmwareUpdateContent(illustration: store.failureIlustration, detectedVersion: store.detectedKeystoneFirmware)

                Spacer()

                ZashiButton(String(localizable: .generalClose)) {
                    store.send(.keystoneFirmwareUpdateCloseTapped)
                }
                .padding(.bottom, 24)
            }
        }
        .navigationBarBackButtonHidden()
        .padding(.vertical, 1)
        .screenHorizontalPadding()
        .applyFailureScreenBackground()
    }
}

/// Illustration + title + body for the firmware-update prompt; store-less so other presentations
/// of the gate can reuse it.
struct KeystoneFirmwareUpdateContent: View {
    let illustration: Image
    let detectedVersion: KeystoneDisplayFirmwareVersion?

    var body: some View {
        VStack(spacing: 0) {
            illustration
                .resizable()
                .frame(width: 148, height: 148)

            Text(String(localizable: .keystoneFirmwareUpdateTitle))
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text(bodyText)
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .screenHorizontalPadding()
        }
    }

    private var bodyText: String {
        if let detectedVersion {
            return String(
                localizable: .keystoneFirmwareUpdateBody(
                    detectedVersion.versionString,
                    KeystoneDisplayFirmwareVersion.minimumSupported.versionString
                )
            )
        }
        return String(localizable: .keystoneFirmwareUpdateLegacyBody(KeystoneDisplayFirmwareVersion.minimumSupported.versionString))
    }
}

#Preview {
    NavigationView {
        KeystoneFirmwareUpdateView(store: SendConfirmation.initial)
    }
}
