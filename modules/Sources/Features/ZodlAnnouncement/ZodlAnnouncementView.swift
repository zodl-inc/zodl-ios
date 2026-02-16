//
//  ZodlAnnouncementView.swift
//  Zashi
//
//  Created by Lukáš Korba on 02-13-2026.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

public struct ZodlAnnouncementView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Perception.Bindable var store: StoreOf<ZodlAnnouncement>
    
    public init(store: StoreOf<ZodlAnnouncement>) {
        self.store = store
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .center, spacing: 0) {
                    headerView()
                        .padding(.top, 58)
                        .padding(.bottom, Design.Spacing._xl)
                    
                    Text(L10n.NewZodl.title)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)

                    Text(L10n.NewZodl.desc)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .padding(.vertical, 20)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Text(L10n.NewZodl.safeFunds)
                    .zFont(.semiBold, size: 16, style: Design.Utility.SuccessGreen._800)
                    .padding(Design.Spacing._xl)
                    .frame(maxWidth: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._lg)
                            .fill(Design.Utility.SuccessGreen._100.color(colorScheme))
                    }
                    .padding(.bottom, Design.Spacing._5xl)

                Text(L10n.NewZodl.likeBefore)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
                    .padding(.bottom, Design.Spacing._lg)

                pointView(L10n.NewZodl.sameTeam).padding(.bottom, Design.Spacing._lg)
                pointView(L10n.NewZodl.sameMission).padding(.bottom, Design.Spacing._lg)
                pointView(L10n.NewZodl.sameApp).padding(.bottom, Design.Spacing._lg)

                Spacer()
                
                ZashiButton(
                    L10n.NewZodl.learnMore,
                    type: .tertiary
                ) {
                    store.send(.learnMoreTapped)
                }
                .padding(.bottom, Design.Spacing._lg)

                ZashiButton(L10n.NewZodl.goTo) {
                    store.send(.goToZodlTapped)
                }
                .padding(.bottom, 24)
            }
            .sheet(isPresented: $store.isInAppBrowserOn) {
                if let url = URL(string: "https://zodl.com/zashi-is-becoming-zodl/") {
                    InAppBrowserView(url: url)
                }
            }
        }
        .navigationBarHidden(true)
        .screenHorizontalPadding()
        .applyScreenBackground()
    }
    
    @ViewBuilder func headerView() -> some View {
        HStack(spacing: 0) {
            // FROM Zashi
            Asset.Assets.prevZashiLogo.image
                .zImage(size: 26, style: Design.Text.opposite)
                .padding(11)
                .background {
                    Circle()
                        .frame(width: 48, height: 48)
                        .foregroundColor(Design.Surfaces.bgAlt.color(colorScheme))
                        .overlay {
                            Circle()
                                .frame(width: 51, height: 51)
                                .offset(x: 42)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }

            // Arrow
            RoundedRectangle(cornerRadius: Design.Radius._4xl)
                .fill(Design.Surfaces.bgTertiary.color(colorScheme))
                .frame(width: 48, height: 48)
                .overlay {
                    Circle()
                        .frame(width: 51, height: 51)
                        .offset(x: 42)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
                .overlay {
                    Asset.Assets.Icons.trPaid.image
                        .zImage(size: 24, style: Design.Text.primary)
                }
                .offset(x: -4)

            // TO Zodl
            Asset.Assets.zashiLogo.image
                .zImage(size: 20, style: Design.Logo.primary)
                .padding(14)
                .background {
                    Circle()
                        .frame(width: 48, height: 48)
                        .foregroundColor(Design.Logo.opposite.color(colorScheme))
                }
                .offset(x: -8)
        }
        .offset(x: 4)
    }
    
    @ViewBuilder func pointView(_ text: String) -> some View {
        HStack(spacing: Design.Spacing._md) {
            Asset.Assets.Icons.checkSolid.image
                .zImage(size: 20, style: Design.Text.primary)
            
            Text(text)
                .zFont(.medium, size: 14, style: Design.Text.primary)
        }
    }
}

// MARK: - Previews

#Preview {
    ZodlAnnouncementView(store: ZodlAnnouncement.initial)
}

// MARK: - Store

extension ZodlAnnouncement {
    public static var initial = StoreOf<ZodlAnnouncement>(
        initialState: .initial
    ) {
        ZodlAnnouncement()
    }
}

// MARK: - Placeholders

extension ZodlAnnouncement.State {
    public static let initial = ZodlAnnouncement.State()
}
