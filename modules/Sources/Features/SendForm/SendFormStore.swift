//
//  SendFormStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 04/25/2022.
//

import SwiftUI
import ComposableArchitecture
import ZcashLightClientKit
import AudioServices
import Utils
import Scan
import SDKSynchronizer
import ZcashSDKEnvironment
import UIComponents
import Models
import Generated
import BalanceFormatter
import WalletBalances
import NumberFormatter
import UserPreferencesStorage
import AddressBookClient
import ZcashPaymentURI
import BalanceBreakdown

@Reducer
public struct SendForm {
    public enum Confirmation {
        case requestPayment
        case send
    }
    
    @ObservableState
    public struct State {
        public var cancelId = UUID()
        
        public var addMemoState: Bool
        public var address: RedactableString = .empty
        @Shared(.inMemory(.addressBookContacts)) public var addressBookContacts: AddressBookContacts = .empty
        @Presents public var alert: AlertState<Action>?
        public var balancesBinding = false
        public var balancesState = Balances.State.initial
        @Shared(.inMemory(.exchangeRate)) public var currencyConversion: CurrencyConversion? = nil
        public var currencyText: RedactableString = .empty
        public var isAddressBookHintVisible = false
        public var isCurrencyConversionEnabled = false
        public var isInsufficientBalance = false
        public var isLatestInputFiat = false
        public var isNotAddressInAddressBook = false
        public var isSheetTexAddressVisible = false
        public var isValidAddress = false
        public var isValidTransparentAddress = false
        public var isValidTexAddress = false
        public var memoState: MessageEditor.State
        public var proposal: Proposal?
        @Shared(.inMemory(.selectedWalletAccount)) public var selectedWalletAccount: WalletAccount? = nil
        public var shieldedBalance: Zatoshi
        public var walletBalancesState: WalletBalances.State
        public var requestsAddressFocus = false
        @Shared(.inMemory(.zashiWalletAccount)) public var zashiWalletAccount: WalletAccount? = nil
        public var zecAmountText: RedactableString = .empty
        
        public var sheetHeight: CGFloat = 0.0

        public var amount: Zatoshi {
            get {
                if !_XCTIsTesting {
                    @Dependency(\.numberFormatter) var numberFormatter
                    var amount = Zatoshi.zero
                    
                    guard let number = numberFormatter.number(zecAmountText.data) else {
                        return amount
                    }
                    amount = Zatoshi(NSDecimalNumber(
                        decimal: number.decimalValue * Decimal(Zatoshi.Constants.oneZecInZatoshi)
                    ).roundedZec.int64Value)
                    
                    return amount
                } else {
                    return .zero
                }
            }
            set {
                zecAmountText = newValue.amount == 0 
                ? .empty
                : newValue.decimalString().redacted
            }
        }

        public var currencySymbol: String {
            currencyConversion?.iso4217.symbol ?? ""
        }

        public var feeFormat: String {
            "(\(ZatoshiStringRepresentation.feeFormat))"
        }

        public var feeRequired: Zatoshi {
            proposal?.totalFeeRequired() ?? Zatoshi(0)
        }

        public var message: String {
            memoState.text
        }

        public var isValidAmount: Bool {
            if !_XCTIsTesting {
                @Dependency(\.numberFormatter) var numberFormatter
                
                return numberFormatter.number(zecAmountText.data) != nil
            } else {
                return true
            }
        }
        
        public var isInvalidAddressFormat: Bool {
            !address.data.isEmpty
            && !isValidAddress
        }

        public var isInvalidAmountFormat: Bool {
            if !_XCTIsTesting {
                @Dependency(\.numberFormatter) var numberFormatter
                
                return !zecAmountText.data.isEmpty
                && !isValidAmount
                || (numberFormatter.number(currencyText.data) == nil && !currencyText.data.isEmpty)
            } else {
                return true
            }
        }

        public var isValidForm: Bool {
            isValidAddress
            && !isInsufficientFunds
            && memoState.isValid
            && isValidAmount
            && isTexSendSupported
        }
        
