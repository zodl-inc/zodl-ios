//
//  ScanView.swift
//  Zashi
//
//  Created by Lukáš Korba on 16.05.2022.
//

import SwiftUI
import Combine
import ComposableArchitecture
import Foundation

struct ScanView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) var openURL
    
    @State private var image: PlatformImage?
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
                            
#if os(iOS)
                            // iOS: the library picker sits below the scan cutout. macOS moves it to the
                            // window toolbar (`.toolbar` below) so nothing sits below the cutout.
                            if !store.forceLibraryToHide {
                                libraryButton(size: proxy.size)
                            }
#endif
                        }
                        
                        WithPerceptionTracking {
                            if store.progress != nil || store.isKeystoneSigningInProgress {
                                WithPerceptionTracking {
                                    progress(size: proxy.size, progress: store.isKeystoneSigningInProgress ? 100 : store.countedProgress)
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
                            
                            if store.isKeystoneSigningInProgress {
                                signingPill()
                                // Audit 2026-08-03 (#10): Cancel STAYS during the post-scan leg —
                                // the pill used to replace it, and with the back button hidden
                                // (camera up) that left a hung submit with no exit at all. The
                                // coordinator has always been built for a cancel landing
                                // mid-proving: the tombstone paths drop the late completion and
                                // the pop lands back on the signing screen with Reject / Get
                                // Signature intact.
                                primaryButton(String(localizable: .generalCancel)) {
                                    store.send(.cancelTapped)
                                }
                            } else if !store.isCameraEnabled {
                                primaryButton(String(localizable: .scanOpenSettings)) {
#if os(iOS)
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        openURL(url)
                                    }
#elseif os(macOS)
                                    // Deep-link to System Settings → Privacy & Security → Camera.
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                        openURL(url)
                                    }
#endif
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
            // RULE #9: scan is EXEMPT from the macOS 800pt content cap — the full-window gray-out
            // overlay + camera cutout must fill the whole window, not shrink to the content column.
            // (No-op on iOS, where there is no cap — Rule #11.)
            .applyScreenBackground(capped: false)
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
#if os(macOS)
            // macOS: the image-library picker lives in the window toolbar (like the Activity filter
            // button), so nothing sits below the scan cutout and it can be larger. Conditionally add the
            // whole ToolbarItem (not an empty one) so there's no stray glass capsule when it's hidden.
            .toolbar {
                if !store.forceLibraryToHide {
                    ToolbarItem(placement: .zashiTrailing) {
                        Button {
                            showSheet = true
                        } label: {
                            Image(systemName: "photo.on.rectangle")
                                .zashiToolbarIconPadding()
                        }
                    }
                }
            }
#endif
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
#if os(macOS)
                // RULE #7: cap the scan overlay buttons (Cancel / Open Settings) — never full-width.
                .frame(maxWidth: Design.Mac.maxButtonWidth)
#else
                .frame(maxWidth: .infinity)
#endif
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Asset.Colors.ZDesign.Base.bone.color)
                }
        }
        .padding(.bottom, 40)
    }

    /// PHASE 7: the disabled "Signing…" pill that replaces the Cancel button while
    /// `Scan.State.isKeystoneSigningInProgress` is armed — same geometry as `primaryButton` above,
    /// but non-interactive (no `Button`) and filled dark (`shark900`/`shark200`) to read as disabled.
    private func signingPill() -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(Asset.Colors.ZDesign.shark200.color)
            Text(String(localizable: .migrationKeystoneScanSigning))
                .font(.custom(FontFamily.Inter.semiBold.name, size: 16))
                .foregroundColor(Asset.Colors.ZDesign.shark200.color)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._xl)
                .fill(Asset.Colors.ZDesign.shark900.color)
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
            // [B4-1] The sign flow's larger cutout (popoverRatio 1.075) starts so close to the
            // window top that `topLeft.y - 56` landed ABOVE the visible bounds — the gold bar was
            // rendering, just off-screen (the account-import scan's smaller cutout kept it
            // visible). Clamp so the bar stays on-screen; with no headroom it overlaps the
            // cutout's top edge instead of vanishing.
            y: max(topLeft.y - 56, 36)
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
        let readRectSize = 0.6
        let topLeftX = (1.0 - readRectSize) * 0.5
        let real = CGRect(x: topLeftX, y: topLeftX, width: readRectSize, height: readRectSize)
#if os(macOS)
        // macOS: a large SQUARE cutout. The width fraction → height fraction is aspect-corrected by the
        // fixed window ratio (Design.Mac.windowWidth / windowHeight) so the rendered rect is square in
        // POINTS, not stretched to the landscape window. Sized to sit just above the Cancel CTA — the
        // library button now lives in the toolbar, so nothing sits below the cutout. (Camera scan zone
        // `real` unchanged; the iOS path is untouched — Rule #11.)
        let widthFraction = 0.54
        let renderOnly = CGRect(
            x: (1.0 - widthFraction) * 0.5,
            y: 0.1,
            width: widthFraction,
            height: widthFraction * (Design.Mac.windowWidth / Design.Mac.windowHeight)
        )
#else
        let rect = PlatformScreen.bounds
        let ratio = rect.width / rect.height
        let rectHeight = ratio * readRectSize * popoverRatio
        let topLeftY = (1.0 - rectHeight) * 0.5
        let renderOnly = CGRect(x: topLeftX, y: topLeftY, width: readRectSize, height: rectHeight)
#endif

        return (renderOnly: renderOnly, real: real)
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
    static var initial: Scan.State { Scan.State() }
}

extension Scan {
    @MainActor static let placeholder = StoreOf<Scan>(
        initialState: .initial
    ) {
        Scan()
    }
}
