//
//  AddressBookView.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-28-2024.
//

import SwiftUI
import Combine
import ComposableArchitecture

extension String {
    var initials: String {
        var res = ""
        self.split(separator: " ").forEach {
            if let firstChar = $0.first, res.count < 2 {
                res.append(String(firstChar))
            }
        }

        return res
    }
}

struct AddressBookView: View {
    @Environment(\.colorScheme) private var colorScheme
    @PlatformBindable var store: StoreOf<AddressBook>
#if os(macOS)
    // macOS replaces the iOS Menu "bubble" (manual vs scan) with the app's macOS sheet equivalent —
    // a zashiSheet card offering the same two choices. This drives its presentation.
    @State private var macAddContactDialog = false
#endif

    init(store: StoreOf<AddressBook>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                if store.isInSelectMode && store.walletAccounts.count > 1 && store.context != .swap {
                    contactsList()
                } else {
                    if store.addressBookContactsToShow.contacts.isEmpty {
                        Spacer()
                        
                        VStack(spacing: 40) {
                            emptyComposition()
                            
                            Text(localizable: .addressBookEmpty)
                                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .screenHorizontalPadding()
                        .macContentRowCap()
                    } else {
                        contactsList()
                    }
                }

                Spacer()

                addContactButton(store)
                    .macContentRowCap()
            }
            .padding(.top, 24)
            .onAppear { store.send(.onAppear) }
            .zashiBack()
            .screenTitle(
                store.isInSelectMode
                && (!store.addressBookContactsToShow.contacts.isEmpty || store.walletAccounts.count > 1 || store.context == .swap)
                ? String(localizable: .addressBookSelectRecipient)
                : String(localizable: .addressBookTitle)
            )
            .zashiNavBarTitleDisplayMode(.inline)
            // macOS: full-width scroll container so the (visible) indicator hits the window edge, not the
            // 530-column edge; rows/chrome cap their own content via `.macContentRowCap()`. iOS no-op (Rule #11).
            .applyScreenBackground(capped: false)
        }
    }

    func addContactButton(_ store: StoreOf<AddressBook>) -> some View {
        WithPerceptionTracking {
#if os(macOS)
            // macOS: a `Menu` whose label is an interactive `ZashiButton` mis-renders here (the
            // button swallows the click AND `.menuStyle(.borderlessButton)` blows the label up to a
            // full-screen plus icon). Replace the iOS Menu "bubble" with the app's macOS sheet
            // equivalent — a zashiSheet card offering the same two choices (manual vs scan).
            ZashiButton(
                String(localizable: .addressBookAddNewContact),
                prefixView:
                    Asset.Assets.Icons.plus.image
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 20, height: 20)
            ) {
                macAddContactDialog = true
            }
            .screenHorizontalPadding()
            .padding(.bottom, 24)
            .padding(.top, 8)
            .accessibilityIdentifier(AccessibilityID.AddressBook.addContact)
            .zashiSheet(isPresented: $macAddContactDialog) {
                macAddContactChoice()
            }
#else
            Menu {
                Button {
                    store.send(.scanButtonTapped)
                } label: {
                    HStack {
                        Asset.Assets.Icons.qr.image
                            .zImage(size: 20, style: Design.Text.primary)

                        Text(localizable: .addressBookScanAddress)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.AddressBook.scanEntry)

                Button {
                    store.send(.addManualButtonTapped)
                } label: {
                    HStack {
                        Asset.Assets.Icons.pencil.image
                            .zImage(size: 20, style: Design.Text.primary)

                        Text(localizable: .addressBookManualEntry)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.AddressBook.manualEntry)
            } label: {
                ZashiButton(
                    String(localizable: .addressBookAddNewContact),
                    prefixView:
                        Asset.Assets.Icons.plus.image
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 20, height: 20)
                ) {

                }
                .screenHorizontalPadding()
                .padding(.bottom, 24)
                .padding(.top, 8)
            }
            .accessibilityIdentifier(AccessibilityID.AddressBook.addContact)
#endif
        }
    }

