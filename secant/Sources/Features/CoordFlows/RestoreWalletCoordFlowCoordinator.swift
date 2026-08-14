//
//  RestoreWalletCoordFlowCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 27-03-2025.
//

import ComposableArchitecture
@preconcurrency import ZcashLightClientKit
import MnemonicSwift
import os
import Foundation

// [#1755] restore-flow diagnostics: the resolveRestore → commitRestore chain had
// silent dead-ends (nil-birthday guards, the DB-present relevance branch). These lines
// make an on-device "tap restore → nothing happens" self-explaining in Console/Xcode —
// filter on the `restore-flow` category. No seed material or PII is ever logged.
private let restoreFlowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "co.ecc.zashi",
    category: "restore-flow"
)

// [#1755] A dead CTA is worse than an error alert. The nil-birthday guards used to
// `return .none`, silently eating the Restore tap; they now surface through the
// existing `failedToRecover` sink so the user (and QA) always sees SOMETHING.
private enum RestoreFlowGuardError: Error {
    case missingBirthday
}

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

                    // Deliberately does NOT pre-acknowledge the Ironwood announcement. Ironwood is
                    // news about the network, not about this wallet, so a brand-new wallet gets it
                    // like everyone else once the chain tip is known. Root's safety gate is what
                    // keeps it from landing mid-onboarding — it requires the user to be idle on
                    // Home with no flow pushed.
                    return .send(.newWalletSuccessfulyCreated)
                } catch {
                    state.alert = AlertState.cantCreateNewWallet(error.toZcashError())
                }
                return .none

            case .importExistingWallet:
                state.path.append(.recoverySeedPhraseEntry(state))
                return .none
                
            case .resolveRestoreTapped:
                var copyState = state
                restoreFlowLogger.info("[#1755] resolveRestoreTapped → presenting Tor sheet (birthday set: \(copyState.birthday != nil, privacy: .public))")
                state.isTorOn = false
                state.isTorSheetPresented = true
                return .none

            case .resolveRestore:
                guard state.birthday != nil else {
                    restoreFlowLogger.error("[#1755] resolveRestore: birthday is nil — surfacing failedToRecover (was a silent dead end)")
                    return .send(.failedToRecover(RestoreFlowGuardError.missingBirthday.toZcashError()))
                }
                let seedPhrase = state.words.joined(separator: " ")
                do {
                    // validate the seed
                    try mnemonic.isValid(seedPhrase)
                } catch {
                    restoreFlowLogger.error("[#1755] resolveRestore: seed invalid → failedToRecover alert")
                    return .send(.failedToRecover(error.toZcashError()))
                }
                // Preventive guard ([#1024]): if a wallet DB is already on disk, the entered seed MUST be
                // relevant to it — otherwise it belongs to a different wallet and importing it over the
                // existing DB desyncs the keychain seed from data.db (the USK no longer matches any account,
                // so every send fails with `createToAddress` "Wallet does not contain an account…").
                if databaseFiles.areDbFilesPresentFor(zcashSDKEnvironment.network()) {
                    restoreFlowLogger.info("[#1755] resolveRestore: DB files PRESENT → awaiting isSeedRelevantToAnyDerivedAccount…")
                    return .run { send in
                        do {
                            let seedBytes = try mnemonic.toSeed(seedPhrase)
                            let relevant = try await sdkSynchronizer.isSeedRelevantToAnyDerivedAccount(seedBytes)
                            restoreFlowLogger.info("[#1755] resolveRestore: relevance answered: \(relevant, privacy: .public)")
                            await send(.seedRelevanceChecked(relevant))
                        } catch {
                            restoreFlowLogger.error("[#1755] resolveRestore: relevance check THREW → failedToRecover alert")
                            await send(.failedToRecover(error.toZcashError()))
                        }
                    }
                }
                restoreFlowLogger.info("[#1755] resolveRestore: no DB on disk → commitRestore")
                return .send(.commitRestore)

            case .seedRelevanceChecked(let relevant):
                // relevant → the entered seed matches the existing DB (same wallet); import silently and
                // keep the already-synced data.db. not relevant → a different wallet; warn before we ever
                // write the seed to the keychain (Root presents the alert and drives the wipe).
                return relevant ? .send(.commitRestore) : .send(.seedNotRelevantToExistingDB)

            case .seedNotRelevantToExistingDB:
                // Handled by the Root reducer (presents `differentSeed()` + offers Start over / Try again).
                restoreFlowLogger.error("[#1755] seed NOT relevant to existing DB → Root should present differentSeed alert")
                return .none

            case .failedToRecover(let error):
                // [#1755] THE dead-CTA root cause: this sink was declared and sent from every
                // restore error path (invalid seed, relevance-check failure, importWallet failure,
                // missing birthday) but never reduced anywhere — the `default: return .none`
                // swallowed it, so a failed restore looked like a Restore button doing nothing.
                restoreFlowLogger.error("[#1755] failedToRecover → presenting alert (code: \(error.code.rawValue, privacy: .public))")
                state.alert = AlertState.failedToRecover(error)
                return .none

            case .commitRestore:
                guard let birthday = state.birthday else {
                    restoreFlowLogger.error("[#1755] commitRestore: birthday is nil — surfacing failedToRecover (was a silent dead end)")
                    return .send(.failedToRecover(RestoreFlowGuardError.missingBirthday.toZcashError()))
                }
                do {
                    let seedPhrase = state.words.joined(separator: " ")

                    try walletStorage.importWallet(seedPhrase, birthday, .english, false)

                    // update the backup phrase validation flag
                    try walletStorage.markUserPassedPhraseBackupTest(true)

#if os(macOS)
                    // S3 (seed-input hardening — see docs/macos/SEED_INPUT_SECURITY.md): the user very
                    // likely pasted their full phrase from a password manager, and on macOS the clipboard
                    // is readable by any process (and persisted by clipboard-history managers). If it still
                    // holds the just-restored seed, wipe it. The exact-match guard means we ONLY ever clear
                    // the seed itself — never unrelated clipboard content the user put there.
                    if let clipboard = pasteboard.getString()?.data,
                       clipboard.normalizedSeedPhrase == seedPhrase.normalizedSeedPhrase {
                        pasteboard.setString("".redacted)
                    }
#endif

                    restoreFlowLogger.info("[#1755] commitRestore: wallet imported → pushing RestoreInfo (keep-open screen)")
                    state.path.append(.restoreInfo(RestoreInfo.State.initial))

                    // notify user
                    return .send(.successfullyRecovered)
                } catch {
                    restoreFlowLogger.error("[#1755] commitRestore: importWallet THREW → failedToRecover alert")
                    return .send(.failedToRecover(error.toZcashError()))
                }

            case .resolveRestoreRequested:
                var copyState = state
                restoreFlowLogger.info("[#1755] Tor sheet resolved (isTorOn: \(copyState.isTorOn, privacy: .public)) → resolveRestore")
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

#if os(macOS)
private extension String {
    /// Whitespace- and case-normalized form, used to safely compare the just-restored phrase against
    /// the current clipboard contents before wiping the clipboard (S3). Collapses any run of
    /// whitespace to single spaces so trivial formatting differences never cause a false negative.
    var normalizedSeedPhrase: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
#endif
