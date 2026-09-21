//
//  ViewingKeyConsentView.swift
//  Zodl
//

import ComposableArchitecture
import Perception
import SwiftUI

struct ViewingKeyConsentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<ExportViewingKeys>

    init(store: StoreOf<ExportViewingKeys>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(localizable: .viewing_key_warning_title)
                            .zFont(.semiBold, size: 20, style: Design.Text.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 24)

                        warning
                            .padding(.top, 16)

                        VStack(alignment: .leading, spacing: 16) {
                            consentToggle(
                                .history,
                                isAccepted: store.consent.contains(.history),
                                label: String(localizable: .viewing_key_acknowledge_history)
                            )
                            consentToggle(
                                .recipient,
                                isAccepted: store.consent.contains(.recipient),
                                label: String(localizable: .viewing_key_acknowledge_recipient)
                            )
                            consentToggle(
                                .irreversible,
                                isAccepted: store.consent.contains(.irreversible),
                                label: String(localizable: .viewing_key_acknowledge_irreversible)
                            )
                        }
                        .padding(.top, 20)
                    }
                }
                .frame(minHeight: 220, maxHeight: 520)

                VStack(spacing: 12) {
                    consentButtons
                }
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 12) {
            Asset.Assets.Icons.alertCircleOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)

            Text(localizable: .viewing_key_warning_body)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
    }

    @ViewBuilder private func consentToggle(
        _ item: ViewingKeyConsent,
        isAccepted: Bool,
        label: String
    ) -> some View {
        ZashiToggle(
            isOn: Binding(
                get: { isAccepted },
                set: { store.send(.consentChanged(item, $0)) }
            ),
            label: label
        )
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder private var consentButtons: some View {
        ZashiButton(
            String(localizable: .generalCancel),
            type: .secondary,
            minHeight: 48,
            allowsMultilineTitle: true
        ) {
            store.send(.cancelConsent)
        }

        ZashiButton(
            String(localizable: .viewing_key_export_key),
            minHeight: 48,
            allowsMultilineTitle: true
        ) {
            store.send(.exportFullTapped)
        }
        .disabled(!store.canExportFull)
    }
}