#if os(macOS)
    // The macOS card-dialog equivalent of the iOS "Add New Contact" Menu bubble: the same two
    // choices (manual entry vs scan), presented in a zashiSheet. The sheet provides the card
    // chrome (background, rounded corners, close button); this is just its content.
    @ViewBuilder func macAddContactChoice() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .addressBookAddNewContact)
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.bottom, 8)

            Button {
                macAddContactDialog = false
                store.send(.addManualButtonTapped)
            } label: {
                HStack(spacing: 12) {
                    Asset.Assets.Icons.pencil.image
                        .zImage(size: 20, style: Design.Text.primary)

                    Text(localizable: .addressBookManualEntry)
                        .zFont(.medium, size: 16, style: Design.Text.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 14)
            }
            .zashiPlainButtonStyle()
            .accessibilityIdentifier(AccessibilityID.AddressBook.manualEntry)

            Divider()

            Button {
                macAddContactDialog = false
                store.send(.scanButtonTapped)
            } label: {
                HStack(spacing: 12) {
                    Asset.Assets.Icons.qr.image
                        .zImage(size: 20, style: Design.Text.primary)

                    Text(localizable: .addressBookScanAddress)
                        .zFont(.medium, size: 16, style: Design.Text.primary)

                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 14)
            }
            .zashiPlainButtonStyle()
            .accessibilityIdentifier(AccessibilityID.AddressBook.scanEntry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
#endif

    func emptyComposition() -> some View {
        Asset.Assets.send.image
            .zImage(size: 32, style: Design.Btns.Tertiary.fg)
            .zForegroundColor(Design.Btns.Tertiary.fg)
            .background {
                Circle()
                    .fill(Design.Btns.Tertiary.bg.color(colorScheme))
                    .frame(width: 72, height: 72)
            }
    }
    
    @ViewBuilder func contactsList() -> some View {
        List {
            if store.walletAccounts.count > 1 && store.isInSelectMode && store.context != .swap {
                Text(localizable: .accountsAddressBookYour)
                    .zFont(.medium, size: 14, style: Design.Text.tertiary)
                    .padding(.top, 24)
                    .padding(.bottom, 16)
                    .screenHorizontalPadding()
                    .macContentRowCap()
                    .listBackground()

                ForEach(store.walletAccounts, id: \.self) { walletAccount in
                    if walletAccount != store.selectedWalletAccount {
                        VStack {
                            walletAccountView(
                                icon: walletAccount.vendor.icon(),
                                title: walletAccount.vendor.name(),
                                address: walletAccount.unifiedAddress ?? String(localizable: .receiveErrorCantExtractUnifiedAddress)
                            ) {
                                store.send(.walletAccountTapped(walletAccount))
                            }
                            
                            if let last = store.walletAccounts.last, last != walletAccount {
                                Design.Surfaces.divider.color(colorScheme)
                                    .frame(height: 1)
                                    .padding(.top, 12)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .macContentRowCap()
                        .listBackground()
                    }
                }
                
                if store.addressBookContactsToShow.contacts.isEmpty {
                    VStack(spacing: 40) {
                        emptyComposition()
                        
                        Text(localizable: .addressBookEmpty)
                            .zFont(.semiBold, size: 24, style: Design.Text.primary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listBackground()
                    .screenHorizontalPadding()
                    .padding(.bottom, 40)
                    .padding(.top, 70)
                    .background {
                        RoundedRectangle(cornerRadius: Design.Radius._2xl)
                            .stroke(Design.Surfaces.strokeSecondary.color(colorScheme), style: StrokeStyle(lineWidth: 2.0, dash: [8, 6]))
                    }
                    .padding(.top, 24)
                    .screenHorizontalPadding()
                    .macContentRowCap()
                } else {
                    Text(localizable: .accountsAddressBookContacts)
                        .zFont(.medium, size: 14, style: Design.Text.tertiary)
                        .padding(.top, 32)
                        .padding(.bottom, 16)
                        .screenHorizontalPadding()
                        .macContentRowCap()
                        .listBackground()
                }
            }

            ForEach(store.addressBookContactsToShow.contacts, id: \.self) { record in
                VStack {
                    ContactView(
                        iconText: record.name.initials,
                        tickerIcon: AddressBook.contactTicker(chainId: record.chainId),
                        title: record.name,
                        desc: record.address.trailingZip316,
                        descIsAddress: true
                    ) {
                        store.send(.editId(record.address, record.id))
                    }

                    if let last = store.addressBookContactsToShow.contacts.last, last != record {
                        Design.Surfaces.divider.color(colorScheme)
                            .frame(height: 1)
                            .padding(.top, 12)
                            .padding(.horizontal, 4)
                    }
                }
                .macContentRowCap()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Asset.Colors.background.color)
                .listRowSeparator(.hidden)
            }

            // [B4-6] Tail inset: the chain-ticker circle is drawn OFFSET (+12 y) past the avatar,
            // so on the LAST row it extends below the row's layout bounds and the plain List
            // clipped it. An invisible tail row gives the overhang room to render.
            Color.clear
                .frame(height: 14)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Asset.Colors.background.color)
                .listRowSeparator(.hidden)
        }
        .padding(.vertical, 1)
        .background(Asset.Colors.background.color)
        .listStyle(.plain)
        .zashiHideListBackground()
    }

    @ViewBuilder func walletAccountView(
        icon: Image,
        title: String,
        address: String,
        selected: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        WithPerceptionTracking {
            Button {
                action?()
            } label: {
                HStack(spacing: 0) {
                    icon
                        .resizable()
                        .frame(width: 24, height: 24)
                        .padding(8)
                        .background {
                            Circle()
                                .fill(Design.Surfaces.bgAlt.color(colorScheme))
                        }
                        .padding(.trailing, 12)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .zFont(.semiBold, size: 14, style: Design.Text.primary)
                        
                        Text(address.zip316)
                            .zFont(fontFamily: .robotoMono, size: 12, style: Design.Text.tertiary)
                    }
                    
                    Spacer()
                    
                    Asset.Assets.chevronRight.image
                        .zImage(size: 20, style: Design.Text.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Design.Radius._2xl)
                            .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview {
    AddressBookView(store: AddressBook.initial)
}

// MARK: - Store

extension AddressBook {
    @MainActor static var initial = StoreOf<AddressBook>(
        initialState: .initial
    ) {
        AddressBook()
    }
}

// MARK: - Placeholders

extension AddressBook.State {
    static var initial: AddressBook.State { AddressBook.State() }
}
