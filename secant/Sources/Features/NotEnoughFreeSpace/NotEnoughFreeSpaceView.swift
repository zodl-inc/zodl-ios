//
//  NotEnoughFreeSpaceView.swift
//  Zashi
//
//  Created by Michal Fousek on 28.09.2022.
//

import SwiftUI
import ComposableArchitecture

struct NotEnoughFreeSpaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<NotEnoughFreeSpace>
    
    init(store: StoreOf<NotEnoughFreeSpace>) {
        self.store = store
    }

    var body: some View {
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

                Text(localizable: .notEnoughFreeSpaceTitle)
                    .zFont(.semiBold, size: 24, style: Design.Text.primary)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Group {
                    Text(localizable: .notEnoughFreeSpaceMessagePre(store.freeSpaceRequiredForSync))
                    + Text(localizable: .notEnoughFreeSpaceDataAvailable(store.freeSpace)).bold()
                    + Text(localizable: .notEnoughFreeSpaceMessagePost)
                }
                .zFont(size: 14, style: Design.Text.primary)
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)

                Text(localizable: .notEnoughFreeSpaceRequiredSpace(store.spaceToFreeUp))
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
    static let initial = NotEnoughFreeSpace.State(
        settingsState: .initial
    )
}

extension NotEnoughFreeSpace {
    static let placeholder = StoreOf<NotEnoughFreeSpace>(
        initialState: .initial
    ) {
        NotEnoughFreeSpace()
    }
}