        public var isTexSendSupported: Bool {
            if isValidTexAddress {
                return selectedWalletAccount?.vendor == .zcash
            }
            return true
        }

        public var isInsufficientFunds: Bool {
            guard isValidAmount else { return false }

            return amount.amount > shieldedBalance.amount
        }
        
        public var isMemoInputEnabled: Bool {
            !isValidTransparentAddress && !isValidTexAddress
        }
                
        public var spendableBalanceString: String {
            shieldedBalance.decimalString(formatter: NumberFormatter.zashiBalanceFormatter)
        }
        
        public var invalidAddressErrorText: String? {
            isInvalidAddressFormat
            ? L10n.Send.Error.invalidAddress
            : nil
        }
        
        public var invalidZecAmountErrorText: String? {
            zecAmountText.data.isEmpty
            ? nil
            : isInvalidAmountFormat
            ? L10n.Send.Error.invalidAmount
            : isInsufficientFunds
            ? L10n.Send.Error.insufficientFunds
            : nil
        }
        
        public var invalidCurrencyAmountErrorText: String? {
            currencyText.data.isEmpty
            ? nil
            : isInvalidAmountFormat
            ? L10n.Send.Error.invalidAmount
            : isInsufficientFunds
            ? L10n.Send.Error.insufficientFunds
            : nil
        }
        
        public init(
            addMemoState: Bool,
            memoState: MessageEditor.State,
            shieldedBalance: Zatoshi = .zero,
            walletBalancesState: WalletBalances.State
        ) {
            self.addMemoState = addMemoState
            self.memoState = memoState
            self.shieldedBalance = shieldedBalance
            self.walletBalancesState = walletBalancesState
        }
    }

    public enum Action: BindableAction {
        case addNewContactTapped(RedactableString)
        case addressBookTapped
        case addressUpdated(RedactableString)
        case alert(PresentationAction<Action>)
        case balances(Balances.Action)
        case balancesBindingUpdated(Bool)
        case binding(BindingAction<SendForm.State>)
        case confirmationRequired(Confirmation)
        case dismissRequired
        case getProposal(Confirmation)
        case gotTexSupportTapped
        case currencyUpdated(RedactableString)
        case dismissAddressBookHint
        case exchangeRateSetupChanged
        case memo(MessageEditor.Action)
        case onAppear
        case onDisapear
        case proposal(Proposal)
        case requestsAddressFocusResolved
        case requestZec(ParserResult)
        case resetForm
        case reviewTapped
        case scanTapped
        case sendFailed(ZcashError, Confirmation)
        case syncAmounts(Bool)
        case validateAddress
        case walletBalances(WalletBalances.Action)
        case zecAmountUpdated(RedactableString)
    }
    
