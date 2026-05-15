//
//  AddressBookContactView.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-28-2024.
//

import SwiftUI
import ComposableArchitecture

struct AddressBookContactView: View {
    @Environment(\.colorScheme) var colorScheme
    
    @Perception.Bindable var store: StoreOf<AddressBook>

    @FocusState var isAddressFocused: Bool
    @FocusState var isNameFocused: Bool
    @FocusState var isChainIdFocused: Bool

    init(store: StoreOf<AddressBook>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack {
                ZashiTextField(
                    addressFont: true,
                    text: $store.address,
                    placeholder: String(localizable: .addressBookNewContactAddressPlaceholder),
                    title: String(localizable: .addressBookNewContactAddress),
                    error: store.invalidAddressErrorText
                )
                .padding(.top, 20)
                .focused($isAddressFocused)

                ZashiTextField(
                    text: $store.name,
                    placeholder: String(localizable: .addressBookNewContactNamePlaceholder),
                    title: String(localizable: .addressBookNewContactName),
                    error: store.invalidNameErrorText
                )
                .padding(.top, 20)
                .padding(.bottom, (store.context != .send || store.isEditingContactWithChain) ? 0 : 20)
                .focused($isNameFocused)

                if store.context != .send || store.isEditingContactWithChain {
                    if store.isValidZcashAddress && store.context != .swap {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(localizable: .swapAndPayAddressBookSelectChain)
                                .zFont(.medium, size: 14, style: Design.Dropdowns.Default.label)
                                .padding(.bottom, 6)
                            
                            HStack(spacing: 0) {
                                store.zecAsset.chainIcon
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                    .padding(.trailing, 8)
                                
                                Text(store.zecAsset.chainName)
                                    .zFont(size: 16, style: Design.Dropdowns.Disabled.dropdown)
                                
                                Spacer()
                                
                                Asset.Assets.chevronDown.image
                                    .zImage(size: 18, style: Design.Dropdowns.Disabled.dropdown)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(
                                RoundedRectangle(cornerRadius: Design.Radius._lg)
                                    .fill(Design.Dropdowns.Disabled.bg.color(colorScheme))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Design.Radius._lg)
                                            .stroke(Design.Dropdowns.Disabled.stroke.color(colorScheme))
                                    }
                            )
                        }
                        .padding(.top, 20)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(localizable: .swapAndPayAddressBookSelectChain)
                                .zFont(.medium, size: 14, style: Design.Dropdowns.Default.label)
                                .padding(.bottom, 6)
                            
                            Button {
                                store.send(.selectChainTapped)
                            } label: {
                                HStack(spacing: 0) {
                                    if let selectedChain = store.selectedChain {
                                        selectedChain.chainIcon
                                            .resizable()
                                            .frame(width: 24, height: 24)
                                            .padding(.trailing, 8)
                                        
                                        Text(selectedChain.chainName)
                                            .zFont(size: 16, style: Design.Dropdowns.Default.text)
                                    } else {
                                        Text(localizable: .swapAndPayAddressBookSelect)
                                            .zFont(size: 16, style: Design.Dropdowns.Default.text)
                                    }
                                    
                                    Spacer()
                                    
                                    Asset.Assets.chevronDown.image
                                        .zImage(size: 18, style: Design.Text.primary)
                                }
                                .padding(.vertical, store.selectedChain == nil ? 10 : 8)
                                .padding(.horizontal, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                                        .fill(Design.Inputs.Default.bg.color(colorScheme))
                                )
                            }
                        }
                        .padding(.top, 20)
                        .focused($isChainIdFocused)
                    }
                }

                Spacer()
                
                ZashiButton(String(localizable: .generalSave)) {
                    store.send(.saveButtonTapped)
                }
                .disabled(store.isSaveButtonDisabled)
                .padding(.bottom, store.editId != nil ? 0 : 24)

                if store.editId != nil {
                    ZashiButton(String(localizable: .generalDelete), type: .destructive1) {
                        store.send(.deleteId(store.uniqueId))
                    }
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
            .onAppear {
                isAddressFocused = store.isAddressFocused
                if !isAddressFocused {
                    isNameFocused = store.isNameFocused
                }
                store.send(.onAppear)
            }
            .alert(
                store: store.scope(
                    state: \.$alert,
                    action: \.alert
                )
            )
            .popover(isPresented: $store.chainSelectBinding) {
                assetContent(colorScheme)
                    .padding(.horizontal, 4)
                    .applyScreenBackground()
            }
        }
        .applyScreenBackground()
        .zashiBack()
        .screenTitle(
            store.editId != nil
            ? String(localizable: .addressBookSavedAddress)
            : String(localizable: .swapAndPayAddressBookNewContact)
        )
    }
}

#Preview {
    AddressBookContactView(store: AddressBook.initial)
}
