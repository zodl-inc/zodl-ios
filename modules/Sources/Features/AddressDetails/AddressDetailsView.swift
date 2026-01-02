//
//  AddressDetailsView.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-19-2024.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit

import Generated
import UIComponents
import Utils

public struct AddressDetailsView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<AddressDetails>
    
    public init(store: StoreOf<AddressDetails>) {
        self.store = store
    }
    
    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        Button {
                            store.send(.qrCodeTapped)
                        } label: {
                            qrCode(store.address.data)
                                .frame(width: 216, height: 216)
                                .onAppear {
                                    store.send(.generateQRCode(colorScheme == .dark ? true : false))
                                }
                                .padding(24)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .fill(store.isQRCodeAppreanceFlipped
                                               ? Asset.Colors.ZDesign.Base.bone.color
                                               : Design.screenBackground.color(colorScheme)
                                        )
                                        .background {
                                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                                        }
                                }
                                .padding(.top, 40)
                        }
                        
                        PrivacyBadge(store.maxPrivacy ? .max : .low)
                            .padding(.top, 32)
                        
                        Text(store.addressTitle)
                            .zFont(.semiBold, size: 20, style: Design.Text.primary)
                            .padding(.top, 12)
                        
                        Text(store.address.data)
                            .zFont(addressFont: true, size: 14, style: Design.Text.tertiary)
                            .lineLimit(store.isAddressExpanded ? nil : 2)
                            .truncationMode(.middle)
                            .padding(.top, 8)
                            .onTapGesture {
                                store.send(.addressTapped)
                            }
                            .onLongPressGesture {
                                store.send(.copyToPastboard)
                            }
                    }
                }

                Spacer()
                
                ZashiButton(
                    L10n.AddressDetails.shareQR,
                    prefixView:
                        Asset.Assets.Icons.share.image
                            .zImage(size: 20, style: Design.Btns.Primary.fg)
                ) {
                    store.send(.shareQR)
                }
                .padding(.bottom, 8)
                .disabled(store.addressToShare != nil)

                ZashiButton(
                    L10n.AddressDetails.copyAddress,
                    type: .ghost,
                    prefixView:
                        Asset.Assets.copy.image
                            .zImage(size: 20, style: Design.Btns.Ghost.fg)
                ) {
                    store.send(.copyToPastboard)
                }
                .padding(.bottom, 20)

                shareView()
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .onAppear { store.send(.onAppear) }
            .onDisappear { store.send(.onDisappear) }
        }
        .screenHorizontalPadding()
        .applyScreenBackground()
        .zashiBack()
    }
}

extension AddressDetailsView {
    @ViewBuilder public func qrCode(_ qrText: String) -> some View {
        Group {
            if let storedImg = store.storedQR {
                Image(storedImg, scale: 1, label: Text(L10n.qrCodeFor(qrText)))
                    .resizable()
            } else {
                ProgressView()
            }
        }
    }
    
    @ViewBuilder func shareView() -> some View {
        if let addressToShare = store.addressToShare,
           let cgImg = QRCodeGenerator.generateCode(
            from: addressToShare.data,
            maxPrivacy: store.maxPrivacy,
            vendor: .zashi,
            color: .black
           ) {
            UIShareDialogView(activityItems: [
                ShareableImage(
                    image: UIImage(cgImage: cgImg),
                    title: L10n.AddressDetails.shareTitle,
                    reason: L10n.AddressDetails.shareDesc
                ), L10n.AddressDetails.shareDesc
            ]) {
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

#Preview {
    NavigationView {
        AddressDetailsView(
            store: StoreOf<AddressDetails>(
                initialState: AddressDetails.State(address: "u1steuf7460a4m3svyyzlg3m6xlc6xd0q5qq7n0da8m29x0vcqdeuvjyw4h82a69vg8zn43cszudgfva45d2ju46227vc0dy0f73mzdv5dsz4wfmfrkaw3ycmd4qkg9hxh3arcrh2f9fdj02d42shg7fl5elvnqed4cq4t3sxu4spcx7cd4l8ye3e5ym9njj0hhs82gf7tjre4umqa2q6".redacted)
            ) {
                AddressDetails()
            }
        )
    }
}

// MARK: - Placeholders

extension AddressDetails.State {
    public static let initial = AddressDetails.State()
}

extension AddressDetails {
    public static let placeholder = StoreOf<AddressDetails>(
        initialState: .initial
    ) {
        AddressDetails()
    }
}
