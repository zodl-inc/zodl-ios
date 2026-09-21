//
//  ViewingKeyDetailView.swift
//  Zodl
//

import ComposableArchitecture
import Foundation
import Perception
import SwiftUI
import UIKit

enum ViewingKeyPayloadPresentation: Equatable {
    case hidden(text: String, accessibilityLabel: String)
    case revealed(key: String?, png: Data?)
}

enum ViewingKeyPresentation {
    static let hiddenText = "•••• •••• •••• ••••"

    static func payload(
        isVisible: Bool,
        key: ViewingKeyMaterial?,
        png: ViewingKeyPNG?
    ) -> ViewingKeyPayloadPresentation {
        guard isVisible else {
            return .hidden(
                text: hiddenText,
                accessibilityLabel: String(localizable: .viewing_key_hidden)
            )
        }
        return .revealed(key: key?.rawValue, png: png?.data)
    }

    static func title(for kind: ViewingKeyKind) -> String {
        switch kind {
        case .incoming:
            return String(localizable: .viewing_key_your_incoming)
        case .full:
            return String(localizable: .viewing_key_your_full)
        }
    }

    static func vendorName(for vendor: WalletAccount.Vendor) -> String {
        vendor.name()
    }
}

struct ViewingKeyDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Perception.Bindable var store: StoreOf<ExportViewingKeys>

    init(store: StoreOf<ExportViewingKeys>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            if let detail = store.detail {
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            detailContent(detail: detail)
                            footerIfAvailable(detail: detail)
                                .padding(.top, 24)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .screenHorizontalPadding()
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                } else {
                    VStack(spacing: 0) {
                        ScrollView {
                            detailContent(detail: detail)
                                .screenHorizontalPadding()
                                .padding(.top, 12)
                                .padding(.bottom, 24)
                        }

                        footerIfAvailable(detail: detail)
                            .screenHorizontalPadding()
                            .padding(.top, 12)
                            .padding(.bottom, 24)
                    }
                }
            }
        }
    }

    private func detailContent(detail: ExportViewingKeys.State.Detail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ViewingKeyPresentation.title(for: detail.kind))
                .zFont(.semiBold, size: 24, style: Design.Text.primary)

            Text(subtitle(for: detail.kind))
                .zFont(size: 14, style: Design.Text.tertiary)
                .padding(.top, 4)

            ZashiSegmentedControl(
                options: ViewingKeyTab.allCases,
                selection: detail.tab,
                title: tabTitle,
                onSelect: { store.send(.selectTab($0)) }
            )
            .padding(.top, 24)

            payloadContent(detail: detail)
                .padding(.top, 16)
        }
    }

    @ViewBuilder private func footerIfAvailable(detail: ExportViewingKeys.State.Detail) -> some View {
        if !(detail.tab == .qrCode && detail.qrFailed) {
            footer(detail: detail)
        }
    }

    @ViewBuilder private func payloadContent(detail: ExportViewingKeys.State.Detail) -> some View {
        if detail.tab == .qrCode && detail.qrFailed {
            qrFailure(kind: detail.kind)
        } else {
            switch ViewingKeyPresentation.payload(
                isVisible: store.isPayloadVisible,
                key: detail.key,
                png: detail.qr
            ) {
            case let .hidden(text, accessibilityLabel):
                hiddenContent(tab: detail.tab, text: text, accessibilityLabel: accessibilityLabel)
            case let .revealed(key, png):
                revealedContent(tab: detail.tab, key: key, png: png)
            }
        }
    }

    @ViewBuilder private func hiddenContent(
        tab: ViewingKeyTab,
        text: String,
        accessibilityLabel: String
    ) -> some View {
        VStack(spacing: 16) {
            Group {
                switch tab {
                case .qrCode:
                    qrPayloadCard {
                        HiddenViewingKeyQR()
                            .frame(maxWidth: 280, minHeight: 280, maxHeight: 280)
                    }
                case .keyString:
                    Text(text)
                        .zFont(.medium, fontFamily: .robotoMono, size: 16, style: Design.Text.primary)
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                        .padding(20)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func revealedContent(
        tab: ViewingKeyTab,
        key: String?,
        png: Data?
    ) -> some View {
        switch tab {
        case .qrCode:
            if let png, let image = UIImage(data: png) {
                displayedQRCode(image)
            } else {
                qrPayloadCard {
                    ProgressView()
                        .frame(maxWidth: 280, minHeight: 280)
                }
            }
        case .keyString:
            if let key {
                Text(key)
                    .zFont(fontFamily: .robotoMono, size: 14, style: Design.Text.primary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(20)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._2xl)
                            .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    }
            }
        }
    }

    @ViewBuilder private func displayedQRCode(_ image: UIImage) -> some View {
        let content = Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 280, minHeight: 280, maxHeight: 280)
            .accessibilityLabel(String(localizable: .viewing_key_qr_code))

        qrPayloadCard {
            if colorScheme == .dark {
                content
                    .colorInvert()
                    .blendMode(.screen)
            } else {
                content
                    .blendMode(.multiply)
            }
        }
    }

    private func qrPayloadCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))

            content()
                .padding(20)
        }
        .frame(maxWidth: .infinity)
        .compositingGroup()
    }

    private func footer(detail: ExportViewingKeys.State.Detail) -> some View {
        VStack(spacing: 12) {
            helper(kind: detail.kind, tab: detail.tab)

            ZashiButton(
                String(localizable: .generalShare),
                type: .tertiary,
                minHeight: 48,
                allowsMultilineTitle: true,
                prefixView: Asset.Assets.Icons.share.image.zImage(size: 20, style: Design.Btns.Tertiary.fg)
            ) {
                store.send(.shareTapped)
            }
            .disabled(!store.canShare)

            ZashiButton(
                detail.isRevealed
                    ? String(localizable: .viewing_key_hide)
                    : String(localizable: .viewing_key_reveal),
                minHeight: 48,
                allowsMultilineTitle: true,
                prefixView: (detail.isRevealed ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image)
                    .zImage(size: 20, style: Design.Btns.Primary.fg)
            ) {
                store.send(detail.isRevealed ? .hideTapped : .revealTapped)
            }
        }
    }

    private func helper(kind: ViewingKeyKind, tab: ViewingKeyTab) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Asset.Assets.infoCircle.image
                .zImage(
                    size: 20,
                    style: kind == .full ? Design.Utility.ErrorRed._500 : Design.Text.tertiary
                )

            Text(helperText(kind: kind, tab: tab))
                .zFont(
                    size: 12,
                    style: kind == .full ? Design.Utility.ErrorRed._700 : Design.Text.tertiary
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private func qrFailure(kind: ViewingKeyKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Asset.Assets.Icons.alertCircleOutline.image
                .zImage(size: 28, style: Design.Utility.ErrorRed._500)

            Text(localizable: .viewing_key_qr_failure_title)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)

            Text(localizable: .viewing_key_qr_failure_body)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ZashiButton(
                String(localizable: .viewing_key_display_string),
                minHeight: 48,
                allowsMultilineTitle: true
            ) {
                store.send(.displayKeyString)
            }

            ZashiButton(
                String(localizable: .viewing_key_go_back),
                type: .secondary,
                minHeight: 48,
                allowsMultilineTitle: true
            ) {
                store.send(.backTapped)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(Design.Surfaces.bgSecondary.color(colorScheme))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ViewingKeyPresentation.title(for: kind))
    }

    private func subtitle(for kind: ViewingKeyKind) -> String {
        switch kind {
        case .incoming:
            return String(localizable: .viewing_key_incoming_subtitle)
        case .full:
            return String(localizable: .viewing_key_full_subtitle)
        }
    }

    private func tabTitle(_ tab: ViewingKeyTab) -> String {
        switch tab {
        case .qrCode:
            return String(localizable: .viewing_key_qr_code)
        case .keyString:
            return String(localizable: .viewing_key_key_string)
        }
    }

    private func helperText(kind: ViewingKeyKind, tab: ViewingKeyTab) -> String {
        switch (kind, tab) {
        case (.incoming, .qrCode):
            return String(localizable: .viewing_key_scan_helper)
        case (.full, .qrCode):
            return String(localizable: .viewing_key_full_qr_helper)
        case (.incoming, .keyString):
            return String(localizable: .viewing_key_incoming_string_helper)
        case (.full, .keyString):
            return String(localizable: .viewing_key_full_string_helper)
        }
    }
}

private struct HiddenViewingKeyQR: View {
    @Environment(\.colorScheme) private var colorScheme

    private let modules = [
        0, 1, 2, 5, 6, 8, 10, 11,
        13, 14, 16, 18, 19, 22, 24, 25,
        27, 29, 31, 32, 34, 36, 38, 40,
        42, 44, 45, 47, 49, 51, 52, 54,
        56, 58, 60, 62, 64, 65, 68, 70,
        72, 73, 76, 78, 80
    ]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let cell = side / 9

            ZStack {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))

                ForEach(modules, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Design.Text.quaternary.color(colorScheme))
                        .frame(width: cell * 0.72, height: cell * 0.72)
                        .position(
                            x: cell * (CGFloat(index % 9) + 0.5),
                            y: cell * (CGFloat(index / 9) + 0.5)
                        )
                }
            }
            .frame(width: side, height: side)
            .blur(radius: 8)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
