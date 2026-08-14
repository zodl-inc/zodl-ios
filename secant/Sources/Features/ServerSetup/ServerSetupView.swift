//
//  ServerSetupView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-02-07.
//

import SwiftUI
import Combine
import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

struct ServerSetupView: View {
    @Environment(\.colorScheme) var colorScheme

    var customDismiss: (() -> Void)? = nil

    @PlatformBindable var store: StoreOf<ServerSetup>

    init(store: StoreOf<ServerSetup>, customDismiss: (() -> Void)? = nil) {
        self.store = store
        self.customDismiss = customDismiss
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .center, spacing: 0) {
                ScrollView {
                    // MARK: - Connection Mode Section
                    connectionModeSection()

                    // MARK: - Server List (Manual mode only)
                    if store.connectionMode == .manual {
                        serverListSection()
                    }
                }
                .disabled(store.isUpdatingServer)
                .padding(.vertical, 1)

                // MARK: - Multi-server / privacy info
                multiServerInfoFooter()

                // MARK: - Save Button
                saveButton()
            }
            .frame(maxWidth: .infinity)
            .zashiBack(store.isUpdatingServer, customDismiss: customDismiss)
            .screenTitle(String(localizable: .serverSetupTitle))
            .onAppear { store.send(.onAppear) }
            .onDisappear { store.send(.onDisappear) }
            .alert($store.scope(state: \.alert, action: \.alert))
            .applyScreenBackground()
        }
        .zashiNavBarTitleDisplayMode(.inline)
    }

    // MARK: - Connection Mode

    @ViewBuilder
    private func connectionModeSection() -> some View {
        HStack {
            Text(localizable: .serverSetupConnectionMode)
                .zFont(.semiBold, size: 18, style: Design.Text.primary)
            Spacer()
        }
        .screenHorizontalPadding()
        .padding(.top, 12)
        .padding(.bottom, 8)

        // Automatic
        Button {
            store.send(.connectionModeChanged(.automatic))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    radioIndicator(isSelected: store.connectionMode == .automatic)

                    Text(localizable: .serverSetupAutomatic)
                        .zFont(.medium, size: 14, style: Design.Text.primary)

                    Spacer()
                }

                if store.connectionMode == .automatic && !store.automaticDisplayServer.isEmpty {
                    HStack(spacing: 8) {
                        Text(store.automaticDisplayServer)
                            .zFont(size: 14, style: Design.Text.tertiary)

                        if store.isEvaluatingServers {
                            testingBadge()
                        } else if store.automaticDisplayServer == store.activeSyncServer {
                            activeBadge()
                        }
                    }
                    .padding(.leading, 30)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .screenHorizontalPadding()

        Design.Surfaces.divider.color(colorScheme)
            .frame(height: 1)
            .screenHorizontalPadding()

        // Manual
        Button {
            store.send(.connectionModeChanged(.manual))
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    radioIndicator(isSelected: store.connectionMode == .manual)

                    Text(localizable: .serverSetupManual)
                        .zFont(.medium, size: 14, style: Design.Text.primary)

                    Spacer()
                }

                if store.connectionMode == .manual && store.isEvaluatingServers && store.topKServers.isEmpty {
                    Text(localizable: .serverSetupPerformingTest)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .padding(.leading, 30)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .screenHorizontalPadding()
    }

    // MARK: - Server List Section

    @ViewBuilder
    private func serverListSection() -> some View {
        if store.topKServers.isEmpty {
            // Before evaluation completes: flat list
            HStack {
                Text(localizable: .serverSetupAllServers)
                    .zFont(.semiBold, size: 18, style: Design.Text.primary)
                Spacer()
            }
            .screenHorizontalPadding()
            .padding(.top, 15)

            serverList(store.servers)
        } else {
            // After evaluation: fastest + other
            HStack {
                Text(localizable: .serverSetupFastestServers)
                    .zFont(.semiBold, size: 18, style: Design.Text.primary)

                Spacer()

                Button {
                    store.send(.refreshServersTapped)
                } label: {
                    HStack(spacing: 4) {
                        Text(localizable: .serverSetupRefresh)
                            .zFont(.semiBold, size: 14, style: Design.Text.primary)

                        if store.isEvaluatingServers {
                            progressView()
                                .scaleEffect(0.7)
                        } else {
                            Asset.Assets.refreshCCW2.image
                                .zImage(size: 20, style: Design.Text.primary)
                        }
                    }
                    .padding(5)
                }
                .disabled(store.isEvaluatingServers || store.isUpdatingServer)
            }
            .screenHorizontalPadding()
            .padding(.top, 15)

            serverList(store.topKServers)

            HStack {
                Text(localizable: .serverSetupOtherServers)
                    .zFont(.semiBold, size: 18, style: Design.Text.primary)
                Spacer()
            }
            .screenHorizontalPadding()
            .padding(.top, 15)

            serverList(store.servers)
        }
    }

    // MARK: - Server List

    private func serverList(_ servers: [ZcashSDKEnvironment.Server]) -> some View {
        ForEach(servers, id: \.self) { server in
            WithPerceptionTracking {
                let serverValue = server.value(for: store.network)
                let isCustom = serverValue == String(localizable: .serverSetupCustom)
                let isSelected = isCustom
                    ? store.selectedServer == String(localizable: .serverSetupCustom)
                    : store.selectedServer == serverValue
                let isCustomExpanded = isCustom && isSelected
                let isSyncServer = isCustom
                    ? store.activeSyncServer == store.customServer
                    : store.activeSyncServer == serverValue

                VStack {
                    HStack(spacing: 0) {
                        Button {
                            store.send(.serverSelected(serverValue))
                        } label: {
                            HStack(
                                alignment: isCustomExpanded ? .top : .center,
                                spacing: 10
                            ) {
                                radioIndicator(isSelected: isSelected)
                                    .padding(.top, isCustomExpanded ? 16 : 0)

                                if isCustomExpanded {
                                    VStack(alignment: .leading) {
                                        Text(serverValue)
                                            .zFont(.medium, size: 14, style: Design.Text.primary)
                                            .multilineTextAlignment(.leading)

                                        WithPerceptionTracking {
                                            TextField(
                                                String(localizable: .serverSetupPlaceholder),
                                                text: $store.customServer
                                            )
                                            .zFont(.medium, size: 14, style: Design.Text.primary)
                                            .frame(height: 40)
#if os(iOS)
                                            .autocapitalization(.none)
#endif
                                            .autocorrectionDisabled()
#if os(iOS)
                                            .keyboardType(.URL)
#endif
                                            .multilineTextAlignment(.leading)
                                            .padding(.leading, 10)
                                            .background {
                                                RoundedRectangle(cornerRadius: Design.Radius._md)
                                                    .fill(Design.Surfaces.bgPrimary.color(colorScheme))
                                            }
                                            .overlay {
                                                RoundedRectangle(cornerRadius: Design.Radius._md)
                                                    .stroke(Design.Inputs.Default.stroke.color(colorScheme), lineWidth: 1)
                                            }
                                            .padding(.vertical, 8)
                                        }
                                    }
                                    .padding(.vertical, 16)
                                } else {
                                    VStack(alignment: .leading) {
                                        Text(
                                            isCustom && !store.customServer.isEmpty
                                            ? store.customServer
                                            : serverValue
                                        )
                                        .zFont(.medium, size: 14, style: Design.Text.primary)
                                        .multilineTextAlignment(.leading)

                                        if let desc = server.desc(for: store.network) {
                                            Text(desc)
                                                .zFont(size: 14, style: Design.Text.tertiary)
                                        }
                                    }
                                }

                                Spacer()

                                if isSyncServer && isSelected {
                                    activeBadge()
                                }

                                if isCustom && !isSelected {
                                    Asset.Assets.chevronDown.image
                                        .zImage(size: 20, style: Design.Text.primary)
                                }
                            }
                            .frame(minHeight: 48)
                            .padding(.leading, 24)
                            .padding(.trailing, isCustomExpanded ? 0 : 24)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._xl)
                                    .fill(
                                        isSelected
                                        ? Design.Surfaces.bgSecondary.color(colorScheme)
                                        : Asset.Colors.background.color
                                    )
                            }
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 8)

                    if let last = servers.last, last != server {
                        Design.Surfaces.divider.color(colorScheme)
                            .frame(height: 1)
                    }
                }
            }
        }
    }

    // MARK: - Multi-server / privacy info footer

    @ViewBuilder
    private func multiServerInfoFooter() -> some View {
        HStack(alignment: .top, spacing: 0) {
            Asset.Assets.infoOutline.image
                .zImage(size: 20, style: Design.Text.tertiary)
                .padding(.trailing, 12)

            Text(localizable: .serverSetupMultiServerInfo)
        }
        .zFont(size: 12, style: Design.Text.tertiary)
        .screenHorizontalPadding()
        .padding(.bottom, 20)
    }

    // MARK: - Save Button

    @ViewBuilder
    private func saveButton() -> some View {
        WithPerceptionTracking {
            ZStack {
                Asset.Colors.background.color
                    .frame(height: 72)
                    .cornerRadius(32)
                    .shadow(color: .black.opacity(0.02), radius: 4, x: 0, y: -8)

                let customLabel = String(localizable: .serverSetupCustom)
                // Disable Save when the custom input can't be parsed (blank, missing :port, etc.) so an
                // invalid entry can't pass the enable-check and then fail in setServerTapped with an alert.
                let customIsInvalid = store.selectedServer == customLabel
                    && UserPreferencesStorage.ServerConfig.endpoint(
                        for: store.customServer.trimmingCharacters(in: .whitespaces),
                        streamingCallTimeoutInMillis: ZcashSDKEnvironment.ZcashSDKConstants.streamingCallTimeoutInMillis
                    ) == nil
                let needsServer = store.connectionMode == .manual && (store.selectedServer == nil || customIsInvalid)
                let canSave = store.hasChanges && !needsServer

                // Rule #7 + button consolidation: ZashiButton owns the macOS width cap (`Design.Mac.maxButtonWidth`) and the
                // primary/disabled styling — don't re-implement a full-width hand-rolled CTA. Branch only
                // to keep the in-progress spinner as the accessory while the server is being saved.
                if store.isUpdatingServer {
                    ZashiButton(
                        String(localizable: .serverSetupSave),
                        accessoryView: progressView(invertTint: true)
                    ) {
                        store.send(.setServerTapped)
                    }
                    .disabled(true)
                    .screenHorizontalPadding()
                } else {
                    ZashiButton(String(localizable: .serverSetupSave)) {
                        store.send(.setServerTapped)
                    }
                    .disabled(!canSave)
                    .screenHorizontalPadding()
                }
            }
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func radioIndicator(isSelected: Bool) -> some View {
        if isSelected {
            Circle()
                .fill(Design.Text.primary.color(colorScheme))
                .frame(width: 24, height: 24)
                .overlay {
                    Asset.Assets.check.image
                        .zImage(size: 14, color: Design.screenBackground.color(colorScheme))
                }
        } else {
            Circle()
                .fill(Design.Checkboxes.offBg.color(colorScheme))
                .frame(width: 24, height: 24)
                .overlay {
                    Circle()
                        .stroke(Design.Checkboxes.offStroke.color(colorScheme))
                        .frame(width: 24, height: 24)
                }
        }
    }

    @ViewBuilder
    private func activeBadge() -> some View {
        Text(localizable: .serverSetupActive)
            .zFont(.medium, size: 14, style: Design.Utility.SuccessGreen._700)
            .frame(height: 20)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .zBackground(Design.Utility.SuccessGreen._50)
            .cornerRadius(16)
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .inset(by: 0.5)
                    .stroke(Design.Utility.SuccessGreen._200.color(colorScheme), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func testingBadge() -> some View {
        HStack(spacing: 4) {
            Text(localizable: .serverSetupTesting)
                .zFont(.medium, size: 14, style: Design.Utility.WarningYellow._700)
            progressView()
                .scaleEffect(0.6)
        }
        .frame(height: 20)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .zBackground(Design.Utility.WarningYellow._50)
        .cornerRadius(16)
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .inset(by: 0.5)
                .stroke(Design.Utility.WarningYellow._200.color(colorScheme), lineWidth: 1)
        }
    }

    private func progressView(invertTint: Bool = false) -> some View {
        let tint: Color = colorScheme == .dark
            ? (invertTint ? .black : .white) : (invertTint ? .white : .black)
        return ZashiSpinner(iosTint: tint, macTint: .fixed(tint))
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        ServerSetupView(
            store: ServerSetup.placeholder
        )
    }
}

// MARK: Placeholders

extension ServerSetup {
    @MainActor static let placeholder = StoreOf<ServerSetup>(
        initialState: .initial
    ) {
        ServerSetup()
    }
}
