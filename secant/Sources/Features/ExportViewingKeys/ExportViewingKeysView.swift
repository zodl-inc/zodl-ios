//
//  ExportViewingKeysView.swift
//  Zodl
//

import ComposableArchitecture
import Perception
import SwiftUI

struct ExportViewingKeysView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Perception.Bindable var store: StoreOf<ExportViewingKeys>

    init(store: StoreOf<ExportViewingKeys>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            let consentPresented = store.isConsentPresented
            let sharingErrorPresented = store.sharingError
            let preparedNativeShare = eligibleNativeShare(
                payload: store.detail?.sharePayload,
                ownership: store.detail?.shareOwnership,
                isVisible: store.isPayloadVisible,
                isPresented: store.detail?.isSharePresented == true
            )

            Group {
                if store.detail != nil {
                    ViewingKeyDetailView(store: store)
                        .navigationTitle(String(localizable: .viewing_key_export))
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    chooser
                }
            }
            .zashiBack(customDismiss: { store.send(.backTapped) })
            .applyScreenBackground()
            .zashiSheet(
                isPresented: consentBinding(isPresented: consentPresented),
                onDismiss: { store.send(.consentDismissed) }
            ) {
                ViewingKeyConsentView(store: store)
            }
            .alert(
                String(localizable: .viewing_key_share_failure_title),
                isPresented: sharingErrorBinding(isPresented: sharingErrorPresented)
            ) {
                Button(String(localizable: .generalOk)) {
                    store.send(.dismissError)
                }
            } message: {
                Text(localizable: .viewing_key_share_failure_body)
            }
            .sheet(
                item: nativeShareBinding(nativeShare: preparedNativeShare),
                onDismiss: { store.send(.shareDismissed) }
            ) { nativeShare in
                let items = ViewingKeyShareItems(
                    payload: nativeShare.payload,
                    title: String(localizable: .viewing_key_export)
                )
                ViewingKeyActivityView(
                    activityItems: items.activityItems,
                    ownership: nativeShare.ownership,
                    onPresented: { store.send(.sharePresented) },
                    onCompletion: { store.send(.shareDismissed) }
                )
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .active:
                    store.send(.becameActive)
                case .inactive:
                    store.send(.becameInactive)
                case .background:
                    store.send(.enteredBackground)
                @unknown default:
                    store.send(.becameInactive)
                }
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ViewingKeyHeaderIcons(vendor: store.session.vendor)
                        .padding(.bottom, 16)

                    Text(localizable: .viewing_key_export)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .padding(.bottom, 4)

                    introText
                        .padding(.bottom, 24)

                    VStack(spacing: 8) {
                        ZashiSelectionCard(
                            title: String(localizable: .viewing_key_incoming_title),
                            subtitle: String(localizable: .viewing_key_incoming_description),
                            isSelected: store.selectedKind == .incoming
                        ) {
                            store.send(.selectKind(.incoming))
                        }

                        ZashiSelectionCard(
                            title: String(localizable: .viewing_key_full_title),
                            subtitle: String(localizable: .viewing_key_full_description),
                            isSelected: store.selectedKind == .full
                        ) {
                            store.send(.selectKind(.full))
                        }
                    }

                    if store.unavailableKey {
                        unavailableMessage
                            .padding(.top, 12)
                    }
                }
                .screenHorizontalPadding()
                .padding(.top, 12)
                .padding(.bottom, 24)
            }

            ZashiButton(
                String(localizable: .generalContinue),
                minHeight: 48,
                allowsMultilineTitle: true
            ) {
                store.send(.continueTapped)
            }
            .disabled(!store.canContinue)
            .screenHorizontalPadding()
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder private var introText: some View {
        let vendor = ViewingKeyPresentation.vendorName(for: store.session.vendor)
        let markdown = String(localizable: .viewing_key_intro(vendor))

        if let attributed = try? AttributedString(markdown: markdown, including: \.zashiApp) {
            ZashiText(withAttributedString: attributed, colorScheme: colorScheme)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(markdown)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unavailableMessage: some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.Icons.alertCircleOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)

            VStack(alignment: .leading, spacing: 2) {
                Text(localizable: .viewing_key_unavailable_title)
                    .zFont(.semiBold, size: 14, style: Design.Utility.ErrorRed._700)

                Text(localizable: .viewing_key_unavailable_body)
                    .zFont(size: 12, style: Design.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Design.Utility.ErrorRed._50.color(colorScheme))
        }
    }

    private func consentBinding(isPresented: Bool) -> Binding<Bool> {
        Binding(
            get: { isPresented },
            set: { updatedValue in
                if !updatedValue {
                    store.send(.cancelConsent)
                }
            }
        )
    }

    private func sharingErrorBinding(isPresented: Bool) -> Binding<Bool> {
        Binding(
            get: { isPresented },
            set: { updatedValue in
                if !updatedValue {
                    store.send(.dismissError)
                }
            }
        )
    }

    private func nativeShareBinding(nativeShare: ViewingKeyNativeShare?) -> Binding<ViewingKeyNativeShare?> {
        Binding(
            get: { nativeShare },
            set: { updatedShare in
                if updatedShare == nil {
                    store.send(.shareDismissed)
                }
            }
        )
    }

    private func eligibleNativeShare(
        payload: ViewingKeySharePayload?,
        ownership: ViewingKeyShareOwnership?,
        isVisible: Bool,
        isPresented: Bool
    ) -> ViewingKeyNativeShare? {
        guard let payload,
              let ownership,
              ownership.payloadID == payload.id,
              isVisible || isPresented || ownership.hasNativeOwnership else {
            return nil
        }
        return ViewingKeyNativeShare(payload: payload, ownership: ownership)
    }
}

private struct ViewingKeyHeaderIcons: View {
    @Environment(\.colorScheme) private var colorScheme
    let vendor: WalletAccount.Vendor

    var body: some View {
        HStack(spacing: -4) {
            vendorBadge

            Asset.Assets.Icons.search.image
                .zImage(size: 24, style: Design.Text.primary)
                .padding(12)
                .background {
                    Circle()
                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        .overlay {
                            Circle()
                                .stroke(Design.Surfaces.bgPrimary.color(colorScheme), lineWidth: 2)
                        }
                }
        }
    }

    @ViewBuilder private var vendorBadge: some View {
        switch vendor {
        case .keystone:
            Asset.Assets.Partners.keystone.image
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
        case .zcash:
            Asset.Assets.zashiLogo.image
                .resizable()
                .scaledToFit()
                .padding(8)
                .frame(width: 48, height: 48)
                .background {
                    Circle()
                        .fill(Asset.Colors.ZDesign.Base.obsidian.color)
                }
        }
    }
}
