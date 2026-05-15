//
//  AddressBookStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 05-28-2024.
//

import ComposableArchitecture
import SwiftUI

@preconcurrency import ZcashLightClientKit

@Reducer
struct AddressBook {
    enum Constants {
        static let maxNameLength = 32
    }
    
    @ObservableState
    struct State: Equatable {
        enum Context {
            case send
            case settings
            case swap
            case unknown
        }
        
        var address = ""
        var addressAlreadyExists = false
        @Shared(.inMemory(.addressBookContacts)) var addressBookContacts: AddressBookContacts = .empty
        @Presents var alert: AlertState<Action>?
        var context: Context = .unknown
        var deleteIdToConfirm: String?
        var isAddressFocused = false
        var editId: String?
        var isChainFocused = false
        var isEditingContactWithChain = false
        var isInSelectMode = false
        var isNameFocused = false
        var isTokenFocused = false
        var isValidForm = false
        var isValidZcashAddress = false
        var name = ""
        var nameAlreadyExists = false
        var originalAddress = ""
        var originalName = ""
        var originalChainId = ""
        @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil
        @Shared(.inMemory(.swapAssets)) var swapAssets: IdentifiedArrayOf<SwapAsset> = []
        @Shared(.inMemory(.walletAccounts)) var walletAccounts: [WalletAccount] = []
        @Shared(.inMemory(.zashiWalletAccount)) var zashiWalletAccount: WalletAccount? = nil
        var zecAsset = SwapAsset(provider: "", chain: "zec", token: "zec", assetId: "", usdPrice: 0, decimals: 0)

        // swaps
        var chains: IdentifiedArrayOf<SwapAsset> = []
        var chainsToPresent: IdentifiedArrayOf<SwapAsset> = []
        var chainSelectBinding = false
        var searchTerm = ""
        var selectedChain: SwapAsset?
        
        var uniqueId: String {
            "\(address)-\(selectedChain?.chain ?? "zcash")"
        }
        
        var isEditChange: Bool {
            (address != originalAddress || name != originalName || selectedChain?.chain != originalChainId)
            && (isValidForm || (context != .send && selectedChain != nil && !isValidZcashAddress))
        }
        
        var isNameOverMaxLength: Bool {
            name.count > Constants.maxNameLength
        }

        var isSaveButtonDisabled: Bool {
            !isEditChange
            || isNameOverMaxLength
            || nameAlreadyExists
            || addressAlreadyExists
//            || (context == .swap && selectedChain == nil)
            || (context == .swap && isValidZcashAddress)
            || (context != .send && selectedChain == nil && !isValidZcashAddress)
        }
        
        var invalidAddressErrorText: String? {
            addressAlreadyExists
            ? String(localizable: .addressBookErrorAddressExists)
            : context == .swap
            ? (isValidZcashAddress ? String(localizable: .swapAndPayAddressBookZcash) : nil)
            : (isValidZcashAddress || address.isEmpty)
            ? nil
            : isEditingContactWithChain
            ? nil
            : (!isValidZcashAddress && selectedChain != nil)
            ? nil
            : context == .settings
            ? nil
            : String(localizable: .addressBookErrorInvalidAddress)
        }

        var invalidNameErrorText: String? {
            isNameOverMaxLength
            ? String(localizable: .addressBookErrorNameLength)
            : nameAlreadyExists
            ? String(localizable: .addressBookErrorNameExists)
            : nil
        }
        
        var addressBookContactsToShow: AddressBookContacts {
            var abContactsCopy = addressBookContacts
            
            abContactsCopy.contacts = abContactsCopy.contacts.filter {
                switch context {
                case .swap: $0.chainId != nil
                case .send: $0.chainId == nil
                default: true
                }
            }
            
            return abContactsCopy
        }

        init() { }
    }

    enum Action: BindableAction, Equatable {
        case addManualButtonTapped
        case alert(PresentationAction<Action>)
        case binding(BindingAction<AddressBook.State>)
        case contactStoreSuccess
        case deleteId(String)
        case deleteIdConfirmed
        case dismissAddContactRequired
        case dismissDeleteContactRequired
        case editId(String, String)
        case fetchedABContacts(AddressBookContacts, Bool)
        case fetchABContactsRequested
        case onAppear
        case checkDuplicates
        case saveButtonTapped
        case scanButtonTapped
        case walletAccountTapped(WalletAccount)
        
