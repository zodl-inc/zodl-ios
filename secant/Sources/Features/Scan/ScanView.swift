//
//  ScanView.swift
//  Zashi
//
//  Created by Lukáš Korba on 16.05.2022.
//

import SwiftUI
import ComposableArchitecture

struct ScanView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) var openURL
    
    @State private var image: UIImage?
    @State private var showSheet = false
    
    let store: StoreOf<Scan>
    let popoverRatio: CGFloat
    
    init(store: StoreOf<Scan>, popoverRatio: CGFloat = 1.0) {
        self.store = store
        self.popoverRatio = popoverRatio
    }
    
    var body: some View {
        WithPerceptionTracking {
            ZStack {
                if showSheet {
                    ZashiImagePicker(selectedImage: $image, showSheet: $showSheet)
                } else {
                    GeometryReader { proxy in
                        QRCodeScanView(
                            rectOfInterest: ScanView.normalizedRectsOfInterest(popoverRatio).real,
                            onQRScanningDidFail: { store.send(.scanFailed(.invalidQRCode)) },
                            onQRScanningSucceededWithCode: { store.send(.scan($0.redacted)) }
                        )
                        
                        frameOfInterest(proxy.size)
                        
                        WithPerceptionTracking {
                            if store.isTorchAvailable {
                                torchButton(size: proxy.size)
                            }
                            
                            if !store.forceLibraryToHide {
                                libraryButton(size: proxy.size)
                            }
                        }
                        
                        WithPerceptionTracking {
                            if store.progress != nil {
                                WithPerceptionTracking {
                                    progress(size: proxy.size, progress: store.countedProgress)
                                }
                            }
                        }
                    }
                    
                    VStack {
                        WithPerceptionTracking {
                            if let instructions = store.instructions {
                                Text(instructions)
                                    .font(.custom(FontFamily.Inter.semiBold.name, size: 20))
                                    .foregroundColor(Asset.Colors.ZDesign.shark200.color)
                                    .padding(.top, 64)
                                    .lineLimit(nil)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                                    .screenHorizontalPadding()
                            }
                            
                            Spacer()
                            
                            HStack(alignment: .top, spacing: 0) {
                                if !store.info.isEmpty {
                                    Asset.Assets.infoOutline.image
                                        .zImage(size: 20, color: Asset.Colors.ZDesign.shark200.color)
                                        .padding(.trailing, 12)
                                    
                                    Text(store.info)
                                        .font(.custom(FontFamily.Inter.medium.name, size: 12))
                                        .foregroundColor(Asset.Colors.ZDesign.shark200.color)
                                        .padding(.top, 2)
                                    
                                    Spacer(minLength: 0)
                                }
                            }
                            .padding(.bottom, 15)
                            
                            if !store.isCameraEnabled {
                                primaryButton(String(localizable: .scanOpenSettings)) {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        openURL(url)
                                    }
                                }
                            } else {
                                primaryButton(String(localizable: .generalCancel)) {
                                    store.send(.cancelTapped)
                                }
                            }
                        }
                    }
                    .screenHorizontalPadding()
                }
            }
            .edgesIgnoringSafeArea(.all)
            .ignoresSafeArea()
            .applyScreenBackground()
            .onAppear { store.send(.onAppear) }
            .onDisappear { store.send(.onDisappear) }
            .zashiBackV2(hidden: store.isCameraEnabled, invertedColors: colorScheme == .light) {
                store.send(.cancelTapped)
            }
            .onChange(of: image) { img in
                if let img {
                    store.send(.libraryImage(img))
                }
            }
        }
    }
    
    private func primaryButton(_ text: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(text)
                .font(.custom(FontFamily.Inter.semiBold.name, size: 16))
                .foregroundColor(Asset.Colors.ZDesign.Base.obsidian.color)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Asset.Colors.ZDesign.Base.bone.color)
                }
        }
        .padding(.bottom, 40)
    }
    
    private func torchButton(size: CGSize) -> some View {
        let topLeft = ScanView.rectOfInterest(size, popoverRatio).origin
        let frameSize = ScanView.frameSize(size, popoverRatio)

        return WithPerceptionTracking {
            Button {
                store.send(.torchTapped)
            } label: {
                if store.isTorchOn {
                    Asset.Assets.Icons.flashOff.image
                        .zImage(size: 24, color: Asset.Colors.ZDesign.shark50.color)
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .fill(Asset.Colors.ZDesign.shark900.color)
                        }
                } else {
                    Asset.Assets.Icons.flashOn.image
                        .zImage(size: 24, color: Asset.Colors.ZDesign.shark50.color)
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                .fill(Asset.Colors.ZDesign.shark900.color)
                        }
                }
            }
            .position(
                x: topLeft.x + frameSize.width * 0.5 + (store.forceLibraryToHide ? 0 : 35),
                y: topLeft.y + frameSize.height + 45
            )
        }
    }
    
    private func libraryButton(size: CGSize) -> some View {
        let topLeft = ScanView.rectOfInterest(size, popoverRatio).origin
        let frameSize = ScanView.frameSize(size, popoverRatio)

        return WithPerceptionTracking {
            Button {
                showSheet = true
            } label: {
                Asset.Assets.Icons.imageLibrary.image
                    .zImage(size: 24, color: Asset.Colors.ZDesign.shark50.color)
                    .padding(12)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                            .fill(Asset.Colors.ZDesign.shark900.color)
                    }
            }
            .position(
                x: topLeft.x + frameSize.width * 0.5 - (store.isTorchAvailable ? 35 : 0),
                y: topLeft.y + frameSize.height + 45
            )
        }
    }
    
    private func progress(size: CGSize, progress: Int) -> some View {
        let topLeft = ScanView.rectOfInterest(size, popoverRatio).origin
        let frameSize = ScanView.frameSize(size, popoverRatio)

        return VStack {
            Text(String(format: "%d%%", progress))
                .font(.custom(FontFamily.Inter.semiBold.name, size: 16))
                .foregroundColor(Asset.Colors.ZDesign.shark50.color)
                .padding(.bottom, 4)
            ProgressView(value: Float(progress), total: Float(100))
        }
        .frame(width: frameSize.width * 0.8)
        .tint(Asset.Colors.ZDesign.Base.brand.color)
        .position(
            x: topLeft.x + frameSize.width * 0.5,
            y: topLeft.y - 56
        )
    }
}

