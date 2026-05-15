//
//  RequestZecSummaryView.swift
//  Zashi
//
//  Created by Lukáš Korba on 09-30-2024.
//

import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct RequestZecSummaryView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<RequestZec>

    let tokenName: String
    
    init(store: StoreOf<RequestZec>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    var body: some View {
        WithPerceptionTracking {
            WithPerceptionTracking {
                VStack(spacing: 0) {
                    PrivacyBadge(store.maxPrivacy ? .max : .low)
                        .padding(.top, 24)
                    
                    Group {
                        Text(store.requestedZec.decimalString())
                        + Text(" \(tokenName)")
                            .foregroundColor(Design.Text.quaternary.color(colorScheme))
                    }
                    .zFont(.semiBold, size: 56, style: Design.Text.primary)
                    .minimumScaleFactor(0.1)
                    .lineLimit(1)
                    .padding(.top, 8)
                    
                    qrCode()
                        .frame(width: 216, height: 216)
                        .onAppear {
                            store.send(.generateQRCode(colorScheme == .dark ? true : false))
                        }
                        .padding(24)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .fill(Design.screenBackground.color(colorScheme))
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                                }
                        }
                        .padding(.top, 32)
                        .onTapGesture {
                            store.send(.qrCodeTapped, animation: .easeInOut)
                        }
                    
                    Spacer()
                    
                    ZashiButton(
                        String(localizable: .generalClose),
                        type: .ghost
                    ) {
                        store.send(.cancelRequestTapped)
                    }
                    .padding(.bottom, 8)
                    
                    ZashiButton(
                        String(localizable: .requestZecSummaryShareQR),
                        prefixView:
                            Asset.Assets.Icons.share.image
                            .zImage(size: 20, style: Design.Btns.Primary.fg)
                    ) {
                        store.send(.shareQR)
                    }
                    .padding(.bottom, 20)
                    .disabled(store.encryptedOutputToBeShared != nil)
                    
                    shareView()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .onAppear { store.send(.onAppear) }
                .onDisappear { store.send(.onDisappear) }
            }
            .screenTitle(String(localizable: .generalRequest))
            .screenHorizontalPadding()
            .applyScreenBackground()
            .zashiBack()
            .enlargeQR(isPresented: $store.isQRCodeEnlarged) {
                qrEnlargedCode()
                    .aspectRatio(1, contentMode: .fit)
                    .padding(48)
                    .background {
                        if store.storedEnlargedQR != nil {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .fill(Asset.Colors.ZDesign.Base.bone.color)
                                .padding(24)
                        }
                    }
            }
        }
    }
}

extension RequestZecSummaryView {
    @ViewBuilder func qrCode(_ qrText: String = "") -> some View {
        Group {
            if let storedImg = store.storedQR {
                Image(storedImg, scale: 1, label: Text(localizable: .qrCodeFor(qrText)))
                    .resizable()
            } else {
                ProgressView()
            }
        }
    }
    
    @ViewBuilder func qrEnlargedCode(_ qrText: String = "") -> some View {
        Group {
            if let storedImg = store.storedEnlargedQR {
                Image(storedImg, scale: 1, label: Text(localizable: .qrCodeFor(qrText)))
                    .resizable()
            } else {
                ProgressView()
            }
        }
    }
    
    @ViewBuilder func shareView() -> some View {
        if let encryptedOutput = store.encryptedOutputToBeShared,
           let cgImg = QRCodeGenerator.generateCode(
            from: encryptedOutput,
            maxPrivacy: store.maxPrivacy,
            vendor: .zashi,
            color: .black
           ) {
            UIShareDialogView(activityItems: [
                ShareableImage(
                    image: UIImage(cgImage: cgImg),
                    title: String(localizable: .requestZecSummaryShareTitle),
                    reason: String(localizable: .requestZecSummaryShareDesc)
                ), "\(String(localizable: .requestZecSummaryShareDesc)) \(String(localizable: .requestZecSummaryShareMsg))"
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
        RequestZecView(store: RequestZec.placeholder, tokenName: "ZEC")
    }
}
