//
//  SmartBannerView.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-03-14.
//

import SwiftUI
import ComposableArchitecture

import Generated
import Generated
import UIComponents

enum SBConstants {
    static let fixedHeight: CGFloat = 32
    static let fixedHeightWithShadow: CGFloat = 36
    static let shadowHeight: CGFloat = 4
}

public struct SmartBannerView: View {
    @Environment(\.colorScheme) var colorScheme

    @Perception.Bindable var store: StoreOf<SmartBanner>
    
    @State private var realHeight: CGFloat = 100
    @State private var isUnhidden = false
    @State private var height: CGFloat = 0
    let tokenName: String

    public init(store: StoreOf<SmartBanner>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }
    
    public var body: some View {
        WithPerceptionTracking {
            ZStack(alignment: .top) {
                BottomRoundedRectangle(radius: SBConstants.fixedHeight)
                    .frame(height: SBConstants.fixedHeight)
                    .foregroundColor(Design.screenBackground.color(colorScheme))
                    .shadow(color: Design.Text.primary.color(colorScheme).opacity(store.isOpen ? 0.25 : 0), radius: 1)
                    .zIndex(1)
                
                VStack(spacing: 0) {
                    if store.isOpen {
                        priorityContent()
                            .padding(.vertical, 16)
                            .padding(.top, SBConstants.fixedHeight)
                            .screenHorizontalPadding()
                    }
                    
                    TopRoundedRectangle(radius: store.isOpen ? SBConstants.fixedHeight : 0)
                        .frame(height: SBConstants.fixedHeightWithShadow)
                        .foregroundColor(Design.screenBackground.color(colorScheme))
                        .shadow(color: Design.Text.primary.color(colorScheme).opacity(0.1), radius: store.isOpen ? 1 : 0, y: -1)
                }
                .frame(minHeight: SBConstants.fixedHeight + SBConstants.shadowHeight)
                
                if let supportData = store.supportData {
                    UIMailDialogView(
                        supportData: supportData,
                        completion: {
                            store.send(.sendSupportMailFinished)
                        }
                    )
                    // UIMailDialogView only wraps MFMailComposeViewController presentation
                    // so frame is set to 0 to not break SwiftUI's layout
                    .frame(width: 0, height: 0)
                }
                
                shareMessageView()
            }
            .zashiSheet(isPresented: $store.isSmartBannerSheetPresented) {
                helpSheetContent()
            }
            .zashiSheet(isPresented: $store.isSyncTimedOutSheetPresented) {
                syncTimedSheetContent()
            }
            .onAppear { store.send(.onAppear) }
            .onDisappear { store.send(.onDisappear) }
            .background {
                VStack(spacing: 0) {
                    Design.screenBackground.color(colorScheme)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: Design.Utility.Purple._700.color(.light), location: 0.00),
                            Gradient.Stop(color: Design.Utility.Purple._950.color(.light), location: 1.00)
                        ],
                        startPoint: UnitPoint(x: 0.5, y: 0.0),
                        endPoint: UnitPoint(x: 0.5, y: 1.0)
                    )
                    Design.screenBackground.color(colorScheme)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
                .onTapGesture {
                    store.send(.smartBannerContentTapped)
                }
            }
            .clipShape( Rectangle() )
        }
    }
}

extension SmartBannerView {
    @ViewBuilder func shareMessageView() -> some View {
        if let message = store.messageToBeShared {
            UIShareDialogView(activityItems: [message]) {
                store.send(.shareFinished)
            }
            // UIShareDialogView only wraps UIActivityViewController presentation
            // so frame is set to 0 to not break SwiftUI's layout
            .frame(width: 0, height: 0)
        } else {
            EmptyView()
        }
    }
    
    @ViewBuilder private func syncTimedSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Asset.Assets.infoOutline.image
                .zImage(size: 20, style: Design.Utility.ErrorRed._500)
                .background {
                    Circle()
                        .fill(Design.Utility.ErrorRed._50.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)
                .padding(.leading, 12)

            Text(L10n.Sheet.SyncTimeout.title)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)
            
            Text(L10n.Sheet.SyncTimeout.desc)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .padding(.bottom, Design.Spacing._3xl)
            
            ActionRow(
                icon: Asset.Assets.Icons.server.image,
                title: L10n.Sheet.SyncTimeout.server,
                divider: false,
                horizontalPadding: Design.Spacing._xl
            ) {
                store.send(.serverSwitchRequested)
            }
            .padding(.bottom, Design.Spacing._lg)
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
            }
            .padding(.bottom, 8)

            ActionRow(
                icon: Asset.Assets.Icons.powerOff.image,
                title: L10n.Sheet.SyncTimeout.tor,
                divider: false,
                horizontalPadding: Design.Spacing._xl
            ) {
                store.send(.torSettingsRequested)
            }
            .padding(.bottom, Design.Spacing._lg)
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius._xl)
                    .stroke(Design.Surfaces.strokeSecondary.color(colorScheme))
            }
            .padding(.bottom, 32)

            ZashiButton(L10n.ErrorPage.Action.contactSupport) {
                store.send(.reportTapped)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
}

// MARK: - Store

extension SmartBanner {
    public static var initial = StoreOf<SmartBanner>(
        initialState: .initial
    ) {
        SmartBanner()
    }
}

// MARK: - Placeholders

extension SmartBanner.State {
    public static let initial = SmartBanner.State()
}

// MARK: - Helpers

struct BottomRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        
        return Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: width, y: 0))
            path.addLine(to: CGPoint(x: width, y: height - radius))

            path.addQuadCurve(
                to: CGPoint(x: width - radius, y: height),
                control: CGPoint(x: width, y: height)
            )
            
            path.addLine(to: CGPoint(x: radius, y: height))

            path.addQuadCurve(
                to: CGPoint(x: 0, y: height - radius),
                control: CGPoint(x: 0, y: height)
            )
            
            path.addLine(to: CGPoint(x: 0, y: 0))
        }
    }
}

struct TopRoundedRectangle: Shape {
    var radius: CGFloat
    
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        
        return Path { path in
            path.move(to: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: width, y: radius))

            path.addQuadCurve(
                to: CGPoint(x: width - radius, y: 0),
                control: CGPoint(x: width, y: 0)
            )
            
            path.addLine(to: CGPoint(x: radius, y: 0))

            path.addQuadCurve(
                to: CGPoint(x: 0, y: radius),
                control: CGPoint(x: 0, y: 0)
            )
            
            path.addLine(to: CGPoint(x: 0, y: 0))
        }
    }
}
