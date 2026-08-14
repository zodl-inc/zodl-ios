//
//  RootCoordinator.swift
//  Zashi
//
//  Created by Lukáš Korba on 07.03.2025.
//

import Combine
import Dispatch
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

extension Root {
    func coordinatorReduce() -> Reduce<Root.State, Root.Action> {
        Reduce { state, action in
            switch action {
                
                // MARK: - Returns to Home

            case .settings(.backToHomeTapped),
                .receive(.backToHomeTapped),
                .walletBackupCoordFlow(.backToHomeTapped),
                .torSetup(.backToHomeTapped),
                .currencyConversionSetup(.backToHomeTapped),
                .backToHomeFromServerSwitchTapped,
                .sendCoordFlow(.sendForm(.dismissRequired)):
                state.path = nil
                return .none
                
                // MARK: - Accounts

            case .home(.walletAccountTapped(let walletAccount)):
                guard state.selectedWalletAccount != walletAccount else {
                    return .none
                }
                state.$selectedWalletAccount.withLock { $0 = walletAccount }
                let switchedEffect = accountSwitchedEffect(state: &state)
                return .merge(
                    switchedEffect,
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    ),
                    // SECURITY (MOB-1352): end any open Flexa session bound to the previous account so a
                    // pending Flexa transaction request can't bind to the newly-selected account.
                    .cancel(id: state.CancelFlexaId)
                )

                // MARK: - Add Keystone HW Wallet Coord Flow

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .restoreInfo(.gotItTapped)))):
                var leavesScreenOpenMutable = false
                for element in state.addKeystoneHWWalletCoordFlowState.path {
                    if case .restoreInfo(let restoreInfoState) = element {
                        leavesScreenOpenMutable = restoreInfoState.isAcknowledged
                    }
                }
                let leavesScreenOpen = leavesScreenOpenMutable
                userDefaults.setValue(leavesScreenOpen, Constants.udLeavesScreenOpen)
                return .run { _ in await autolockHandler.value(leavesScreenOpen) }

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .accountHWWalletSelection(.forgetThisDeviceTapped)))),
                .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .keystoneDeviceReady(.forgetThisDeviceTapped)))):
                state.path = nil
                return .none

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .keystoneDeviceReady(.accountImportSucceeded)))):
                // `AddHWWalletStore`'s `.loadedWalletAccounts` handler (fired immediately before
                // this action, within the SAME `.run` effect as `.accountImported`) writes
                // `state.selectedWalletAccount` directly with no Root-visible "switch" action of
                // its own -- this is the earliest point Root can react to that write, so the
                // transaction/balance reactions fire here rather than waiting for the user to
                // dismiss the "Keystone Connected" confirmation screen (`.keystoneConnected(.closeTapped)`
                // below still runs its own refetch afterward too -- redundant but harmless once the
                // provenance guard on `.fetchedTransactions` is in place). Navigation (pushing
                // `.keystoneConnected`) is owned by `AddKeystoneHWWalletCoordFlowCoordinator`, so this
                // arm leaves `state.path` untouched. The metadata reload merged in below matters here
                // just as much as the transaction/balance reactions: the fetched list gets decorated
                // from `userMetadataProvider`, which holds a single in-memory state for whichever
                // account was loaded last, and a freshly imported Keystone account has no metadata
                // encryption keys yet -- `.resolveMetadataEncryptionKeys` provisions them for every
                // account in `state.walletAccounts`, which `.loadedWalletAccounts` has just
                // repopulated, before `.loadUserMetadata` reloads the in-memory state for the new
                // account.
                let switchedEffect = accountSwitchedEffect(state: &state)
                return .merge(
                    switchedEffect,
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    )
                )

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .accountHWWalletSelection(.accountImportSucceeded)))):
                state.path = nil
                let switchedEffect = accountSwitchedEffect(state: &state)
                return .merge(
                    switchedEffect,
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    )
                )

            case .addKeystoneHWWalletCoordFlow(.path(.element(id: _, action: .keystoneConnected(.closeTapped)))):
                state.path = nil
                state.autoUpdateSwapCandidates.removeAll()
                return .merge(
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    ),
                    .send(.fetchTransactionsForTheSelectedAccount)
                )
                
            case .addKeystoneHWWalletCoordFlow(.addKeystoneHWWallet(.backToHomeTapped)):
                state.path = nil
                return .none

                // MARK: - Add Keystone HW Wallet from Settings

            case .settings(.path(.element(id: _, action: .accountHWWalletSelection(.accountImportSucceeded)))):
                state.path = nil
                let switchedEffect = accountSwitchedEffect(state: &state)
                return .merge(
                    switchedEffect,
                    .send(.loadContacts),
                    .concatenate(
                        .send(.resolveMetadataEncryptionKeys),
                        .send(.loadUserMetadata)
                    )
                )

                // MARK: - Resync Wallet

            case .settings(.resyncFinished):
                guard let birthday = state.settingsState.resyncBirthday else {
                    return .none
                }
                var leavesScreenOpen = false
                for element in state.settingsState.path {
                    if case .resyncRestoreInfo(let restoreInfoState) = element {
                        leavesScreenOpen = restoreInfoState.isAcknowledged
                    }
                }
                userDefaults.setValue(leavesScreenOpen, Constants.udLeavesScreenOpen)
                state.path = nil
                state.isRestoringWallet = true
                userDefaults.setValue(true, Constants.udIsResyncingWallet)
                state.$walletStatus.withLock { $0 = .resyncing }
                let leavesScreenOpenFixed = leavesScreenOpen
                return .concatenate(
                    .run { _ in
                        await autolockHandler.value(leavesScreenOpenFixed)
                    },
                    .publisher {
                        sdkSynchronizer.rewind(.height(blockheight: birthday))
                            .replaceEmpty(with: Void())
                            .map { _ in
                                Root.Action.rewindDone(nil)
                            }
                            .catch { error in
                                Just(Root.Action.rewindDone(error.toZcashError()))
                                    .eraseToAnyPublisher()
                            }
                            .receive(on: mainQueue)
                    }
                    .cancellable(id: state.CancelResyncStateId, cancelInFlight: true),
                    .send(.batteryStateChanged)
                )
                
            case .rewindDone(let zcashError):
                if zcashError == nil {
                    //return .send(.home(.smartBanner(.evaluatePriority45)))
                }
                return .none

                // MARK: - Flexa

            case .flexaOpenRequest:
                flexaHandler.open()
                return .publisher {
                    flexaHandler.onTransactionRequest()
                        .map(Root.Action.flexaOnTransactionRequest)
                        .receive(on: mainQueue)
                }
                .cancellable(id: state.CancelFlexaId, cancelInFlight: true)
                
                // MARK: - Currency Conversion Setup
                
            case .currencyConversionSetup(.skipTapped), .currencyConversionSetup(.enableTapped):
                state.path = nil
                state.homeState.isRateEducationEnabled = false
                return .send(.home(.smartBanner(.closeAndCleanupBanner)))

                // MARK: - Home

            case .home(.settingsTapped):
                state.settingsState = .initial
                state.path = .settings
                return .none
                
            case .home(.receiveTapped):
                state.receiveState = .initial
                state.path = .receive
                return .none

            case .home(.sendTapped):
                state.sendCoordFlowState = .initial
                state.path = .sendCoordFlow
                exchangeRate.refreshExchangeRateUSD()
                return .none

            case .home(.scanTapped):
                state.scanCoordFlowState = .initial
                state.path = .scanCoordFlow
                return .none

            case .home(.flexaTapped), .settings(.payWithFlexaTapped):
                return .send(.flexaOpenRequest)
                
            case .home(.addKeystoneHWWalletTapped):
                state.addKeystoneHWWalletCoordFlowState = .initial
                state.path = .addKeystoneHWWalletCoordFlow
                return .none
                
            case .home(.swapWithNearTapped):
                state.swapAndPayCoordFlowState = .initial
                state.swapAndPayCoordFlowState.isSwapExperience = true
                state.swapAndPayCoordFlowState.swapAndPayState.isSwapExperienceEnabled = true
                state.path = .swapAndPayCoordFlow
                // whether to start on SwapToZEC or fromZEC
                return .send(.swapAndPayCoordFlow(.swapAndPay(.enableSwapToZecExperience)))

            case .home(.payWithNearTapped):
                state.swapAndPayCoordFlowState = .initial
                state.swapAndPayCoordFlowState.isSwapExperience = false
                state.swapAndPayCoordFlowState.swapAndPayState.isSwapExperienceEnabled = false
                state.path = .swapAndPayCoordFlow
                return .none

            case .home(.transactionList(.transactionTapped(let txId))):
                state.transactionsCoordFlowState = .initial
                state.transactionsCoordFlowState.transactionToOpen = txId
                if let index = state.transactions.index(id: txId) {
                    state.transactionsCoordFlowState.transactionDetailsState.transaction = state.transactions[index]
                }
                state.path = .transactionsCoordFlow
                return .none

            case .home(.seeAllTransactionsTapped):
                // [B4-21] PRODUCT DECISION (2026-07-02): the full reset is intended — filters and
                // search live only while the user stays on the Activity screen. On macOS this
                // action is also the section-switch re-entry, so leaving to Send/Receive and
                // coming back means a clean, unfiltered Activity (outline icon, full content).
                // A filter/search carry-over was briefly added here and reverted on that call.
                state.transactionsCoordFlowState = .initial
                state.path = .transactionsCoordFlow
                return .none
                
            case .home(.currencyConversionSetupTapped):
                state.currencyConversionSetupState = .initial
                state.path = .currencyConversionSetup
                return .none

            case .home(.migrationTapped):
                return openMigrationCoordFlow(state: &state)

            case .migrationCoordFlow(.switchServerRequested):
                // N6: the Tor sheet's custom-server escape. Tear the flow down (which discards the
                // still-PROVISIONAL network snapshot — nothing was committed) and open Server Setup.
                // A re-entry afterwards re-forms and re-rolls the endpoint.
                // Reuse the smart banner's own Server Setup entry (the one existing precedent),
                // rather than a second route to the same screen.
                state.serverSetupState = .initial
                state.path = .serverSwitch
                // Audit 2026-08-03 (#15+#19): this teardown is a flow CLOSE like `flowFinished` —
                // it must disarm the flow-presented guard and re-run the re-arms the other close
                // path always had (the banner poke, and the tick respawn a mid-session commit
                // relies on), or a tick loop that self-cancelled earlier stays dead until the
                // next app-open. (The Send-now fence clear that lived here was REMOVED 2026-08-07
                // with the Send-now lanes.)
                migrationManager.setMigrationFlowPresented(state.selectedWalletAccount?.id, false)
                return .merge(
                    .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                        await migrationManager.clearAbandonedNetworkSnapshot(accountUUID)
                    },
                    .send(.home(.smartBanner(.migrationReevaluationRequested))),
                    migrationTickLoopEffect(state: state)
                )

            // G1 (field 2026-08-05): THE IN-FLOW COMMIT CURE. `flowFinished` below re-spawns the
            // tick loop for a run committed mid-session — but only when the user LEAVES the flow,
            // and the session that commits then sits watching the progress screen never does: its
            // R0 open-lane credit is long spent (the log's "afterSync SKIPPED — already driven"),
            // no sync edge is coming on an up-to-date wallet, and the loop was never spawned
            // because the app-open's spawn ran before the run existed. The banner honestly said
            // "Keep Zodl open" while nothing in the session could ever discharge the first
            // preparation. So: spawn the loop the moment the run is BORN, from both commit
            // delegates (the scheduled plan's and the review screen's). Idempotent —
            // `cancelInFlight: true` makes a duplicate spawn a restart, and every guard
            // (off switch, activation, committed candidate) lives inside the effect itself.
            // And drive the newborn run's first step RIGHT NOW (Lukas, 2026-08-05: "I was hoping
            // to trigger first nextStep with the start migration button") — the same at-tip
            // `.afterSync` drive `flowFinished` runs, which works here because the commit itself
            // refunded the session's open-lane credits (`recordCommittedSchedule` — a newborn run
            // is not the state the pre-commit pass drove). Mid-sync, the guard defers to the
            // coming edge, whose own drive now also holds a fresh credit. The tick loop stays the
            // belt for everything after.
            // Field 2026-08-06: the scheduled-plan lane now front-runs this same drive UNDER THE
            // CONFIRM LOADER, awaited, before `.transferPlan`'s `.delegate(.confirmed)` ever fires
            // (`MigrationTransferPlan`'s `.scheduleCommitted` — see its doc). So for that lane this
            // call is now an idempotent backstop, not the first driver — it still fires here every
            // time, on the same phase token and the same at-tip guard, and the tick-loop spawn
            // above still matters regardless of which lane fired it. NOT a backstop for a back-tap
            // during the drive wait, though: that pops the path element before `.delegate(.confirmed)`
            // can ever fire, so this case never matches on that path (TCA's `forEach` cancels the
            // in-flight `.scheduleCommitted` effect on the pop, so its trailing
            // `send(.scheduleSigned)` is a no-op) — that path is recovered by `flowFinished` below
            // (fires when the coordinator closes) and, failing that, the next app-open's re-arm in
            // `RootInitialization`, not by this case. The drive itself keeps running regardless —
            // it's unstructured specifically so the pop's cancellation can't reach it (see
            // `.scheduleCommitted`'s own doc). This case remains the ONLY drive for the
            // `.reviewTransfer` lane below, which gained no loader-side drive of its own.
            case .migrationCoordFlow(.path(.element(id: _, action: .transferPlan(.delegate(.confirmed))))),
                .migrationCoordFlow(.path(.element(id: _, action: .reviewTransfer(.delegate(.confirmed))))):
                return .merge(
                    migrationTickLoopEffect(state: state),
                    .run { [migrationManager, sdkSynchronizer] _ in
                        guard case .upToDate = sdkSynchronizer.latestState().syncStatus else { return }
                        await migrationManager.advance(.afterSync)
                    }
                )

            case .migrationCoordFlow(.flowFinished):
                state.path = nil
                // Audit 2026-08-03 (#15): the flow-presented guard's disarm — see the coordinator
                // `.onAppear` arm for the plan-cache race this pair closes.
                migrationManager.setMigrationFlowPresented(state.selectedWalletAccount?.id, false)
                // (The Send-now fence clear that lived here was REMOVED 2026-08-07 with the
                // Send-now lanes.)
                // A finished run has usually changed what there is to migrate — after the manual
                // lane, to nothing at all. Poke the banner to re-derive rather than waiting for a
                // sync transition to do it: on an already-`.upToDate` wallet no transition is
                // coming, which is exactly how a completed manual migration was left advertising
                // itself on the Home screen (field-caught 2026-07-29). Harmless when nothing
                // changed — the re-read returns the same variant and re-renders in place.
                //
                // MOB-1466: the flow that just closed may have COMMITTED a scheduled run mid-session,
                // and the tick loop only spawns at app-open — re-spawn it here too (idempotent,
                // self-guarding: the off switch, activation, and scheduled-candidate checks all live
                // inside the effect itself).
                //
                // And drive the DRIVER once at `.afterSync` when the wallet is already at the tip
                // (field-caught 2026-08-02, the confirm-after-edge wedge): a run committed after
                // this app-open's one `.upToDate` edge has missed the only phase that may prove
                // (`.prove` defers as `.wrongPhase` at `.beforeSync` and `.tick` alike), so its
                // first preparation sat unproven until the next app-open — "no transition is
                // coming" applies to the driver exactly as it does to the banner above. Guarded on
                // the LIVE status at execution time: mid-sync, the coming edge owns this call
                // (`didJustReachUpToDate` in `synchronizerStateChanged`), and driving early would
                // sweep against a stale tip. The driver is single-flight and self-guarding, so a
                // flow that committed nothing degrades to one cheap `noRun` read.
                return .merge(
                    .send(.home(.smartBanner(.migrationReevaluationRequested))),
                    migrationTickLoopEffect(state: state),
                    .run { [migrationManager, sdkSynchronizer] _ in
                        guard case .upToDate = sdkSynchronizer.latestState().syncStatus else { return }
                        await migrationManager.advance(.afterSync)
                    },
                    // Audit 2026-08-03 (#6): a flow that closed WITHOUT committing leaves its
                    // Tor-sheet snapshot provisional — and nothing ever cleared it, pinning
                    // auto-server selection and arming ServerSetup's privacy warning for a run
                    // that does not exist. The cleaner no-ops when the flow committed (the
                    // confirm converted the snapshot) and when there is nothing to clear.
                    .run { [migrationManager, accountUUID = state.selectedWalletAccount?.id] _ in
                        migrationManager.clearProvisionalNetworkSnapshot(accountUUID)
                    }
                )

            case .home(.torSetupTapped(let settingsView)):
                state.torSetupState = .initial
                state.torSetupState.isSettingsView = settingsView
                state.path = .torSetup
                return .none

            case .home(.smartBanner(.walletBackupTapped)):
                state.walletBackupCoordFlowState = .initial
                state.path = .walletBackup
                return .none
                
            case .home(.smartBanner(.serverSwitchRequested)):
                state.serverSetupState = .initial
                state.path = .serverSwitch
                return .none

                // MARK: - Ironwood Announcement

            case .ironwoodAnnouncement(.continueTapped):
                // The feature reducer already wrote the keychain acknowledgment flag; Root owns
                // navigation. Routing through `.updateDestination` (rather than assigning
                // `destinationState.destination` directly) is what lets a pending
                // stale-wallet-healed notice be delivered on this arrival at Home — see
                // `presentStaleWalletHealedAlertEffect` (RootStore.swift).
                return .send(.destination(.updateDestination(.home)))

            case .settings(.path(.element(id: _, action: .advancedSettings(.debugResetIronwoodAnnouncementTapped)))):
                // The debug row itself writes the keychain flag; without also clearing this
                // session's latch here, the reset wouldn't take effect until the app is
                // relaunched (the latch is what keeps the already-acknowledged path from
                // re-reading the keychain more than once per session). No `#if` needed: this
                // action is unreachable in a production build because the row that sends it is
                // compiled out (see AdvancedSettingsView).
                state.ironwoodAnnouncementResolved = false
                return .none

            case .settings(.path(.element(id: _, action: .migrationRestart(.delegate(.restarted))))):
                // MOB-1466 (Lukas, 2026-08-07): "once I finish restart migration, we need to reset
                // smart banner.. because it renders me 2 of 11 transactions done.. aka previous
                // state."
                //
                // The restart cancels the run in the ENGINE and reconciles, but the banner holds
                // its own answer: the last variant, the dwell queue behind it, any held answer
                // waiting on a verdict, and the `.idle` termination latch that is deliberately
                // sticky for the rest of the session. None of that is invalidated by an engine
                // state change on its own — the banner would keep counting a run that no longer
                // exists until something re-asked.
                //
                // So: kill the cached answer and re-run the priority ladder from the top. The
                // ladder re-asks the manager, which now sees no run and Orchard funds still to
                // move, and hands back `.required` — the user is offered the migration again,
                // which is the whole point of restarting.
                //
                // Sent from `Root` rather than from Settings because the banner lives under Home;
                // Settings has no path to it.
                return .send(.home(.smartBanner(.migrationRunReset)))

                // MARK: - Keystone

            case .sendCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.rejectTapped)))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.rejectTapped)))):
                state.path = nil
                return .none

            case .signWithKeystoneCoordFlow(.sendConfirmation(.rejectTapped)):
                // The standalone Keystone sign flow (shield-from-Keystone) is presented via the
                // `signWithKeystoneCoordFlowBinding` binding, not `path`, so the shared `path = nil` above
                // was a no-op for it: on iOS only the popover's interactive swipe dismissed it, and the
                // macOS full-window takeover would have no way out at all. Flip the binding so Reject
                // actually closes the flow on both platforms.
                state.signWithKeystoneCoordFlowBinding = false
                // Clear the processor's replayed `.proposal` (CurrentValueSubject) so a later
                // SmartBanner re-subscription can't receive the stale state and instantly close a
                // freshly-opened shield banner (field bug: banner dismissed on every account switch
                // AFTER one rejected Keystone shield).
                shieldingProcessor.reset()
                return .none

            case .signWithKeystoneRequested:
                state.signWithKeystoneCoordFlowBinding = true
                return .send(.signWithKeystoneCoordFlow(.sendConfirmation(.resolvePCZT)))
                
                // MARK: - Request Zec

            case .requestZecCoordFlow(.path(.element(id: _, action: .requestZecSummary(.cancelRequestTapped)))):
                state.path = nil
                return .none

                // MARK: - Reset Zashi

            case .settings(.path(.element(id: _, action: .disconnectHWWallet(.disconnectFinished)))):
                state.path = nil
                state.$selectedWalletAccount.withLock { $0 = nil }
                return .run { send in
                    // [B4-17] The disconnected account's SmartBanners (e.g. the Keystone shielding
                    // offer) must not survive it — macOS's always-visible banner host never
                    // re-evaluates on its own (the split-view stale-gate class). Close-and-cleanup
                    // re-runs the priority chain against the remaining accounts; fires AFTER the
                    // deletion completed, so the re-evaluation can't resurrect the stale offer.
                    await send(.home(.smartBanner(.closeAndCleanupBanner)))
                    let walletAccounts = try await sdkSynchronizer.walletAccounts()
                    await send(.initialization(.loadedWalletAccounts(walletAccounts)))
                    await send(.fetchTransactionsForTheSelectedAccount)
                    await send(.home(.walletBalances(.updateBalances)))
                    /// The TCA spins an async Task in `fetchTransactionsForTheSelectedAccount` and it's needed to run
                    /// before next code here therefore Task is asleep for 0.01s. The purpose is also to not block the main thread
                    /// so await of mainQueue is not used.
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await send(.resolveMetadataEncryptionKeys)
                    await send(.loadUserMetadata)
                }

            case .settings(.path(.element(id: _, action: .resetZashi(.deleteTapped(let areMetadataPreserved))))):
                return .send(.initialization(.resetZashiRequest(areMetadataPreserved)))

                // MARK: - Restore Wallet Coord Flow from Onboarding

            case .onboarding(.seedNotRelevantToExistingDB):
                // Preventive guard ([#1024]): the entered seed doesn't match the wallet DB already on disk.
                // Funnel through the single mismatch sink (`seedValidationResult(false)` → `differentSeed()`:
                // "Start over" wipes via resetZashi, "Try again" dismisses) — before the seed is ever written
                // to the keychain.
                return .send(.initialization(.seedValidationResult(false)))

            case .onboarding(.path(.element(id: _, action: .restoreInfo(.gotItTapped)))):
                var leavesScreenOpen = false
                for element in state.onboardingState.path {
                    if case .restoreInfo(let restoreInfoState) = element {
                        leavesScreenOpen = restoreInfoState.isAcknowledged
                    }
                }
                userDefaults.setValue(leavesScreenOpen, Constants.udLeavesScreenOpen)
                state.isRestoringWallet = true
                userDefaults.setValue(true, Constants.udIsRestoringWallet)
                state.$walletStatus.withLock { $0 = .restoring }
                return .concatenate(
                    .send(.initialization(.initializeSDK(.restoreWallet))),
                    .send(.initialization(.checkBackupPhraseValidation)),
                    .send(.batteryStateChanged)
                )

                // MARK: - Scan Coord Flow
                
            // MOB-1581: a terminal send outcome that stored a transaction must refresh the shared
            // transactions list immediately — an idle wallet emits no sync event until the next block
            // (~75s), and not every flow exit passes a refetching Close arm (the View Transaction →
            // detail-close exit did not). `sendFailed(_, false)` stored nothing, so it stays silent.
            case .scanCoordFlow(.path(.element(id: _, action: .sendConfirmation(.sendDone)))),
                    .scanCoordFlow(.path(.element(id: _, action: .sendConfirmation(.sendPartial)))),
                    .scanCoordFlow(.path(.element(id: _, action: .sendConfirmation(.sendFailed(_, true))))),
                    .scanCoordFlow(.path(.element(id: _, action: .requestZecConfirmation(.sendDone)))),
                    .scanCoordFlow(.path(.element(id: _, action: .requestZecConfirmation(.sendPartial)))),
                    .scanCoordFlow(.path(.element(id: _, action: .requestZecConfirmation(.sendFailed(_, true))))),
                    .scanCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendDone)))),
                    .scanCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendPartial)))),
                    .scanCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendFailed(_, true))))):
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .scanCoordFlow(.scan(.cancelTapped)):
                state.path = nil
                return .none
                
            case .scanCoordFlow(.path(.element(id: _, action: .sendForm(.dismissRequired)))):
                state.path = nil
                return .none

            // MOB-1581: this exit previously refreshed nothing — see the send-terminal arms above.
            case .scanCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.path = nil
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .scanCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .scanCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .scanCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.path = nil
                state.macRedirectToActivityAfterClose = true
                return .send(.fetchTransactionsForTheSelectedAccount)

                // MARK: - Self

            case .sendAgainRequested(let transactionState):
                state.sendCoordFlowState = .initial
                state.path = .sendCoordFlow
                state.sendCoordFlowState.sendFormState.memoState.text = state.transactionMemos[transactionState.id]?.first ?? ""
                return .merge(
                    .send(.sendCoordFlow(.sendForm(.zecAmountUpdated(transactionState.amountWithoutFee.decimalString().redacted)))),
                    .send(.sendCoordFlow(.sendForm(.addressUpdated(transactionState.address.redacted))))
                )
                
            case .deeplinkWarning(.rescanInZashi):
                state = .initial
                state.splashAppeared = true
                return .merge(
                    .send(.destination(.updateDestination(.home))),
                    .send(.home(.scanTapped))
                )

                // MARK: - Send Coord Flow

            // MOB-1581: a terminal send outcome that stored a transaction must refresh the shared
            // transactions list immediately — an idle wallet emits no sync event until the next block
            // (~75s), and not every flow exit passes a refetching Close arm (the View Transaction →
            // detail-close exit did not). `sendFailed(_, false)` stored nothing, so it stays silent.
            case .sendCoordFlow(.path(.element(id: _, action: .sendConfirmation(.sendDone)))),
                    .sendCoordFlow(.path(.element(id: _, action: .sendConfirmation(.sendPartial)))),
                    .sendCoordFlow(.path(.element(id: _, action: .sendConfirmation(.sendFailed(_, true))))),
                    .sendCoordFlow(.path(.element(id: _, action: .requestZecConfirmation(.sendDone)))),
                    .sendCoordFlow(.path(.element(id: _, action: .requestZecConfirmation(.sendPartial)))),
                    .sendCoordFlow(.path(.element(id: _, action: .requestZecConfirmation(.sendFailed(_, true))))),
                    .sendCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendDone)))),
                    .sendCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendPartial)))),
                    .sendCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendFailed(_, true))))):
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .sendCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .sendCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .sendCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.path = nil
                state.macRedirectToActivityAfterClose = true
                return .send(.fetchTransactionsForTheSelectedAccount)

            // MOB-1581: this exit previously refreshed nothing — see the send-terminal arms above.
            case .sendCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.path = nil
                return .send(.fetchTransactionsForTheSelectedAccount)

                // MARK: - Sign with Keystone Coord Flow

            // MOB-1581: a terminal send outcome that stored a transaction must refresh the shared
            // transactions list immediately — an idle wallet emits no sync event until the next block
            // (~75s), and not every flow exit passes a refetching Close arm (the View Transaction →
            // detail-close exit did not). `sendFailed(_, false)` stored nothing, so it stays silent.
            case .signWithKeystoneCoordFlow(.sendConfirmation(.sendDone)),
                    .signWithKeystoneCoordFlow(.sendConfirmation(.sendPartial)),
                    .signWithKeystoneCoordFlow(.sendConfirmation(.sendFailed(_, true))):
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .signWithKeystoneCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.signWithKeystoneCoordFlowBinding = false
                state.macRedirectToActivityAfterClose = true
                // See the reject case above — clear the processor's replayed terminal state.
                shieldingProcessor.reset()
                // [class: split-view stale gate — B4-10/B4-17 recipe] macOS Home never re-fires
                // onAppear (always-visible split view), so the "Shield funds" banner survives the
                // return from this full-window sign flow. Poke the re-evaluation: after a
                // successful shield it drops; after a failure it legitimately re-opens.
                return .merge(
                    .send(.fetchTransactionsForTheSelectedAccount),
                    .send(.home(.smartBanner(.closeAndCleanupBanner)))
                )

            // MOB-1581: this exit previously refreshed nothing — see the send-terminal arms above.
            case .signWithKeystoneCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.signWithKeystoneCoordFlowBinding = false
                #if os(macOS)
                shieldingProcessor.reset()
                // Same stale-gate poke — this close also lands back on Activity post-shield. macOS-only:
                // works around macOS's always-visible split view never re-firing onAppear (the
                // split-view stale-gate class); iOS's Home does re-fire onAppear on its own, and
                // production main's byte-faithful behavior here (see
                // RootSendCompletionRefreshTests.detailCloseInKeystoneSignFlowRefetchesTransactions)
                // is exactly the plain fetch below.
                return .merge(
                    .send(.fetchTransactionsForTheSelectedAccount),
                    .send(.home(.smartBanner(.closeAndCleanupBanner)))
                )
                #else
                return .send(.fetchTransactionsForTheSelectedAccount)
                #endif

                // MARK: - Tor Setup
                
            case .torSetup(.disableTapped), .torSetup(.enableTapped):
                state.path = nil
                return .send(.home(.smartBanner(.closeAndCleanupBanner)))

                // MARK: - Swap and Pay Coord Flow

            // MOB-1581: a terminal send outcome that stored a transaction must refresh the shared
            // transactions list immediately — an idle wallet emits no sync event until the next block
            // (~75s), and not every flow exit passes a refetching Close arm (the View Transaction →
            // detail-close exit did not). `sendFailed(_, false)` stored nothing, so it stays silent.
            case .swapAndPayCoordFlow(.sendDone),
                    .swapAndPayCoordFlow(.sendPartial),
                    .swapAndPayCoordFlow(.sendFailed(_, true)),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendDone)))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendPartial)))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .confirmWithKeystone(.sendFailed(_, true))))):
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .swapAndPayCoordFlow(.path(.element(id: _, action: .swapToZecSummary(.sentTheFundsButtonTapped)))):
                state.path = nil
                return .send(.fetchTransactionsForTheSelectedAccount)

            case .swapAndPayCoordFlow(.customBackRequired):
                state.path = nil
                return .none

            case .swapAndPayCoordFlow(.swapAndPay(.customBackRequired)):
                state.path = nil
                return .none

            case .swapAndPayCoordFlow(.path(.element(id: _, action: .swapAndPayOptInForced(.customBackRequired)))):
                state.path = nil
                return .none

            case .swapAndPayCoordFlow(.swapAndPay(.cancelPaymentTapped)):
                state.path = nil
                return .none
                
            case .swapAndPayCoordFlow(.path(.element(id: _, action: .sendResultSuccess(.closeTapped)))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .sendResultFailure(.closeTapped)))),
                    .swapAndPayCoordFlow(.path(.element(id: _, action: .sendResultPending(.closeTapped)))):
                state.path = nil
                state.macRedirectToActivityAfterClose = true
                return .send(.fetchTransactionsForTheSelectedAccount)

            // MOB-1581: this exit previously refreshed nothing — see the send-terminal arms above.
            case .swapAndPayCoordFlow(.path(.element(id: _, action: .transactionDetails(.closeDetailTapped)))):
                state.path = nil
                // [B4-19] This detail is reached via "Check status" on a Result screen; closing it
                // ends the whole Swap/Pay flow, so land on Activity — where the transaction lives —
                // instead of the stale Swap/Pay form. Same redirect the Result closes use.
                state.macRedirectToActivityAfterClose = true
                return .send(.fetchTransactionsForTheSelectedAccount)

                // MARK: - Transactions Coord Flow
                
            case .transactionsCoordFlow(.transactionDetails(.closeDetailTapped)):
                state.path = nil
                return .none

            case .transactionsCoordFlow(.transactionsManager(.dismissRequired)):
                state.path = nil
                return .none

            case .transactionsCoordFlow(.transactionDetails(.sendAgainTapped)):
                state.path = nil
                let transactionState = state.transactionsCoordFlowState.transactionDetailsState.transaction
                return .run { send in
                    try? await mainQueue.sleep(for: .seconds(0.8))
                    await send(.sendAgainRequested(transactionState))
                }
                
            case .transactionsCoordFlow(.path(.element(id: _, action: .transactionDetails(.sendAgainTapped)))):
                for element in state.transactionsCoordFlowState.path {
                    if case .transactionDetails(let transactionDetailsState) = element {
                        state.path = nil
                        return .run { send in
                            try? await mainQueue.sleep(for: .seconds(0.8))
                            await send(.sendAgainRequested(transactionDetailsState.transaction))
                        }
                    }
                }
                return .none

                // MARK: - Wallet Backup Coord Flow

            case .walletBackupCoordFlow(.path(.element(id: _, action: .phrase(.remindMeLaterTapped)))):
                state.path = nil
                return .send(.home(.smartBanner(.remindMeLaterTapped(.priority6))))

            case .walletBackupCoordFlow(.path(.element(id: _, action: .phrase(.seedSavedTapped)))):
                state.path = nil
                do {
                    try walletStorage.markUserPassedPhraseBackupTest(true)
                } catch {
                    state.alert = AlertState.cantStoreThatUserPassedPhraseBackupTest(error.toZcashError())
                }
                return .merge(
                    .send(.home(.smartBanner(.closeAndCleanupBanner))),
                    .send(.home(.smartBanner(.closeSheetTapped)))
                )

            default: return .none
            }
        }
    }

    /// The account-switch reactions shared by the manual switcher (`.home(.walletAccountTapped)`)
    /// and every Keystone-connect auto-select completion. `AddHWWalletStore`'s
    /// `.loadedWalletAccounts` writes `state.selectedWalletAccount` directly, with no Root-visible
    /// "switch" action of its own — `.accountImportSucceeded`, sent immediately after in the same
    /// effect, is the earliest point Root can react. Both paths flip the selected account out from
    /// under whatever transaction/balance fetches are in flight for the PREVIOUS account, so both
    /// must invalidate the now-stale transaction lists — Home's mini list AND the "See All"
    /// screen's (previously only Home's was reset here) — and kick off fresh transaction/balance
    /// reads for the NEW one. Callers compose their own additional reactions on top
    /// (contacts/metadata reload, Flexa cancellation) — this covers only the subset common to
    /// every switch path.
    ///
    /// `autoUpdateSwapCandidates.removeAll()` folded in here too — every OTHER caller already
    /// cleared it inline immediately before invoking this helper (dropping the previous account's
    /// swap candidates on any switch is the existing, uniform behavior; nothing relies on them
    /// surviving one), so this is behavior-preserving there and closes the one arm
    /// (`.keystoneDeviceReady(.accountImportSucceeded)`) that previously omitted it.
    private func accountSwitchedEffect(state: inout Root.State) -> Effect<Root.Action> {
        state.autoUpdateSwapCandidates.removeAll()
        state.homeState.transactionListState.isInvalidated = true
        state.transactionsCoordFlowState.transactionsManagerState.isInvalidated = true
        return .merge(
            .send(.home(.smartBanner(.walletAccountChanged))),
            .send(.home(.walletBalances(.updateBalances))),
            .concatenate(
                .cancel(id: state.CancelTransactionsFetchId),
                .send(.fetchTransactionsForTheSelectedAccount)
            )
        )
    }
}
