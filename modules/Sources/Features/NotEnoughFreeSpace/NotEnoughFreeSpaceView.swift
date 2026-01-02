//
//  NotEnoughFreeSpaceView.swift
//  Zashi
//
//  Created by Michal Fousek on 28.09.2022.
//

import SwiftUI
import ComposableArchitecture

import Generated
import Settings
import UIComponents

public struct NotEnoughFreeSpaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<NotEnoughFreeSpace>
    
    public init(store: StoreOf<NotEnoughFreeSpace>) {
        self.store = store
    }

    public var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                Asset.Assets.infoCircle.image
                    .zImage(size: 28, style: Design.Utility.ErrorRed._700)
                    .padding(18)
                    .background {
                        Circle()
                            .fill(Design.Utility.ErrorRed._100.color(colorScheme))
                    }
                    .rotationEffect(.degrees(180))
                    .padding(.top, 100)

                Text(L10n.NotEnoughFreeSpace.title)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Group {
                    Text(L10n.NotEnoughFreeSpace.messagePre(store.freeSpaceRequiredForSync))
                    + Text(L10n.NotEnoughFreeSpace.dataAvailable(store.freeSpace)).bold()
                    + Text(L10n.NotEnoughFreeSpace.messagePost)
                }
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)

                Text(L10n.NotEnoughFreeSpace.requiredSpace(store.spaceToFreeUp))
                    .zFont(size: 12, style: Design.Text.primary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .onAppear { store.send(.onAppear) }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: settingsButton())
            .screenHorizontalPadding()
            .applyErredScreenBackground()
        }
    }
    
    func settingsButton() -> some View {
        Asset.Assets.Icons.dotsMenu.image
            .zImage(size: 24, style: Design.Text.primary)
            .padding(Design.Spacing.navBarButtonPadding)
            .tint(Asset.Colors.primary.color)
            .navigationLink(
                isActive: $store.isSettingsOpen,
                destination: {
                    // FIXME: this can be done without .navigationLink( by using NavigationStack
                    SettingsView(
                        store:
                            store.scope(
                                state: \.settingsState,
                                action: \.settings
                            )
                    )
                }
            )
    }
}

// MARK: - Previews

#Preview {
    NavigationView {
        NotEnoughFreeSpaceView(
            store:
                StoreOf<NotEnoughFreeSpace>(
                    initialState: NotEnoughFreeSpace.State(
                        settingsState: .initial
                    )
                ) {
                    NotEnoughFreeSpace()
                }
        )
    }
}

// MARK: Placeholders

extension NotEnoughFreeSpace.State {
    public static let initial = NotEnoughFreeSpace.State(
        settingsState: .initial
    )
}

extension NotEnoughFreeSpace {
    public static let placeholder = StoreOf<NotEnoughFreeSpace>(
        initialState: .initial
    ) {
        NotEnoughFreeSpace()
    }
}
