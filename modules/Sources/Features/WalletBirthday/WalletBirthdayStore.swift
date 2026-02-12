//
//  WalletBirthdayStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-31-2025.
//

import Foundation
import ComposableArchitecture

import Generated
import SDKSynchronizer
import Utils
import ZcashLightClientKit
import Pasteboard
import UIComponents
import ZcashSDKEnvironment

@Reducer
public struct WalletBirthday {
    enum Constants {
        static let startYear: Int = 2018
        static let startMonth: Int = 10
    }
    
    @ObservableState
    public struct State: Equatable {
        public var birthday = ""
        public var estimatedHeight = BlockHeight(0)
        public var isValidBirthday = false
        public var months: [String] = []
        public var selectedMonth = ""
        public var selectedYear = Constants.startYear
        @Shared(.inMemory(.toast)) public var toast: Toast.Edge? = nil
        public var years: [Int] = []

        public var estimatedHeightString: String {
            Zatoshi(Int64(estimatedHeight * 100_000_000)).decimalString()
        }
        
        public init() { }
    }
    
    public enum Action: BindableAction, Equatable {
        case binding(BindingAction<WalletBirthday.State>)
        case copyBirthdayTapped
        case estimateHeightReady
        case estimateHeightRequested
        case estimateHeightTapped
        case helpSheetRequested
        case onAppear
        case restoreTapped
        case updateMonths
    }

    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.pasteboard) var pasteboard
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    public init() { }

    public var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                let currentYear = Calendar.current.component(.year, from: Date())
                state.years = Array(Constants.startYear...currentYear)
                state.estimatedHeight = zcashSDKEnvironment.network.constants.saplingActivationHeight
                return .send(.updateMonths)
            
            case .binding(\.birthday):
                let saplingActivation = zcashSDKEnvironment.network.constants.saplingActivationHeight

                if let birthdayHeight = BlockHeight(state.birthday), birthdayHeight >= saplingActivation {
                    state.estimatedHeight = birthdayHeight
                    state.isValidBirthday = true
                } else {
                    state.isValidBirthday = false
                }
                return .none
                
            case .binding(\.selectedYear):
                return .send(.updateMonths)

            case .binding:
                return .none

            case .restoreTapped:
                return .none
                
            case .copyBirthdayTapped:
                pasteboard.setString(state.birthday.redacted)
                state.$toast.withLock { $0 = .top(L10n.General.copiedToTheClipboard) }
                return .none

            case .updateMonths:
                let currentYear = Calendar.current.component(.year, from: Date())
                let currentMonth = Calendar.current.component(.month, from: Date())
                let formatter = DateFormatter()
                formatter.locale = Locale.current
                if state.selectedYear > Constants.startYear && state.selectedYear < currentYear {
                    state.months = formatter.monthSymbols
                } else if state.selectedYear == Constants.startYear {
                    state.months = formatter.monthSymbols.suffix(13 - Constants.startMonth)
                    if !state.months.contains(state.selectedMonth) {
                        if let first = state.months.first {
                            state.selectedMonth = first
                        }
                    }
                } else if state.selectedYear == currentYear {
                    state.months = Array(formatter.monthSymbols.prefix(currentMonth))
                    if !state.months.contains(state.selectedMonth) {
                        if let last = state.months.last {
                            state.selectedMonth = last
                        }
                    }
                }
                return .none
                
            case .helpSheetRequested:
                return .none
                
            case .estimateHeightRequested:
                // compute date based on the picker state
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MMMM yyyy"
                dateFormatter.locale = Locale(identifier: "en_US_POSIX")
                if let date = dateFormatter.date(from: "\(state.selectedMonth) \(state.selectedYear)") {
                    state.estimatedHeight = sdkSynchronizer.estimateBirthdayHeight(date)
                    state.isValidBirthday = true
                    return .send(.estimateHeightReady)
                } else {
                    state.estimatedHeight = BlockHeight(0)
                    state.isValidBirthday = false
                }
                return .none

            case .estimateHeightReady:
                return .none
                
            case .estimateHeightTapped:
                return .none
            }
        }
    }
}
