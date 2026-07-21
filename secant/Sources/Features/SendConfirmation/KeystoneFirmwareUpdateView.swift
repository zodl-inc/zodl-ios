//
//  KeystoneFirmwareUpdateView.swift
//  Zashi
//
//  MOB-1510: Keystone minimum-firmware gate failure screen — mirrors `PreSendingFailureView`'s
//  structure exactly (illustration, title, body, `applyFailureScreenBackground()`, `ZashiButton`).
//  Presented as a coordinator path element from every send-side Keystone signing surface (the 4
//  send `CoordFlowCoordinator`s) once `SendConfirmationStore.foundPCZT` detects firmware below
//  `KeystoneFirmwareVersion.minimumSupported`, or no version stamp at all.
//
//  `KeystoneFirmwareUpdateContent` below carries the illustration/title/body only (no button, no
//  screen-centering spacers) so the Migration Keystone ceremony's sheet (`MigrationCoordFlowView`,
//  which has no `SendConfirmation` of its own to scope a store from) can present the SAME copy and
//  visual without depending on this feature's store or its full-screen layout.
//

import SwiftUI
import ComposableArchitecture

struct KeystoneFirmwareUpdateView: View {
    @Perception.Bindable var store: StoreOf<SendConfirmation>

    init(store: StoreOf<SendConfirmation>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Spacer()

                KeystoneFirmwareUpdateContent(detectedVersion: store.detectedKeystoneFirmware)

                Spacer()

                ZashiButton(String(localizable: .keystoneFirmwareUpdateClose)) {
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

/// Illustration + title + body for MOB-1510's firmware-update prompt, shared by the full-screen
/// `KeystoneFirmwareUpdateView` above (the 4 send-side coordinators) and the Migration Keystone
/// ceremony's sheet content (`MigrationCoordFlowView`) — see this file's header comment.
struct KeystoneFirmwareUpdateContent: View {
    let detectedVersion: KeystoneFirmwareVersion?

    var body: some View {
        VStack(spacing: 0) {
            Asset.Assets.Illustrations.failure3.image
                .resizable()
                .frame(width: 148, height: 148)

            Text(String(localizable: .keystoneFirmwareUpdateTitle))
                .zFont(.semiBold, size: 28, style: Design.Text.primary)
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
                    KeystoneFirmwareVersion.minimumSupported.versionString
                )
            )
        }
        return String(localizable: .keystoneFirmwareUpdateLegacyBody(KeystoneFirmwareVersion.minimumSupported.versionString))
    }
}

#Preview {
    NavigationView {
        KeystoneFirmwareUpdateView(store: SendConfirmation.initial)
    }
}
