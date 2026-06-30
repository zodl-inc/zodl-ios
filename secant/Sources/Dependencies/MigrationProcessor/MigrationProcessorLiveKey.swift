//
//  MigrationProcessorLiveKey.swift
//  ZODL
//
// TODO: [#MOB-IRONWOOD] `refresh()` calls the real `planOrchardDenominationSplit` SDK method
//   (zcash-swift-wallet-sdk PR #1791). Methods still marked "SDK STUB" depend on the rest of the
//   migration transaction-building surface, which is blocked on unstable Ironwood/nu6.3 crate APIs.
//

import Foundation
import ComposableArchitecture
@preconcurrency import Combine
@preconcurrency import ZcashLightClientKit

extension MigrationProcessorClient: DependencyKey {
    static let liveValue: MigrationProcessorClient = Self.live()

    static func live() -> Self {
        let impl = MigrationProcessorImpl()

        return MigrationProcessorClient(
            observe: { impl.observe() },
            refresh: { impl.refresh() },
            confirmNoteSplit: { proposal in impl.confirmNoteSplit(proposal: proposal) },
            confirmSchedule: { schedule in impl.confirmSchedule(schedule: schedule) },
            executeNextTransfer: { useTor in impl.executeNextTransfer(useTor: useTor) },
            restart: { impl.restart() }
        )
    }
}

// Placeholder fee/threshold constants pending Core team confirmation (see open security
// questions in the migration design doc — anchor height window, denomination economics).
private enum DenominationPlanDefaults {
    static let prepFeeZatoshi: Int64 = 10_000
    static let migrationFeeZatoshi: Int64 = 10_000
    static let minimumOutputZatoshi: Int64 = 50_000
}

// `@Dependency` property wrappers and the Combine subject are thread-safe.
private final class MigrationProcessorImpl: @unchecked Sendable {
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment
    @Dependency(\.transactionGuard) var transactionGuard

    @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

    let subject = CurrentValueSubject<MigrationProcessorClient.Phase, Never>(.unknown)

    // Non-reentrant guard: mirrors the transactionGuard pattern already used for shielding.
    // executeNextTransfer must never overlap itself across two concurrent app-open callbacks.
    private var isExecuting = false

    func observe() -> AnyPublisher<MigrationProcessorClient.Phase, Never> {
        subject.eraseToAnyPublisher()
    }

    func refresh() {
        Task { [subject, sdkSynchronizer] in
            guard let account = selectedWalletAccount else {
                subject.send(.notStarted)
                return
            }

            do {
                let orchardSpendable = try await sdkSynchronizer.getAccountsBalances()[account.id]?.orchardBalance.spendableValue ?? .zero

                guard orchardSpendable.amount > 0 else {
                    subject.send(.notStarted)
                    return
                }

                let plan = try await sdkSynchronizer.planOrchardDenominationSplit(
                    orchardSpendable.amount,
                    DenominationPlanDefaults.prepFeeZatoshi,
                    DenominationPlanDefaults.migrationFeeZatoshi,
                    DenominationPlanDefaults.minimumOutputZatoshi
                )

                guard !plan.migrationOutputs.isEmpty else {
                    subject.send(.notStarted)
                    return
                }

                subject.send(
                    .awaitingNoteSplitConfirm(
                        MigrationProcessorClient.NoteSplitProposalModel(
                            outputNotes: plan.migrationOutputs,
                            feeSatoshi: plan.prepFeeZatoshi
                        )
                    )
                )
            } catch {
                subject.send(.failed(error.toZcashError()))
            }
        }
    }

    func confirmNoteSplit(proposal: MigrationProcessorClient.NoteSplitProposalModel) {
        guard let account = selectedWalletAccount else {
            subject.send(.failed("confirmNoteSplit: no account".toZcashError()))
            return
        }

        Task { [subject, sdkSynchronizer, transactionGuard] in
            do {
                if account.vendor == .keystone {
                    // TODO: [#MOB-IRONWOOD] SDK STUB — build PCZT from note-split proposal
                    // and route through existing KeystoneSigningView. For now fall through to error.
                    throw "confirmNoteSplit: Keystone note-split not yet wired to SDK".toZcashError()
                }

                // TODO: [#MOB-IRONWOOD] SDK STUB — replace with:
                //   let result = try await sdkSynchronizer.orchardMigration.submitNoteSplit(sdkProposal)
                //   where sdkProposal is built from `proposal` fields.
                subject.send(.awaitingSplitConfirmation)

                // SECURITY: spending key must be zeroed after submit — implement when SDK is wired.
            } catch {
                subject.send(.failed(error.toZcashError()))
            }
        }
    }

