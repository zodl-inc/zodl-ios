//
//  ZecKeyboardStore.swift
//  modules
//
//  Created by Lukáš Korba on 20.09.2024.
//

import Foundation
import SwiftUI
import UIKit
import ComposableArchitecture
import ZcashLightClientKit
import Generated
import Utils
import Models

@Reducer
public struct ZecKeyboard {
    public enum Constants {
        static let initialValue = "0"
    }
    
    @ObservableState
    public struct State: Equatable {
        public var amount: Zatoshi = .zero
        public var decimalSeparator = ""
        public var convertedInput = Constants.initialValue
        @Shared(.inMemory(.exchangeRate)) public var currencyConversion: CurrencyConversion? = nil
        public var currencyValue: Double = 0
        public var humanReadableConvertedInput = ""
        public var humanReadableMainInput = ""
        public var input = Constants.initialValue
        public var isInputInZec = true
        public var isCurrencySymbolPrefix = false
        public var isValidInput = true
        public var isZeroOutputAllowed = false
        public var keys: [String] = []
        public var localeCurrencySymbol = ""

        public var isNextButtonDisabled: Bool {
            amount.amount == 0 && !isZeroOutputAllowed
        }
        
        public init() { }
    }

    public enum Action: Equatable {
        case longKeyTapped(Int)
        case keyTapped(Int)
        case nextTapped
        case onAppear
        case reportInvalidInput
        case resolveHumanReadableStrings
        case revertLastInput
        case swapCurrenciesTapped
        case validateInputs
    }

    public init() { }

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                if let decimalSeparator = Locale.current.decimalSeparator {
                    state.decimalSeparator = decimalSeparator
                    state.keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", decimalSeparator, "0", "x"]
                }
                if state.input == Constants.initialValue {
                    state.isInputInZec = true
                }
                return .send(.validateInputs)
                
            case .swapCurrenciesTapped:
                state.isInputInZec.toggle()
                if state.amount.amount > 0 {
                    state.input = state.convertedInput
                    return .send(.validateInputs)
                }
                return .send(.resolveHumanReadableStrings)
                
            case .longKeyTapped(let index):
                // backspace
                if index == 11 {
                    state.input = Constants.initialValue
                    return .send(.validateInputs)
                }
                return .none
                
            case .keyTapped(let index):
                let inputSides = state.input.split(separator: Character(state.decimalSeparator))
                if inputSides.count == 2, inputSides[1].count >= 8 && index != 11 {
                    return .none
                }

                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                impactFeedback.impactOccurred()

                // backspace
                if index == 11 {
                    let newValue = String(state.input.dropLast())
                    state.input =  newValue.isEmpty ? Constants.initialValue : newValue
                } else if index == 9 {
                    // decimal separator
                    if !state.input.contains(state.decimalSeparator) {
                        state.input += state.decimalSeparator
                    }
                } else {
                    // some number
                    if state.input == Constants.initialValue {
                        state.input = state.keys[index]
                    } else {
                        if state.isInputInZec {
                            state.input += state.keys[index]
                        } else {
                            let split = state.input.split(separator: Character(state.decimalSeparator))
                            
                            if split.count == 2 {
                                if split[1].count < 8 {
                                    state.input += state.keys[index]
                                }
                            } else {
                                state.input += state.keys[index]
                            }
                        }
                    }
                }

                return .send(.validateInputs)
                
            case .validateInputs:
                let numberFormatter = NumberFormatter()
                numberFormatter.maximumFractionDigits = 8
                numberFormatter.maximumIntegerDigits = 8
                numberFormatter.numberStyle = .decimal
                numberFormatter.usesGroupingSeparator = false

                if let currencyConversion = state.currencyConversion {
                    // ZEC
                    if state.isInputInZec {
                        var amount = Zatoshi.zero
                        
                        guard let inputToNumber = numberFormatter.number(from: state.input) else {
                            return .send(.reportInvalidInput)
                        }
                        
                        amount = Zatoshi(
                            NSDecimalNumber(
                                decimal: inputToNumber.decimalValue * Decimal(Zatoshi.Constants.oneZecInZatoshi)
                            ).roundedZec.int64Value)
                        
                        // valid range
                        if amount.amount < Zatoshi.Constants.maxZatoshi {
                            state.amount = amount
                            state.currencyValue = currencyConversion.convert(amount)
                            state.convertedInput = Decimal(state.currencyValue).formatted(.number.grouping(.never))
                            state.isValidInput = true
                        } else {
                            // revert last input
                            return .send(.revertLastInput)
                        }
                    } else {
                        // USD
                        guard let inputToNumber = numberFormatter.number(from: state.input) else {
                            return .send(.reportInvalidInput)
                        }

                        guard let currencyValue = Double(exactly: inputToNumber) else {
                            return .send(.reportInvalidInput)
                        }
                        
                        state.currencyValue = currencyValue
                        let valueInZec = currencyConversion.convert(currencyValue)

                        // valid range
                        if valueInZec.amount < Zatoshi.Constants.maxZatoshi {
                            if let stringValue = numberFormatter.string(from: valueInZec.decimalValue.roundedZec) {
                                state.convertedInput = stringValue
                                state.amount = valueInZec
                            } else {
                                state.isValidInput = false
                            }
                        } else {
                            // revert input
                            return .send(.revertLastInput)
                        }
                        state.isValidInput = true
                    }
                } else {
                    // ZEC only input
                    var amount = Zatoshi.zero
                    if let number = numberFormatter.number(from: state.input) {
                        amount = Zatoshi(
                            NSDecimalNumber(
                                decimal: number.decimalValue * Decimal(Zatoshi.Constants.oneZecInZatoshi)
                        ).roundedZec.int64Value)
                        
                        // valid range
                        if amount.amount < Zatoshi.Constants.maxZatoshi {
                            state.amount = amount
                            state.isValidInput = true
                        } else {
                            // revert last input
                            return .send(.revertLastInput)
                        }
                    } else {
                        state.isValidInput = false
                    }
                }
                return .send(.resolveHumanReadableStrings)
                
