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
    @ScaledMetric(relativeTo: .headline) private var titleLeading: CGFloat = 1.8
    @ScaledMetric(relativeTo: .body) private var bodyLeading: CGFloat = 3.05

    init(store: StoreOf<ExportViewingKeys>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    consentContent
                    consentButtons
                        .padding(.top, 32)
                        .padding(.bottom, 32)
                }
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        consentContent
                    }

                    consentButtons
                        .padding(.top, 32)
                        .padding(.bottom, 32)
                }
            }
        }
    }

    private var consentContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(localizable: .viewing_key_warning_title)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .tracking(-0.32)
                .lineSpacing(titleLeading)
                .padding(.vertical, titleLeading / 2)
                .fixedSize(horizontal: false, vertical: true)

            warning

            VStack(alignment: .leading, spacing: 12) {
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
        }
        // The native grabber sits over the sheet content rather than reserving header space.
        .padding(.top, 26 + 8)
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 12) {
            Asset.Assets.Icons.alertCircle.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)

            Text(localizable: .viewing_key_warning_body)
                .zFont(.medium, size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .lineSpacing(bodyLeading)
                .padding(.vertical, bodyLeading / 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgPrimary.color(colorScheme))
        }
    }

    @ViewBuilder private func consentToggle(
        _ item: ViewingKeyConsent,
        isAccepted: Bool,
        label: String
    ) -> some View {
        let isOn = Binding(
            get: { isAccepted },
            set: { store.send(.consentChanged(item, $0)) }
        )
        ZashiToggle(
            isOn: isOn,
            label: label,
            textSize: 14,
            checkboxSpacing: 12,
            checkboxTopPadding: 2,
            textTracking: -0.224,
            textLineSpacing: bodyLeading,
            textVerticalPadding: bodyLeading / 2,
            expandsTextVertically: true
        )
        .accessibilityRepresentation {
            Toggle(label, isOn: isOn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var consentButtons: some View {
        VStack(spacing: 12) {
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
}
