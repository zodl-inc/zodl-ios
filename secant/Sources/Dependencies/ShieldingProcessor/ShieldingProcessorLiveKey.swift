//
//  TaxExporterLiveKey.swift
//  Zashi
//
//  Created by Lukáš Korba on 2025-02-13.
//

import Foundation
import ComposableArchitecture
import UIKit
@preconcurrency import Combine

extension ShieldingProcessorClient: DependencyKey {
    static let liveValue: ShieldingProcessorClient = Self.live()

    static func live() -> Self {
        let impl = ShieldingProcessorImpl()

        return ShieldingProcessorClient(
            observe: { impl.observe() },
            shieldFunds: { impl.shieldFunds() }
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

    func shieldFunds() {
        subject.send(.requested)

        guard let account = selectedWalletAccount, let zip32AccountIndex = account.zip32AccountIndex else {
            subject.sendTerminal(.failed("shieldFunds failed, no account available".toZcashError()))
            return
        }

        if account.vendor == .keystone {
            Task { [subject, sdkSynchronizer, zcashSDKEnvironment] in
                do {
                    let proposal = try await sdkSynchronizer.proposeShielding(account.id, zcashSDKEnvironment.shieldingThreshold(), .empty, nil)

                    guard let proposal else {
                        subject.sendTerminal(.nothingToShield)
                        return
                    }
                    subject.sendTerminal(.proposal(proposal))
                } catch {
                    subject.sendTerminal(.failed(error.toZcashError()))
                }
            }
        } else {
            Task { [subject, derivationTool, mnemonic, sdkSynchronizer, walletStorage, zcashSDKEnvironment] in
                do {
                    let proposal = try await sdkSynchronizer.proposeShielding(account.id, zcashSDKEnvironment.shieldingThreshold(), .empty, nil)

                    guard let proposal else {
                        subject.sendTerminal(.nothingToShield)
                        return
                    }

                    // Key material is derived only once there is something to shield — the
                    // nil-proposal answer above is free, the seed derivation is not, and the
                    // spending key should live no longer than needed.
                    let storedWallet = try walletStorage.exportWallet()
                    let seedBytes = try mnemonic.toSeed(storedWallet.seedPhrase.value())
                    let spendingKey = try derivationTool.deriveSpendingKey(seedBytes, zip32AccountIndex, zcashSDKEnvironment.network().networkType)

                    let result = try await sdkSynchronizer.createAndSubmitProposedTransactions(proposal, spendingKey)

                    // Shielding surfaces outcomes through a simpler state machine (.grpc / .failed /
                    // .succeeded) with no pending screen, so `.grpcFailure`'s `reason` (e.g. timeout) is
                    // intentionally not differentiated here — the generic `.grpc` state already means
                    // "transport failure, may still settle". Send/Swap distinguish the timeout copy only
                    // because they have a pending screen to show it on; this path does not.
                    switch result {
                    case .grpcFailure:
                        subject.sendTerminal(.grpc)
                    case let .failure(_, code, description):
                        subject.sendTerminal(.failed("shieldFunds failed \(code) \(description)".toZcashError()))
                    case let .partial(_, statuses):
                        subject.sendTerminal(.failed("shieldFunds partially failed \(statuses.joined(separator: ", "))".toZcashError()))
                    case .success:
                        walletStorage.resetShieldingReminder(WalletAccount.Vendor.zcash.name())
                        subject.sendTerminal(.succeeded)
                    }
                } catch {
                    subject.sendTerminal(.failed(error.toZcashError()))
                }
            }
        }
    }
}

private extension CurrentValueSubject where Output == ShieldingProcessorClient.State, Failure == Never {
    /// Terminal outcomes are one-shot events, but this is a `CurrentValueSubject`, which replays
    /// its latest value to every new subscriber. Left latched, a `.succeeded` / `.nothingToShield`
    /// / `.proposal` re-fires on each resubscribe (SmartBanner re-subscribes on every Home appear,
    /// Root on re-init) — retracting valid banners, re-popping alerts, or re-launching the
    /// Keystone signing flow. Follow every terminal send with `.unknown` so live subscribers see
    /// the outcome exactly once and future subscribers replay only the reset. `.requested` stays
    /// latched on purpose: a Balances sheet opened mid-shield needs the replay for its spinner.
    func sendTerminal(_ state: ShieldingProcessorClient.State) {
        send(state)
        send(.unknown)
    }
}