extension ScanView {
    func frameOfInterest(_ size: CGSize) -> some View {
        let topLeft = ScanView.rectOfInterest(size, popoverRatio).origin
        let frameSize = ScanView.frameSize(size, popoverRatio)
        let sizeOfTheMark = 40.0
        let markShiftSize = 18.0

        return ZStack {
            Color.black
                .opacity(0.65)
                .edgesIgnoringSafeArea(.all)
                .ignoresSafeArea()
                .reverseMask(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 28)
                        .frame(
                            width: frameSize.width,
                            height: frameSize.height,
                            alignment: .topLeading
                        )
                        .offset(
                            x: topLeft.x,
                            y: topLeft.y
                        )
                }

            // top right
            Asset.Assets.scanMark.image
                .resizable()
                .frame(width: sizeOfTheMark, height: sizeOfTheMark)
                .position(
                    x: topLeft.x + frameSize.width - markShiftSize,
                    y: topLeft.y + markShiftSize
                )

            // top left
            Asset.Assets.scanMark.image
                .resizable()
                .frame(width: sizeOfTheMark, height: sizeOfTheMark)
                .rotationEffect(Angle(degrees: 270))
                .position(
                    x: topLeft.x + markShiftSize,
                    y: topLeft.y + markShiftSize
                )

            // bottom left
            Asset.Assets.scanMark.image
                .resizable()
                .frame(width: sizeOfTheMark, height: sizeOfTheMark)
                .rotationEffect(Angle(degrees: 180))
                .position(
                    x: topLeft.x + markShiftSize,
                    y: topLeft.y + frameSize.height - markShiftSize
                )

            // bottom right
            Asset.Assets.scanMark.image
                .resizable()
                .frame(width: sizeOfTheMark, height: sizeOfTheMark)
                .rotationEffect(Angle(degrees: 90))
                .position(
                    x: topLeft.x + frameSize.width - markShiftSize,
                    y: topLeft.y + frameSize.height - markShiftSize
                )
        }
    }
}

extension View {
    @inlinable
    func reverseMask<Mask: View>(
        alignment: Alignment = .center,
        @ViewBuilder _ mask: () -> Mask
    ) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: alignment) {
                    mask()
                        .blendMode(.destinationOut)
                }
        }
    }
}

extension ScanView {
    static func frameSize(_ size: CGSize, _ popoverRatio: CGFloat) -> CGSize {
        let rect = normalizedRectsOfInterest(popoverRatio).renderOnly
        
        return CGSize(width: rect.width * size.width, height: rect.height * size.height)
    }

    static func rectOfInterest(_ size: CGSize, _ popoverRatio: CGFloat) -> CGRect {
        let rect = normalizedRectsOfInterest(popoverRatio).renderOnly

        return CGRect(
            x: size.width * rect.origin.x,
            y: size.height * rect.origin.y,
            width: frameSize(size, popoverRatio).width,
            height: frameSize(size, popoverRatio).height
        )
    }

    static func normalizedRectsOfInterest(_ popoverRatio: CGFloat) -> (renderOnly: CGRect, real: CGRect) {
        let rect = UIScreen.main.bounds
        
        let readRectSize = 0.6

        let topLeftX = (1.0 - readRectSize) * 0.5
        let ratio = rect.width / rect.height
        let rectHeight = ratio * readRectSize * popoverRatio
        let topLeftY = (1.0 - rectHeight) * 0.5

        return (
            renderOnly: CGRect(
                x: topLeftX,
                y: topLeftY,
                width: readRectSize,
                height: rectHeight
            ), real: CGRect(
                x: topLeftX,
                y: topLeftX,
                width: readRectSize,
                height: readRectSize
            )
        )
    }
}

// MARK: - Previews

struct ScanView_Previews: PreviewProvider {
    static var previews: some View {
        ScanView(store: Scan.placeholder)
    }
}

// MARK: Placeholders

extension Scan.State {
    static var initial = Scan.State()
}

extension Scan {
    static let placeholder = StoreOf<Scan>(
        initialState: .initial
    ) {
        Scan()
    }
}