    @Dependency(\.addressBook) var addressBook
    @Dependency(\.audioServices) var audioServices
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.numberFormatter) var numberFormatter
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.userStoredPreferences) var userStoredPreferences
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    public init() { }
    
    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        Scope(state: \.memoState, action: \.memo) {
            MessageEditor()
        }

        Scope(state: \.walletBalancesState, action: \.walletBalances) {
            WalletBalances()
        }

        Scope(state: \.balancesState, action: \.balances) {
            Balances()
        }

        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.memoState.charLimit = zcashSDKEnvironment.memoCharLimit
                return .send(.exchangeRateSetupChanged)

            case .onDisapear:
                return .cancel(id: state.cancelId)
                
            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none

            case .alert:
                return .none
                
            case .binding:
                return .none
                
            case .balances(.sheetHeightUpdated(let value)):
                state.sheetHeight = value
                return .none

            case .addressBookTapped:
                return .none

            case .addNewContactTapped:
                state.requestsAddressFocus = true
                return .none
                
            case .requestsAddressFocusResolved:
                state.requestsAddressFocus = false
                return .none
                
            case .exchangeRateSetupChanged:
                if let automatic = userStoredPreferences.exchangeRate()?.automatic, automatic {
                    state.isCurrencyConversionEnabled = true
                } else {
                    state.isCurrencyConversionEnabled = false
                }
                return .none

            case let .proposal(proposal):
                state.proposal = proposal
                return .none

            case .walletBalances(.exchangeRateEvent(let result)):
                switch result {
                case .value(let rate), .refreshEnable(let rate):
                    if let rate {
                        state.$currencyConversion.withLock { $0 = CurrencyConversion(.usd, ratio: rate.rate.doubleValue, timestamp: rate.date.timeIntervalSince1970) }
                        return .send(.syncAmounts(true))
                    }
                case .stale:
                    state.$currencyConversion.withLock { $0 = nil }
                    return .none
                }
                return .none
                
            case .reviewTapped:
                return .send(.getProposal(.send))
                
            case .getProposal(let confirmationType):
                guard let account = state.selectedWalletAccount else {
                    return .none
                }
                state.amount = state.isLatestInputFiat ? state.amount.roundToAvoidDustSpend() : state.amount
                return .run { [state, confirmationType] send in
                    do {
                        let recipient = try Recipient(state.address.data, network: zcashSDKEnvironment.network.networkType)
                        
                        let memo: Memo?
                        if state.isValidTransparentAddress || state.isValidTexAddress {
                            memo = nil
                        } else if let memoText = state.addMemoState ? state.memoState.text : nil {
                            memo = memoText.isEmpty ? nil : try Memo(string: memoText)
                        } else {
                            memo = nil
                        }

                        let proposal = try await sdkSynchronizer.proposeTransfer(account.id, recipient, state.amount, memo)
                        
                        await send(.proposal(proposal))
                        await send(.confirmationRequired(confirmationType))
                    } catch {
                        await send(.sendFailed(error.toZcashError(), confirmationType))
                    }
                }
                
            case let .sendFailed(error, confirmationType):
                if error.isInsufficientBalance {
                    state.isInsufficientBalance = error.isInsufficientBalance
                    return .none
                }
                if confirmationType == .send {
                    state.alert = AlertState.sendFailure(error)
                }
                return .none

            case .confirmationRequired:
                return .none

            case .resetForm:
                state.memoState.text = ""
                state.address = .empty
                state.zecAmountText = .empty
                state.currencyText = .empty
                state.isValidAddress = false
                state.isValidTransparentAddress = false
                state.isValidTexAddress = false
                state.isNotAddressInAddressBook = false
                return .none
                
            case .syncAmounts(let zecToCurrency):
                guard let currencyConversion = state.currencyConversion else {
                    return .none
                }
                if zecToCurrency {
                    if state.zecAmountText.data.isEmpty || !state.isValidAmount {
                        state.currencyText = .empty
                    } else {
                        let value: Double = currencyConversion.convert(Zatoshi(state.amount.amount))
                        state.currencyText = Decimal(value).formatted(.number.precision(.fractionLength(2))).redacted
                    }
                } else {
                    if let number = numberFormatter.number(state.currencyText.data) {
                        if let value = Double(exactly: number) {
                            let value2 = currencyConversion.convert(value)
                            state.zecAmountText = value2.decimalString().redacted
                        }
                    } else if state.currencyText.data.isEmpty {
                        state.zecAmountText = .empty
                    }
                }
                return .none

            case .memo:
                return .none
                
            case .requestZec(let requestPayment):
                if case .legacy(let address) = requestPayment {
                    audioServices.systemSoundVibrate()
                    return .send(.addressUpdated(address.value.redacted))
                } else if case .request(let paymentRequest) = requestPayment {
                    if let payment = paymentRequest.payments.first {
                        if let memoBytes = payment.memo, let memo = try? Memo(bytes: [UInt8](memoBytes.memoData)) {
                            state.memoState.text = memo.toString() ?? ""
                        }
                        // Amount can be nil since ZIP-321 requests can contain no amount, use only address.
                        guard let paymentAmount = payment.amount else {
                            audioServices.systemSoundVibrate()
                            return .send(.addressUpdated(payment.recipientAddress.value.redacted))
                        }
                        let numberLocale = numberFormatter.convertUSToLocale(paymentAmount.toString()) ?? ""
                        audioServices.systemSoundVibrate()
                        return .concatenate(
                            .send(.zecAmountUpdated(numberLocale.redacted)),
                            .send(.addressUpdated(payment.recipientAddress.value.redacted)),
                            .send(.getProposal(.requestPayment))
                        )
                    }
                }
                return .none

            case .walletBalances(.balanceUpdated):
                state.shieldedBalance = state.walletBalancesState.shieldedBalance
                return .none
                
            case .walletBalances(.availableBalanceTapped):
                state.balancesBinding = true
                return .none
                
            case .balancesBindingUpdated(let newState):
                state.balancesBinding = newState
                return .none

            case .balances(.dismissTapped):
                state.balancesBinding = false
                return .none
                
            case .balances(.shieldFundsTapped):
                state.balancesBinding = false
                return .none
                
            case .balances(.everythingSpendable):
                if state.balancesBinding {
                    state.balancesBinding = false
                }
                return .none

            case .balances:
                return .none

            case .walletBalances:
                return .none
                
            case .addressUpdated(let newValue):
                let network = zcashSDKEnvironment.network.networkType
                state.address = newValue
                state.isValidAddress = derivationTool.isZcashAddress(state.address.data, network)
                state.isValidTransparentAddress = derivationTool.isTransparentAddress(state.address.data, network)
                state.isValidTexAddress = derivationTool.isTexAddress(state.address.data, network)
                if !state.isMemoInputEnabled {
                    state.memoState.text = ""
                }
                state.isNotAddressInAddressBook = state.isValidAddress
                var isNotAddressInAddressBook = state.isNotAddressInAddressBook
                if state.isValidAddress {
                    for contact in state.addressBookContacts.contacts {
                        if contact.address == state.address.data {
                            state.isNotAddressInAddressBook = false
                            isNotAddressInAddressBook = false
                            break
                        }
                    }
                }
                
                if state.selectedWalletAccount?.vendor == .keystone {
                    state.isSheetTexAddressVisible = state.isValidTexAddress
                }
                
                if isNotAddressInAddressBook {
                    state.isAddressBookHintVisible = true
                    return .run { send in
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        await send(.dismissAddressBookHint)
                    }
                    .cancellable(id: state.cancelId)
                } else {
                    state.isAddressBookHintVisible = false
                    return .cancel(id: state.cancelId)
                }
                
            case .dismissAddressBookHint:
                state.isAddressBookHintVisible = false
                return .none
                
            case .currencyUpdated(let newValue):
                state.currencyText = newValue
                state.isLatestInputFiat = true
                return .send(.syncAmounts(false))
                
            case .validateAddress:
                let network = zcashSDKEnvironment.network.networkType
                state.isValidAddress = derivationTool.isZcashAddress(state.address.data, network)
                state.isValidTransparentAddress = derivationTool.isTransparentAddress(state.address.data, network)
                state.isValidTexAddress = derivationTool.isTexAddress(state.address.data, network)
                if state.selectedWalletAccount?.vendor == .keystone {
                    state.isSheetTexAddressVisible = state.isValidTexAddress
                }
                return .none
                
            case .zecAmountUpdated(let newValue):
                state.zecAmountText = newValue
                state.isLatestInputFiat = false
                return .send(.syncAmounts(true))
                
            case .dismissRequired:
                return .none
                
            case .scanTapped:
                return .none
                
            case .gotTexSupportTapped:
                state.isSheetTexAddressVisible = false
                return .none
            }
        }
    }
}

// MARK: Alerts

extension AlertState where Action == SendForm.Action {
    public static func sendFailure(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(L10n.Send.Alert.Failure.title)
        } message: {
            TextState(L10n.Send.Alert.Failure.message(error.detailedMessage))
        }
    }
}
