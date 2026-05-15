//
//  SendFeedbackView.swift
//  Zashi
//
//  Created by Lukáš Korba on 10-11-2024.
//

import SwiftUI
import ComposableArchitecture

struct SendFeedbackView: View {
    @Environment(\.colorScheme) private var colorScheme
    
    @Perception.Bindable var store: StoreOf<SendFeedback>
    
    @FocusState var isFieldFocused: Bool
    @State private var keyboardVisible: Bool = false

    init(store: StoreOf<SendFeedback>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(localizable: .sendFeedbackTitle)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .padding(.top, 40)
                        
                        Text(localizable: .sendFeedbackDesc)
                            .zFont(size: 14, style: Design.Text.primary)
                            .padding(.top, 8)
                        
                        Text(localizable: .sendFeedbackRatingQuestion)
                            .zFont(.medium, size: 14, style: Design.Text.primary)
                            .padding(.top, 32)
                        
                        HStack(spacing: 12) {
                            ForEach(0..<5) { rating in
                                WithPerceptionTracking {
                                    Button {
                                        store.send(.ratingTapped(rating))
                                    } label: {
                                        Text(store.ratings[rating])
                                            .padding(.vertical, 12)
                                            .frame(maxWidth: .infinity)
                                            .background {
                                                RoundedRectangle(cornerRadius: Design.Radius._xl)
                                                    .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                                            }
                                            .padding(3)
                                            .overlay {
                                                if let selectedRating = store.selectedRating, selectedRating == rating {
                                                    RoundedRectangle(cornerRadius: 14)
                                                        .stroke(Design.Text.primary.color(colorScheme))
                                                }
                                            }
                                    }
                                }
                            }
                        }
                        .padding(.top, 12)
                        
                        Text(localizable: .sendFeedbackHowCanWeHelp)
                            .zFont(.medium, size: 14, style: Design.Text.primary)
                            .padding(.top, 24)
                        
                        MessageEditorView(
                            store: store.memoStore(),
                            title: "",
                            placeholder: String(localizable: .sendFeedbackHcwhPlaceholder)
                        )
                        .frame(height: 155)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .focused($isFieldFocused)
                        .onAppear {
                            isFieldFocused = true
                        }
                        
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
                        
                        Spacer()
                        
                        ZashiButton(
                            String(localizable: .generalShare)
                        ) {
                            store.send(.sendTapped)
                        }
                        .disabled(store.invalidForm)
                        .padding(.bottom, keyboardVisible ? 48 : 24)
                        
                        shareView()
                    }
                    .screenHorizontalPadding()
                }
                .padding(.vertical, 1)
                .zashiBack()
                .trackKeyboardVisibility($keyboardVisible)
                .onAppear {
                    store.send(.onAppear)
                }
            }
            .overlay(
                VStack(spacing: 0) {
                    Spacer()

                    Asset.Colors.primary.color
                        .frame(height: 1)
                        .opacity(0.1)
                    
                    HStack(alignment: .center) {
                        Spacer()
                        
                        Button {
                            isFieldFocused = false
                        } label: {
                            Text(String(localizable: .generalDone).uppercased())
                                .zFont(.regular, size: 14, style: Design.Text.primary)
                        }
                        .padding(.bottom, 4)
                    }
                    .applyScreenBackground()
                    .padding(.horizontal, 20)
                    .frame(height: keyboardVisible ? 38 : 0)
                    .frame(maxWidth: .infinity)
                    .opacity(keyboardVisible ? 1 : 0)
                }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .applyScreenBackground()
        .screenTitle(String(localizable: .sendFeedbackScreenTitle).uppercased())
    }
    
}

extension SendFeedbackView {
    @ViewBuilder func shareView() -> some View {
        if let message = store.messageToBeShared {
            UIShareDialogView(activityItems: [
                ShareableMessage(
                    title: String(localizable: .sendFeedbackShareTitle),
                    message: message,
                    desc: String(localizable: .sendFeedbackShareDesc)
                ),
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

// MARK: - Previews

#Preview {
    SendFeedbackView(store: SendFeedback.initial)
}

// MARK: - Store

extension SendFeedback {
    static var initial = StoreOf<SendFeedback>(
        initialState: .initial
    ) {
        SendFeedback()
    }
}

// MARK: - Placeholders

extension SendFeedback.State {
    static let initial = SendFeedback.State()
}

extension StoreOf<SendFeedback> {
    func memoStore() -> StoreOf<MessageEditor> {
        self.scope(
            state: \.memoState,
            action: \.memo
        )
    }
}
