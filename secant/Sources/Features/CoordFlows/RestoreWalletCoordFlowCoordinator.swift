//
//  RestoreWalletCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 27-03-2025.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import MnemonicSwift

extension RestoreWalletCoordFlow {
    func coordinatorReduce() -> Reduce<RestoreWalletCoordFlow.State, RestoreWalletCoordFlow.Action> {
        Reduce { state, action in
            switch action {
                
                // MARK: - Self

            case .dismissDestination:
                state.path.removeAll()
                return .none
                
            case .restoreCancelTapped:
                state.isTorSheetPresented = false
                return .none

            case .createNewWalletRequested:
                do {
                    // get the random english mnemonic
                    let newRandomPhrase = try mnemonic.randomMnemonic()
                    let birthday = zcashSDKEnvironment.latestCheckpoint()
                    
                    // store the wallet to the keychain
                    try walletStorage.importWallet(newRandomPhrase, birthday, .english, false)

                    return .send(.newWalletSuccessfulyCreated)
                } catch {
                    state.alert = AlertState.cantCreateNewWallet(error.toZcashError())
                }
                return .none

            case .importExistingWallet:
                state.path.append(.recoverySeedPhraseEntry(state))
                return .none
                
            case .resolveRestoreTapped:
                state.isTorOn = false
                state.isTorSheetPresented = true
                return .none

            case .resolveRestore:
                guard state.birthday != nil else {
                    return .none
                }
                let seedPhrase = state.words.joined(separator: " ")
                do {
                    // validate the seed
                    try mnemonic.isValid(seedPhrase)
                } catch {
                    return .send(.failedToRecover(error.toZcashError()))
                }
                // Preventive guard ([#1024]): if a wallet DB is already on disk, the entered seed MUST be
                // relevant to it — otherwise it belongs to a different wallet and importing it over the
                // existing DB desyncs the keychain seed from data.db (the USK no longer matches any account,
                // so every send fails with `createToAddress` "Wallet does not contain an account…").
                if databaseFiles.areDbFilesPresentFor(zcashSDKEnvironment.network()) {
                    return .run { send in
                        do {
                            let seedBytes = try mnemonic.toSeed(seedPhrase)
                            let relevant = try await sdkSynchronizer.isSeedRelevantToAnyDerivedAccount(seedBytes)
                            await send(.seedRelevanceChecked(relevant))
                        } catch {
                            await send(.failedToRecover(error.toZcashError()))
                        }
                    }
                }
                return .send(.commitRestore)

            case .seedRelevanceChecked(let relevant):
                // relevant → the entered seed matches the existing DB (same wallet); import silently and
                // keep the already-synced data.db. not relevant → a different wallet; warn before we ever
                // write the seed to the keychain (Root presents the alert and drives the wipe).
                return relevant ? .send(.commitRestore) : .send(.seedNotRelevantToExistingDB)

            case .seedNotRelevantToExistingDB:
                // Handled by the Root reducer (presents `differentSeed()` + offers Start over / Try again).
                return .none

            case .commitRestore:
                guard let birthday = state.birthday else {
                    return .none
                }
                do {
                    let seedPhrase = state.words.joined(separator: " ")

                    try walletStorage.importWallet(seedPhrase, birthday, .english, false)

                    // update the backup phrase validation flag
                    try walletStorage.markUserPassedPhraseBackupTest(true)

                    state.path.append(.restoreInfo(RestoreInfo.State.initial))

                    // notify user
                    return .send(.successfullyRecovered)
                } catch {
                    return .send(.failedToRecover(error.toZcashError()))
                }
                
            case .resolveRestoreRequested:
                state.isTorSheetPresented = false
                let isTorOn = state.isTorOn
                try? walletStorage.importTorSetupFlag(isTorOn)
                return .merge(
                    .send(.resolveRestore),
                    .run { _ in try? await sdkSynchronizer.torEnabled(isTorOn) }
                )

                // MARK: Recovery Seed Phrase Entry
                
            case .path(.element(id: _, action: .recoverySeedPhraseEntry(.nextTapped))):
                for element in state.path {
                    if case .recoverySeedPhraseEntry(let recoverySeedPhraseEntryState) = element {
                        state.words = recoverySeedPhraseEntryState.words
                    }
                }
                state.path.append(.walletBirthday(WalletBirthday.State.initial))
                return .none
                
            case .path(.element(id: _, action: .recoverySeedPhraseEntry(.helpSheetRequested))),
                .path(.element(id: _, action: .estimatedBirthday(.helpSheetRequested))):
                state.isHelpSheetPresented.toggle()
                return .none

                // MARK: - Wallet Birthday

            case .path(.element(id: _, action: .walletBirthday(.helpSheetRequested))):
                state.isHelpSheetPresented.toggle()
                return .none

            case .path(.element(id: _, action: .walletBirthday(.estimateHeightTapped))):
                state.path.append(.estimateBirthdaysDate(WalletBirthday.State.initial))
                return .none

            case .path(.element(id: _, action: .walletBirthday(.restoreTapped))):
                for element in state.path {
                    if case .walletBirthday(let walletBirthdayState) = element {
                        state.birthday = walletBirthdayState.estimatedHeight
                        return .send(.resolveRestoreTapped)
                    }
                }
                return .none
                
            case .path(.element(id: _, action: .estimateBirthdaysDate(.helpSheetRequested))):
                state.isHelpSheetPresented.toggle()
                return .none

            case .path(.element(id: _, action: .estimateBirthdaysDate(.estimateHeightReady))):
                for element in state.path {
                    if case .estimateBirthdaysDate(let estimateBirthdaysDateState) = element {
                        state.path.append(.estimatedBirthday(estimateBirthdaysDateState))
                    }
                }
                return .none
                
            case .path(.element(id: _, action: .estimatedBirthday(.restoreTapped))):
                for element in state.path {
                    if case .estimatedBirthday(let estimatedBirthdayState) = element {
                        state.birthday = estimatedBirthdayState.estimatedHeight
                        return .send(.resolveRestoreTapped)
                    }
                }
                return .none

            default: return .none
            }
        }
    }
}
