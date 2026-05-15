//
//  WalletBirthdayStore.swift
//  Zashi
//
//  Created by Lukáš Korba on 03-31-2025.
//

import Foundation
import ComposableArchitecture

@preconcurrency import ZcashLightClientKit

@Reducer
struct WalletBirthday {
    enum Constants {
        static let startYear: Int = 2018
        static let startMonth: Int = 10
    }
    
    @ObservableState
    struct State: Equatable {
        var birthday = ""
        var estimatedHeight = BlockHeight(0)
        var isKeystoneFlow = false
        var isResyncFlow = false
        var isValidBirthday = false
        var months: [String] = []
        var selectedMonth = ""
        var selectedYear = Constants.startYear
        @Shared(.inMemory(.toast)) var toast: Toast.Edge? = nil
        var years: [Int] = []

        var estimatedHeightString: String {
            Zatoshi(Int64(estimatedHeight * 100_000_000)).decimalString()
        }

        var heightString: String {
            if !birthday.isEmpty {
                return birthday
            }
            
            return String(estimatedHeight)
        }
        
        var selectedDateString: String {
            "\(selectedMonth) \(selectedYear)"
        }

        init() { }
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<WalletBirthday.State>)
        case copyBirthdayTapped
        case enterManuallyTapped
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

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                let currentYear = Calendar.current.component(.year, from: Date())
                state.years = Array(Constants.startYear...currentYear)
                if state.estimatedHeight < zcashSDKEnvironment.network.constants.saplingActivationHeight {
                    state.estimatedHeight = zcashSDKEnvironment.network.constants.saplingActivationHeight
                }
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
                pasteboard.setString(state.heightString.redacted)
                state.$toast.withLock { $0 = .top(String(localizable: .generalCopiedToTheClipboard)) }
                return .none

            case .updateMonths:
                let currentYear = Calendar.current.component(.year, from: Date())
                let currentMonth = Calendar.current.component(.month, from: Date())
                let formatter = DateFormatter()
                formatter.locale = Locale.current
                let capitalizedMonths = formatter.monthSymbols.map { $0.prefix(1).uppercased() + $0.dropFirst() }
                if state.selectedYear > Constants.startYear && state.selectedYear < currentYear {
                    state.months = capitalizedMonths
                } else if state.selectedYear == Constants.startYear {
                    state.months = Array(capitalizedMonths.suffix(13 - Constants.startMonth))
                    if !state.months.contains(state.selectedMonth) {
                        if let first = state.months.first {
                            state.selectedMonth = first
                        }
                    }
                } else if state.selectedYear == currentYear {
                    state.months = Array(capitalizedMonths.prefix(currentMonth))
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
                dateFormatter.locale = Locale.current
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
                
            case .enterManuallyTapped:
                return .none

            case .estimateHeightTapped:
                return .none
            }
        }
    }
}
