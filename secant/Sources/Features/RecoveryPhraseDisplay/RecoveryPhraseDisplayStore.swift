//
//  RecoveryPhraseDisplayStore.swift
//  Zashi
//
//  Created by Francisco Gindre on 10/26/21.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct RecoveryPhraseDisplay {
    @ObservableState
    struct State: Equatable {
        @Presents var alert: AlertState<Action>?
        var birthday: Birthday?
        var birthdayValue: String?
        var isBirthdayHintVisible = false
        var isHelpSheetPresented = false
        var isRecoveryPhraseHidden = true
        var isWalletBackup = false
        var phrase: RecoveryPhrase?

        enum LearnMoreOptions: CaseIterable {
            case control
            case keep
            case store
            case height

            func title() -> String {
                switch self {
                case .control: return String(localizable: .recoveryPhraseDisplayWarningControlTitle)
                case .keep: return String(localizable: .recoveryPhraseDisplayWarningKeepTitle)
                case .store: return String(localizable: .recoveryPhraseDisplayWarningStoreTitle)
                case .height: return String(localizable: .recoveryPhraseDisplayWarningHeightTitle)
                }
            }

            func subtitle() -> String {
                switch self {
                case .control: return String(localizable: .recoveryPhraseDisplayWarningControlInfo)
                case .keep: return String(localizable: .recoveryPhraseDisplayWarningKeepInfo)
                case .store: return String(localizable: .recoveryPhraseDisplayWarningStoreInfo)
                case .height: return String(localizable: .recoveryPhraseDisplayWarningHeightInfo)
                }
            }

            func icon() -> ImageAsset {
                switch self {
                case .control: return Asset.Assets.Icons.cryptocurrency
                case .keep: return Asset.Assets.Icons.emptyShield
                case .store: return Asset.Assets.Icons.archive
                case .height: return Asset.Assets.Icons.calendar
                }
            }
        }
        
        init(
            birthday: Birthday? = nil,
            birthdayValue: String? = nil,
            phrase: RecoveryPhrase? = nil
        ) {
            self.birthday = birthday
            self.birthdayValue = birthdayValue
            self.phrase = phrase
        }
    }
    
    enum Action: BindableAction, Equatable {
        case binding(BindingAction<RecoveryPhraseDisplay.State>)
        case alert(PresentationAction<Action>)
        case finishedTapped
        case helpSheetRequested
        case hideEverything
        case onAppear
        case recoveryPhraseTapped
        case recoveryPhraseUnhideRequested
        case remindMeLaterTapped
        case securityWarningNextTapped
        case seedSavedTapped
        case tooltipTapped
    }
    
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.numberFormatter) var numberFormatter
    @Dependency(\.walletStorage) var walletStorage

    init() {}
    
    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // __LD TESTED
                state.isRecoveryPhraseHidden = true
                do {
                    let storedWallet = try walletStorage.exportWallet()
                    state.birthday = storedWallet.birthday
                    
                    if let value = state.birthday?.value() {
                        state.birthdayValue = String(value)
                    }
                    
                    let seedWords = storedWallet.seedPhrase.value().split(separator: " ").map { RedactableString(String($0)) }
                    state.phrase = RecoveryPhrase(words: seedWords)
                } catch {
                    state.alert = AlertState.storedWalletFailure(error.toZcashError())
                }
                
                return .none
                
            case .hideEverything:
                state.isRecoveryPhraseHidden = true
                return .none

            case .alert(.presented(let action)):
                return .send(action)

            case .alert(.dismiss):
                state.alert = nil
                return .none
                
            case .binding:
                return .none
                
            case .finishedTapped:
                return .none
                
            case .tooltipTapped:
                state.isBirthdayHintVisible.toggle()
                return .none
                
            case .recoveryPhraseUnhideRequested:
                return .run { send in
                    guard await localAuthentication.authenticate() else {
                        return
                    }
                    
                    await send(.recoveryPhraseTapped)
                }

            case .recoveryPhraseTapped:
                state.isRecoveryPhraseHidden.toggle()
                return .none
                
            case .securityWarningNextTapped:
                return .none
                
            case .helpSheetRequested:
                state.isHelpSheetPresented.toggle()
                return .none
                
            case .seedSavedTapped:
                return .none
                
            case .remindMeLaterTapped:
                return .none
            }
        }
    }
}

// MARK: Alerts

extension AlertState where Action == RecoveryPhraseDisplay.Action {
    static func storedWalletFailure(_ error: ZcashError) -> AlertState {
        AlertState {
            TextState(String(localizable: .recoveryPhraseDisplayAlertFailedTitle))
        } message: {
            TextState(String(localizable: .recoveryPhraseDisplayAlertFailedMessage(error.detailedMessage)))
        }
    }
}