        // swaps
        case chainTapped(SwapAsset)
        case closeChainsSheetTapped
        case eraseSearchTermTapped
        case selectChainTapped
        case updateAssetsAccordingToSearchTerm
    }

    init() { }

    @Dependency(\.addressBook) var addressBook
    @Dependency(\.audioServices) var audioServices
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.isValidForm = false
                state.deleteIdToConfirm = nil
                state.nameAlreadyExists = false
                state.addressAlreadyExists = false
                if !state.swapAssets.isEmpty {
                    let uniqueByChain = Dictionary(grouping: state.swapAssets, by: { $0.chain })
                        .compactMapValues { $0.first }
                        .values
                        .sorted(by: { $0.chainName < $1.chainName })
                    state.chains = IdentifiedArray(uniqueElements: uniqueByChain)
                } else {
                    state.chains = IdentifiedArray(uniqueElements: SwapAsset.hardcodedChains())
                }
                if let editId = state.editId {
                    return .concatenate(
                        .send(.editId(editId, editId)),
                        .send(.fetchABContactsRequested),
                        .send(.updateAssetsAccordingToSearchTerm)
                    )
                }
                return .merge(
                    .send(.fetchABContactsRequested),
                    .send(.updateAssetsAccordingToSearchTerm)
                )

            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .alert:
                return .none

            case .addManualButtonTapped:
                state.address = ""
                state.name = ""
                state.isValidForm = false
                state.isAddressFocused = true
                return .none

            case .checkDuplicates:
                state.nameAlreadyExists = false
                state.addressAlreadyExists = false
                for contact in state.addressBookContacts.contacts {
                    if contact.name == state.name && state.name != state.originalName {
                        state.nameAlreadyExists = true
                    }
                    if contact.id == state.uniqueId && state.address != state.originalAddress {
                        state.addressAlreadyExists = true
                    }
                }
                return .none
                
            case .scanButtonTapped:
                return .none

            case .binding(\.searchTerm):
                return .send(.updateAssetsAccordingToSearchTerm)

            case .binding:
                state.isValidZcashAddress = derivationTool.isZcashAddress(state.address, zcashSDKEnvironment.network.networkType)
                state.isValidForm = !state.name.isEmpty && (state.isValidZcashAddress || state.context == .swap || state.isEditingContactWithChain)
                if state.isValidZcashAddress {
                    state.selectedChain = nil
                }
                return .send(.checkDuplicates)

            case .deleteId(let id):
                state.deleteIdToConfirm = id
                state.alert = AlertState.confirmDelete()
                return .none

            case .deleteIdConfirmed:
                state.alert = nil
                guard let deleteIdToConfirm = state.deleteIdToConfirm, let account = state.zashiWalletAccount else {
                    return .none
                }

