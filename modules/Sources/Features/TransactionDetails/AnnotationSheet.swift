//
//  AnnotationSheet.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-01-27.
//

import SwiftUI
import ComposableArchitecture
import Generated
import UIComponents

extension TransactionDetailsView {
    @ViewBuilder func annotationContent(_ isEditMode: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isEditMode
                 ? L10n.Annotation.edit
                 : L10n.Annotation.addArticle
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
                                    Text(L10n.Annotation.placeholder)
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

                Text(L10n.Annotation.chars(store.annotationToInput.count, TransactionDetails.State.Constants.annotationMaxLength))
                    .zFont(size: 14, style: Design.Inputs.Default.hint)
            }
            .padding(.bottom, 32)
            
            if isEditMode {
                HStack(spacing: 8) {
                    ZashiButton(
                        L10n.Annotation.delete,
                        type: .destructive1
                    ) {
                        store.send(.deleteNoteTapped)
                    }

                    ZashiButton(L10n.Annotation.save) {
                        store.send(.saveNoteTapped)
                    }
                    .disabled(!store.isAnnotationModified)
                }
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            } else {
                ZashiButton(L10n.Annotation.add) {
                    store.send(.addNoteTapped)
                }
                .disabled(store.annotationToInput.isEmpty)
                .padding(.bottom, Design.Spacing.sheetBottomSpace)
            }
        }
    }
}
