//
//  TaxExporterLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-13.
//

import Foundation
import ComposableArchitecture
#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import ZcashLightClientKit
@preconcurrency import Combine

extension ShieldingProcessorClient: DependencyKey {
    static let liveValue: ShieldingProcessorClient = Self.live()

    static func live() -> Self {
        let impl = ShieldingProcessorImpl()

        return ShieldingProcessorClient(
            observe: { impl.observe() },
            shieldFunds: { impl.shieldFunds() },
            reset: { impl.reset() }
        )
    }
}

// TCA's `@Dependency` and `@Shared` property wrappers synthesize `var` storage but are themselves
// thread-safe (task-local dependency lookup / shared-state machinery). The Combine `subject` is
// reference-counted Sendable storage.
private final class ShieldingProcessorImpl: @unchecked Sendable {
    @Dependency(\.derivationTool) var derivationTool
    @Dependency(\.mnemonic) var mnemonic
    @Dependency(\.sdkSynchronizer) var sdkSynchronizer
    @Dependency(\.walletStorage) var walletStorage
    @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

    @Shared(.inMemory(.selectedWalletAccount)) var selectedWalletAccount: WalletAccount? = nil

    let subject = CurrentValueSubject<ShieldingProcessorClient.State, Never>(.unknown)

    func observe() -> AnyPublisher<ShieldingProcessorClient.State, Never> {
        subject.eraseToAnyPublisher()
    }

    // See `ShieldingProcessorClient.reset` — clears the replayed terminal state on flow teardown.
    func reset() {
        subject.send(.unknown)
    }

    func shieldFunds() {
        subject.send(.requested)

        guard let account = selectedWalletAccount, let zip32AccountIndex = account.zip32AccountIndex else {
            subject.send(.failed("shieldFunds failed, no account available".toZcashError()))
            return
        }

        if account.vendor == .keystone {
            Task { [subject, sdkSynchronizer, zcashSDKEnvironment] in
                do {
                    let proposal = try await sdkSynchronizer.proposeShielding(account.id, zcashSDKEnvironment.shieldingThreshold(), .empty, nil)

                    guard let proposal else { throw "shieldFunds with Keystone: nil proposal" }
                    subject.send(.proposal(proposal))
                } catch {
                    subject.send(.failed(error.toZcashError()))
                }
            }
        } else {
            Task { [subject, derivationTool, mnemonic, sdkSynchronizer, walletStorage, zcashSDKEnvironment] in
                do {
                    let storedWallet = try await walletStorage.exportWallet(nil)
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                    let spendingKey = try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, zcashSDKEnvironment.network().networkType)

                    let proposal = try await sdkSynchronizer.proposeShielding(account.id, zcashSDKEnvironment.shieldingThreshold(), .empty, nil)

                    guard let proposal else { throw "shieldFunds nil proposal" }

                    let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal, spendingKey)

                    // Shielding surfaces outcomes through a simpler state machine (.grpc / .failed /
                    // .succeeded) with no pending screen, so `.grpcFailure`'s `reason` (e.g. timeout) is
                    // intentionally not differentiated here — the generic `.grpc` state already means
                    // "transport failure, may still settle". Send/Swap distinguish the timeout copy only
                    // because they have a pending screen to show it on; this path does not.
                    switch result {
                    case .grpcFailure:
                        subject.send(.grpc)
                    case let .failure(_, code, description):
                        subject.send(.failed("shieldFunds failed \(code) \(description)".toZcashError()))
                    case let .partial(_, statuses):
                        subject.send(.failed("shieldFunds partially failed \(statuses.joined(separator: ", "))".toZcashError()))
                    case .success:
                        walletStorage.resetShieldingReminder(WalletAccount.Vendor.zcash.name())
                        subject.send(.succeeded)
                    }
                } catch {
                    subject.send(.failed(error.toZcashError()))
                }
            }
        }
    }
}