                let contact = state.addressBookContacts.contacts.first {
                    $0.id == deleteIdToConfirm
                }
                if let contact {
                    do {
                        let result = try addressBook.deleteContact(account.account, contact)
                        let abContacts = result.contacts
                        if result.remoteStoreResult == .failure {
                            // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                        }
                        return .run { send in
                            await send(.fetchedABContacts(abContacts, false))
                            
                            try? await Task.sleep(for: .milliseconds(150))
                            await send(.dismissDeleteContactRequired)
                        }
                    } catch {
                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                    }
                }
                return .none
                
            case .walletAccountTapped:
                return .none
                
            case let .editId(_, id):
                guard !state.isInSelectMode else {
                    return .none
                }
                let record = state.addressBookContacts.contacts.first {
                    $0.id == id
                }
                guard let record else {
                    return .none
                }
                state.address = record.address
                state.name = record.name
                state.originalAddress = state.address
                state.originalName = state.name
                state.originalChainId = record.chainId ?? "zcash"
                state.isValidForm = true
                state.isNameFocused = true
                state.isValidZcashAddress = derivationTool.isZcashAddress(state.address, zcashSDKEnvironment.network.networkType)
                state.isEditingContactWithChain = record.chainId != nil
                state.selectedChain = state.chains.first { $0.chain == record.chainId }
                return .none

            case .saveButtonTapped:
                guard let account = state.zashiWalletAccount else {
                    return .none
                }
                do {
                    _ = try addressBook.deleteContact(
                        account.account,
                        Contact(
                            address: state.originalAddress,
                            name: state.originalName,
                            chainId: state.originalChainId
                        )
                    )
                    let result = try addressBook.storeContact(
                        account.account,
                        Contact(
                            address: state.address,
                            name: state.name,
                            chainId: state.selectedChain?.chain
                        )
                    )
                    let abContacts = result.contacts
                    if result.remoteStoreResult == .failure {
                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                    }
                    return .concatenate(
                        .send(.fetchedABContacts(abContacts, false)),
                        .send(.contactStoreSuccess),
                        .send(.dismissAddContactRequired)
                    )
                } catch {
                    // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                }
                return .none

            case .contactStoreSuccess:
                state.address = ""
                state.name = ""
                state.isAddressFocused = false
                state.isNameFocused = false
                state.selectedChain = nil
                return .none

            case .fetchABContactsRequested:
                guard let account = state.zashiWalletAccount else {
                    return .none
                }
                do {
                    let result = try addressBook.allLocalContacts(account.account)
                    let abContacts = result.contacts
                    if result.remoteStoreResult == .failure {
                        // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                    }
                    return .send(.fetchedABContacts(abContacts, true))
                } catch {
                    // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                }
                return .none

            case let .fetchedABContacts(abContacts, requestToSync):
                guard let account = state.zashiWalletAccount else {
                    return .none
                }
                state.$addressBookContacts.withLock { $0 = abContacts }
                if requestToSync {
                    return .run { send in
                        do {
                            let result = try await addressBook.syncContacts(account.account, abContacts)
                            let syncedContacts = result.contacts
                            if result.remoteStoreResult == .failure {
                                // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                            }
                            await send(.fetchedABContacts(syncedContacts, false))
                        } catch {
                            // TODO: [#1408] error handling https://github.com/Electric-Coin-Company/zashi-ios/issues/1408
                        }
                    }
                }
                return .none
                
            case .dismissAddContactRequired:
                return .none

            case .dismissDeleteContactRequired:
                return .none
                
                // MARK: - Swaps
                
            case .eraseSearchTermTapped:
                return .none
                
            case .selectChainTapped:
                state.searchTerm = ""
                state.chainsToPresent = state.chains
                state.chainSelectBinding = true
                return .none
                
            case .closeChainsSheetTapped:
                state.searchTerm = ""
                state.chainsToPresent = state.chains
                state.chainSelectBinding = false
                return .none
                
            case .chainTapped(let chain):
                state.selectedChain = chain
                state.chainSelectBinding = false
                return .send(.checkDuplicates)
                
            case .updateAssetsAccordingToSearchTerm:
                let swapChains = state.chains
                guard !state.searchTerm.isEmpty else {
                    state.chainsToPresent = swapChains
                    return .none
                }
                state.chainsToPresent.removeAll()
                let chainNameMatch = swapChains.filter { $0.chainName.localizedCaseInsensitiveContains(state.searchTerm) }
                let chainMatch = swapChains.filter { $0.chain.localizedCaseInsensitiveContains(state.searchTerm) }
                state.chainsToPresent.append(contentsOf: chainNameMatch)
                state.chainsToPresent.append(contentsOf: chainMatch)
                return .none
            }
        }
    }
}

extension AddressBook {
    static func contactTicker(chainId: String?) -> Image? {
        guard let chainId else { return nil }
        
        guard let icon = UIImage(named: "chain_\(chainId.lowercased())") else {
            return Asset.Assets.Tickers.none.image
        }

        return Image(uiImage: icon)
    }
}

// MARK: Alerts

extension AlertState where Action == AddressBook.Action {
    static func confirmDelete() -> AlertState {
        AlertState {
            TextState(String(localizable: .addressBookAlertTitle))
        } actions: {
            ButtonState(role: .destructive, action: .deleteIdConfirmed) {
                TextState(String(localizable: .generalConfirm))
            }
            ButtonState(role: .cancel, action: .alert(.dismiss)) {
                TextState(String(localizable: .generalCancel))
            }
        } message: {
            TextState(String(localizable: .addressBookAlertMessage))
        }
    }
}
