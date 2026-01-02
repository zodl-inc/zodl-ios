//
//  SignWithKeystoneView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2024-11-29.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit

import Generated
import UIComponents
import Utils
import KeystoneSDK
import Vendors
import SDKSynchronizer
import Scan
import URKit

public struct SignWithKeystoneView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.presentationMode) var presentationMode

    @Perception.Bindable var store: StoreOf<SendConfirmation>

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer

    @State private var previousBrightness: CGFloat = UIScreen.main.brightness
    @State private var isPresented = false
    
    let tokenName: String
    
    public init(store: StoreOf<SendConfirmation>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Asset.Assets.Partners.keystoneLogo.image
                                .resizable()
                                .frame(width: 24, height: 24)
                                .padding(8)
                                .background {
                                    Circle()
                                        .fill(Design.Surfaces.bgAlt.color(colorScheme))
                                }
                                .padding(.trailing, 12)
                            
                            VStack(alignment: .leading, spacing: 0) {
                                Text(L10n.Accounts.keystone)
                                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                
                                Text(store.selectedWalletAccount?.unifiedAddress?.zip316 ?? "")
                                    .zFont(addressFont: true, size: 12, style: Design.Text.tertiary)
                            }
                            
                            Spacer()
                            
                            Text(L10n.Keystone.SignWith.hardware)
                                .zFont(.medium, size: 12, style: Design.Utility.HyperBlue._700)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 8)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                        .fill(Design.Utility.HyperBlue._50.color(colorScheme))
                                        .background {
                                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                                .stroke(Design.Utility.HyperBlue._200.color(colorScheme))
                                        }
                                }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                        }
                        .padding(.top, 40)

                        if let pczt = store.pcztForUI, let encoder = sdkSynchronizer.urEncoderForPCZT(pczt), !isPresented {
                            AnimatedQRCode(urEncoder: encoder, size: 250)
                                .frame(width: 216, height: 216)
                                .padding(24)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .fill(Asset.Colors.ZDesign.Base.bone.color)
                                        .background {
                                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                                .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                                        }
                                }
                                .padding(.top, 32)
                                .onTapGesture {
                                    withAnimation {
                                        isPresented = true
                                    }
                                }
                        } else {
                            VStack {
                                ProgressView()
                            }
                            .frame(width: 216, height: 216)
                            .padding(24)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._xl)
                                    .fill(Asset.Colors.ZDesign.Base.bone.color)
                                    .background {
                                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                                            .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
                                    }
                            }
                            .padding(.top, 32)
                        }

                        Text(L10n.Keystone.SignWith.title)
                            .zFont(.medium, size: 16, style: Design.Text.primary)
                            .padding(.top, 32)
                        
                        Text(L10n.Keystone.SignWith.desc)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .screenHorizontalPadding()
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }

                #if DEBUG
                ZashiButton(
                    "Share PCZT",
                    type: .ghost
                ) {
                    store.send(.sharePCZT)
                }
                .padding(.top, 16)
                #endif

                Spacer()

                ZashiButton(
                    L10n.Keystone.SignWith.reject,
                    type: .destructive1
                ) {
                    store.send(.rejectRequested)
                }
                .padding(.bottom, 8)

                ZashiButton(
                    L10n.Keystone.SignWith.getSignature
                ) {
                    store.send(.getSignatureTapped)
                }
                .padding(.bottom, 24)

                shareView()
            }
            .zashiSheet(isPresented: $store.rejectSendRequest) {
                rejectSendContent(colorScheme: colorScheme)
            }
            .onAppear {
                store.send(.onAppear)
                previousBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 1.0
            }
            .onChange(of: presentationMode.wrappedValue.isPresented) { isPresented in
                if !isPresented {
                    UIScreen.main.brightness = previousBrightness
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        .screenHorizontalPadding()
        .applyScreenBackground()
        .zashiBack(hidden: true)
        .navigationBarTitleDisplayMode(.inline)
        .screenTitle(L10n.Keystone.SignWith.signTransaction)
        .overlay {
            if let pczt = store.pcztForUI, let encoder = sdkSynchronizer.urEncoderForPCZT(pczt), isPresented {
                Color.black.opacity(0.9)
                    .edgesIgnoringSafeArea(.all)
                    .onTapGesture {
                        isPresented = false
                    }
                
                AnimatedQRCode(urEncoder: encoder, size: UIScreen.main.bounds.width - 64)
                    .padding()
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._4xl)
                            .fill(Color.white)
                    }
                    .onTapGesture {
                        isPresented = false
                    }
            }
        }
    }
}

extension SignWithKeystoneView {
    @ViewBuilder func shareView() -> some View {
        if let pczt = store.pcztToShare {
            UIShareDialogView(activityItems: [pczt]) {
                store.send(.shareFinished)
            }
            .frame(width: 0, height: 0)
        }
    }
}
