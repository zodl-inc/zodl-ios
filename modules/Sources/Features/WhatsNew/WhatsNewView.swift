//
//  WhatsNewView.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-14-2024
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents
import WhatsNewProvider

public struct WhatsNewView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Perception.Bindable var store: StoreOf<WhatsNew>
    
    public init(store: StoreOf<WhatsNew>) {
        self.store = store
    }

    public var body: some View {
        WithPerceptionTracking {
            if store.isInDebugMode {
                debugModeView()
            } else {
                whatsNewView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
    }
    
    @ViewBuilder func attributedText(_ sectionIndex: Int, index: Int) -> some View {
        if let previewText = try? AttributedString(
            markdown: store.latest.sections[sectionIndex].bulletpoints[index],
            including: \.zashiApp) {
            HStack {
                VStack {
                    Circle()
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                        .padding(.leading, 8)
                    
                    Spacer()
                }
                
                ZashiText(withAttributedString: previewText, colorScheme: colorScheme)
                    .zFont(size: 14, style: Design.Text.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accentColor(Asset.Colors.primary.color)
                    .lineSpacing(1.5)
            }
        }
    }
    
    @ViewBuilder func whatsNewView() -> some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(spacing: 0) {
                    Text(L10n.WhatsNew.version(store.latest.version))
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                    
                    Spacer()
                    
                    Text(store.latest.date)
                        .zFont(.semiBold, size: 14, style: Design.Text.primary)
                }
                .padding(.top, 40)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .screenHorizontalPadding()

                WithPerceptionTracking {
                    ForEach(0..<store.latest.sections.count, id: \.self) { sectionIndex in
                        VStack(alignment: .leading, spacing: 6) {
                            WithPerceptionTracking {
                                Text(store.latest.sections[sectionIndex].title)
                                    .zFont(.semiBold, size: 16, style: Design.Text.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                
                                WithPerceptionTracking {
                                    ForEach(0..<store.latest.sections[sectionIndex].bulletpoints.count, id: \.self) { index in
                                        WithPerceptionTracking {
                                            attributedText(sectionIndex, index: index)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
                .screenHorizontalPadding()
            }
            .padding(.vertical, 1)
            .zashiBack()
            .onAppear { store.send(.onAppear) }
            .screenTitle(L10n.Settings.whatsNew.uppercased())

            Spacer()
            
            Asset.Assets.zashiLogo.image
                .zImage(width: 41, height: 41, color: Asset.Colors.primary.color)
                .padding(.bottom, 7)

            Asset.Assets.zashiTitle.image
                .zImage(width: 73, height: 20, color: Asset.Colors.primary.color)
                .padding(.bottom, 16)
                .onLongPressGesture {
                    store.send(.enableDebugMode)
                }

            Text(L10n.Settings.version(store.appVersion, store.appBuild))
                .zFont(size: 16, style: Design.Text.tertiary)
                .padding(.bottom, 24)
        }
    }
    
    @ViewBuilder func debugModeView() -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZashiButton("Exit debug", infinityWidth: false) {
                    store.send(.exitDebug)
                }
                
                Spacer()
                
                ZashiButton("Execute", infinityWidth: false) {
                    store.send(.executeQueryRequested)
                }
            }
            .padding(.bottom, 8)
            
            TextEditor(text: $store.query)
                .font(.custom(FontFamily.Inter.medium.name, size: 16))
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .colorBackground(Design.Inputs.Default.bg.color(colorScheme))
                .cornerRadius(10)
                .padding(.bottom, 8)
            
            TextEditor(text: $store.output)
                .font(.custom(FontFamily.Inter.medium.name, size: 16))
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .colorBackground(Design.Inputs.Default.bg.color(colorScheme))
                .cornerRadius(10)
        }
        .padding()
        .zashiBack()
        .screenTitle("QUERY DATABASE".uppercased())
    }
}

// MARK: - Previews

#Preview {
    WhatsNewView(store: WhatsNew.initial)
}

// MARK: - Store

extension WhatsNew {
    public static var initial = StoreOf<WhatsNew>(
        initialState: .initial
    ) {
        WhatsNew()
    }
}

// MARK: - Placeholders

extension WhatsNew.State {
    public static let initial = WhatsNew.State(latest: .zero, releases: .zero)
}