            case .reportInvalidInput:
                state.isValidInput = false
                return .send(.resolveHumanReadableStrings)

            case .revertLastInput:
                let numberFormatter = NumberFormatter()
                numberFormatter.maximumFractionDigits = 8
                numberFormatter.maximumIntegerDigits = 8
                numberFormatter.numberStyle = .decimal
                numberFormatter.usesGroupingSeparator = false
                
                // ZEC
                if state.isInputInZec {
                    let newValue = String(state.input.dropLast())
                    state.input =  newValue.isEmpty ? Constants.initialValue : newValue
                    
                    if let number = numberFormatter.number(from: state.input) {
                        let amount = Zatoshi(
                            NSDecimalNumber(
                                decimal: number.decimalValue * Decimal(Zatoshi.Constants.oneZecInZatoshi)
                            ).roundedZec.int64Value)
                        state.amount = amount
                        if let currencyConversion = state.currencyConversion {
                            state.currencyValue = currencyConversion.convert(amount)
                            state.convertedInput = Decimal(state.currencyValue).formatted(.number.grouping(.never))
                        }
                        state.isValidInput = true
                    }
                } else {
                    guard let currencyConversion = state.currencyConversion else {
                        return .none
                    }

                    let newValue = String(state.input.dropLast())
                    state.input =  newValue.isEmpty ? Constants.initialValue : newValue
                    if let number = numberFormatter.number(from: state.input) {
                        if let currencyValue = Double(exactly: number) {
                            state.currencyValue = currencyValue
                            let valueInZec = currencyConversion.convert(currencyValue)
                            
                            if let stringValue = numberFormatter.string(from: valueInZec.decimalValue.roundedZec) {
                                state.convertedInput = stringValue
                                state.amount = valueInZec
                            } else {
                                state.isValidInput = false
                            }
                        }
                    }
                }
                return .send(.resolveHumanReadableStrings)
                
            case .resolveHumanReadableStrings:
                let formatter = NumberFormatter()
                formatter.locale = Locale.current
                formatter.numberStyle = .currency
                if let currencyConversion = state.currencyConversion {
                    formatter.currencyCode = currencyConversion.iso4217.code
                }
                formatter.maximumFractionDigits = 8
                let currencySymbol = formatter.currencySymbol ?? ""

                state.localeCurrencySymbol = currencySymbol
                if formatter.positivePrefix.contains(formatter.currencySymbol) {
                    state.isCurrencySymbolPrefix = true
                } else {
                    state.isCurrencySymbolPrefix = false
                }

                if state.isInputInZec {
                    state.humanReadableMainInput = state.amount.decimalString()
                    let inputSides = state.input.split(separator: Character(state.decimalSeparator))
                    if inputSides.count == 2 {
                        if let humanReadableInput = state.humanReadableMainInput.split(separator: Character(state.decimalSeparator)).first {
                            state.humanReadableMainInput = "\(humanReadableInput)\(state.decimalSeparator)\(inputSides[1])"
                        }
                    } else {
                        if let lastChar = state.input.last, String(lastChar) == state.decimalSeparator {
                            state.humanReadableMainInput += state.decimalSeparator
                        }
                    }
                    state.humanReadableConvertedInput = Decimal(state.currencyValue).formatted(.number.precision(.fractionLength(2)))
                } else {
                    state.humanReadableMainInput = Decimal(state.currencyValue).formatted(.number)
                    let inputSides = state.input.split(separator: Character(state.decimalSeparator))
                    if inputSides.count == 2 {
                        if let humanReadableInput = state.humanReadableMainInput.split(separator: Character(state.decimalSeparator)).first {
                            state.humanReadableMainInput = "\(humanReadableInput)\(state.decimalSeparator)\(inputSides[1])"
                        }
                    } else {
                        if let lastChar = state.input.last, String(lastChar) == state.decimalSeparator {
                            state.humanReadableMainInput += state.decimalSeparator
                        }
                    }
                    state.humanReadableConvertedInput = state.amount.decimalString()
                }
                return .none
                
            case .nextTapped:
                return .none
            }
        }
    }
}
