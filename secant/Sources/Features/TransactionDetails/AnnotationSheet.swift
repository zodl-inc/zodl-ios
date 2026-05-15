//
//  AnnotationSheet.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-01-27.
//

import SwiftUI
import ComposableArchitecture

extension TransactionDetailsView {
    @ViewBuilder func annotationContent(_ isEditMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditMode
                 ? String(localizable: .annotationEdit)
                 : String(localizable: .annotationAddArticle)
            )
            .zFont(.semiBold, size: 20, style: Design.Text.primary)
            .padding(.top, 32)
            .padding(.bottom, 16)
            
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $store.annotationToInput)
                    .focused($isAnnotationFocused)
                    .font(.custom(FontFamily.Inter.medium.name, size: 16))
                    .frame(height: 122)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .colorBackground(Design.Inputs.Default.bg.color(colorScheme))
                    .cornerRadius(10)
                    .overlay {
                        if store.annotationToInput.isEmpty {
                            HStack {
                                VStack {
                                    Text(localizable: .annotationPlaceholder)
                                        .font(.custom(FontFamily.Inter.regular.name, size: 16))
                                        .zForegroundColor(Design.Inputs.Default.text)
                                        .allowsHitTesting(false)

                                    Spacer()
                                }
                                .padding(.top, 10)
                                
                                Spacer()
                            }
                            .padding(.leading, 14)
                        } else {
                            EmptyView()
                        }
                    }

                Text(localizable: .annotationChars(String(store.annotationToInput.count), String(TransactionDetails.State.Constants.annotationMaxLength)))
                    .zFont(size: 14, style: Design.Inputs.Default.hint)
            }
            .padding(.bottom, 32)
            
            if isEditMode {
                HStack(spacing: 8) {
                    ZashiButton(
                        String(localizable: .annotationDelete),
                        type: .destructive1
                    ) {
                        store.send(.deleteNoteTapped)
                    }

                    ZashiButton(String(localizable: .annotationSave)) {
                        store.send(.saveNoteTapped)
                    }
                    .disabled(!store.isAnnotationModified)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            } else {
                ZashiButton(String(localizable: .annotationAdd)) {
                    store.send(.addNoteTapped)
                }
                .disabled(store.annotationToInput.isEmpty)
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
    }
}
