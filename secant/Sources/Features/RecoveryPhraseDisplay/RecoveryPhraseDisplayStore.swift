//
//  RecoveryPhraseDisplayStore.swift
//  Zashi
//
//  Created by Francisco Gindre on 10/26/21.
//

import Foundation
import Combine
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
        var isSeedUnavailable = false
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
        case recoveryPhraseRevealFailed(ZcashError)
        case recoveryPhraseRevealed(StoredWallet)
        case recoveryPhraseUnhideRequested
        case remindMeLaterTapped
        case securityWarningNextTapped
        case seedSavedTapped
        case tooltipTapped
    }
    
    @Dependency(\.localAuthentication) var localAuthentication
    @Dependency(\.numberFormatter) var numberFormatter
    @Dependency(\.walletStorage) var walletStorage

    private enum CancelID { case reveal }

    init() {}
    
    var body: some Reducer<State, Action> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear, .hideEverything:
                // Seed material is kept out of the state until the user passes
                // local authentication in the reveal path below.
                state.isRecoveryPhraseHidden = true
                state.phrase = nil
                state.birthday = nil
                state.birthdayValue = nil
                state.isSeedUnavailable = false
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
                    // macOS: the SE seed decrypt below is the single biometric gate
                    // (see `authenticateForSeedDecrypt`); iOS prompts here.
                    guard await localAuthentication.authenticateForSeedDecrypt(for: .revealRecoveryPhrase) else {
                        return
                    }

                    // The keychain export runs here, inside the effect (off the
                    // main actor), so the blocking read + decode never stalls the
                    // reducer. The seed reaches the state only via the action below,
                    // and only after authentication has already succeeded.
                    do {
                        let storedWallet = try await walletStorage.exportWallet(AuthenticationContext.revealRecoveryPhrase.localizedReason)
                        await send(.recoveryPhraseRevealed(storedWallet))
                    } catch {
                        await send(.recoveryPhraseRevealFailed(error.toZcashError()))
                    }
                }
                .cancellable(id: CancelID.reveal, cancelInFlight: true)

            case let .recoveryPhraseRevealed(storedWallet):
                state.birthday = storedWallet.birthday

                if let value = state.birthday?.value() {
                    state.birthdayValue = String(value)
                }

                let seedWords = storedWallet.seedPhrase.value().split(separator: " ").map { RedactableString(String($0)) }
                state.phrase = RecoveryPhrase(words: seedWords)
                state.isRecoveryPhraseHidden = false
                state.isSeedUnavailable = false
                return .none

            case let .recoveryPhraseRevealFailed(error):
                state.isSeedUnavailable = true
                state.alert = AlertState.storedWalletFailure(error)
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