    func confirmSchedule(schedule: MigrationProcessorClient.MigrationScheduleModel) {
        guard let account = selectedWalletAccount else {
            subject.send(.failed("confirmSchedule: no account".toZcashError()))
            return
        }

        if account.vendor == .keystone {
            // Keystone path: produce PCZT and hand off to SignWithKeystoneCoordFlow.
            // The Root reducer observes `.proposal` state and routes to the existing flow.
            Task { [subject] in
                // TODO: [#MOB-IRONWOOD] SDK STUB — replace with:
                //   let pczt = try await sdkSynchronizer.orchardMigration.buildMigrationPczt(schedule)
                //   subject.send(.proposal(pczt))
                subject.send(.failed("confirmSchedule: Keystone path not yet wired to SDK".toZcashError()))
            }
            return
        }

        Task { [subject, derivationTool, mnemonic, walletStorage, zcashSDKEnvironment, transactionGuard] in
            guard let zip32AccountIndex = account.zip32AccountIndex else {
                subject.send(.failed("confirmSchedule: zip32AccountIndex missing".toZcashError()))
                return
            }

            do {
                let storedWallet = try walletStorage.exportWallet()
                let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                let spendingKey = try derivationTool.deriveSpendingKey(
                    seedBytes, zip32AccountIndex, zcashSDKEnvironment.network().networkType
                )

                // TODO: [#MOB-IRONWOOD] SDK STUB — replace with:
                //   try await sdkSynchronizer.orchardMigration.signAndStoreMigrationSchedule(sdkSchedule, spendingKey)

                // SECURITY: zero key bytes immediately after the SDK call.
                // var keyBytes = spendingKey.bytes; keyBytes.resetBytes(in: 0..<keyBytes.count)

                let initialProgress = MigrationProcessorClient.MigrationProgressModel(
                    completedTransfers: 0,
                    totalTransfers: schedule.transfers.count,
                    remainingOrchardZatoshi: schedule.transfers.reduce(0) { $0 + $1.amountZatoshi },
                    nextTransferReadyAtHeight: schedule.transfers.first?.nextExecutableAfterHeight
                )
                subject.send(.inProgress(initialProgress))
            } catch {
                subject.send(.failed(error.toZcashError()))
            }
        }
    }

    func executeNextTransfer(useTor: Bool) {
        guard !isExecuting else { return }
        isExecuting = true

        Task { [subject, sdkSynchronizer, walletStorage, zcashSDKEnvironment, transactionGuard] in
            defer { isExecuting = false }

            guard let account = selectedWalletAccount else {
                subject.send(.failed("executeNextTransfer: no account".toZcashError()))
                return
            }

            do {
                // SECURITY CHECKLIST (verify each when wiring SDK):
                // 1. Call isSyncRequiredBeforeNextTransfer() — if true, trigger sync and skip execute.
                // 2. Wrap broadcast inside transactionGuard to prevent overlap with regular sends.
                // 3. Pass NetworkPrivacyOptions(useTor: useTor) to executeNextPendingTransfer().
                // 4. Handle TransferResult.InvalidNote → .requiresAttention(.invalidTransfer).
                // 5. Handle TransferResult.Expired → .requiresAttention(.transferExpired).
                // 6. Zero spending key bytes immediately after SDK call.

                // TODO: [#MOB-IRONWOOD] SDK STUB — replace with:
                //   let syncRequired = sdkSynchronizer.orchardMigration.isSyncRequiredBeforeNextTransfer()
                //   if syncRequired { subject.send(.requiresAttention(.syncRequired)); return }
                //
                //   let options = NetworkPrivacyOptions(useTor: useTor)
                //   let result = try await transactionGuard.guarded {
                //       try await sdkSynchronizer.orchardMigration.executeNextPendingTransfer(options)
                //   }
                //
                //   switch result {
                //   case .success: refresh()       // re-fetch progress
                //   case .networkError: break      // leave in .inProgress, retry next open
                //   case .invalidNote: subject.send(.requiresAttention(.invalidTransfer))
                //   case .expired: subject.send(.requiresAttention(.transferExpired))
                //   case nil: break                // no transfer due yet at current height
                //   }
                break
            }
        }
    }

    func restart() {
        Task { [subject] in
            // TODO: [#MOB-IRONWOOD] SDK STUB — replace with:
            //   let newSchedule = try await sdkSynchronizer.orchardMigration.restartCurrentMigrationStep()
            //   subject.send(.proposalReview(map(newSchedule)))
            subject.send(.failed("restart: not yet wired to SDK".toZcashError()))
        }
    }
}
