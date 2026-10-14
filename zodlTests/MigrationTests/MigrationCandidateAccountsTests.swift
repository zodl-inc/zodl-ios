//
//  MigrationCandidateAccountsTests.swift
//  zodlTests
//
//  MOB-2020 Phase 1.2: `MigrationDerivations.candidateAccountUUIDs` must never hand a Ledger
//  account to the migration BG session tree or re-arm scheduler (`Root.migrationBackgroundSessionEffect`,
//  `MigrationBGSchedulerImpl.arm(margin:)`) — Ledger signing does not exist yet (Phase 3), so a
//  migration run proposed for one could never be submitted. Covers the exclusion alongside the
//  pre-existing selected-first, deduplicated ordering (MOB-1496 W5).
//

import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct MigrationCandidateAccountsTests {
    private static func account(idByte: UInt8, vendor: WalletAccount.Vendor) -> WalletAccount {
        let keySource: String?
        switch vendor {
        case .keystone: keySource = "keystone"
        case .ledger: keySource = "ledger"
        case .zcash: keySource = nil
        }
        return WalletAccount(
            Account(
                id: AccountUUID(id: [UInt8](repeating: idByte, count: 16)),
                name: "Test",
                keySource: keySource,
                seedFingerprint: nil,
                hdAccountIndex: vendor == .ledger ? nil : Zip32AccountIndex(0),
                ufvk: nil,
                uivk: nil
            )
        )
    }

    @Test func dropsLedgerAccountsFromTheCandidateList() {
        let zodl = Self.account(idByte: 0x01, vendor: .zcash)
        let keystone = Self.account(idByte: 0x02, vendor: .keystone)
        let ledger = Self.account(idByte: 0x03, vendor: .ledger)

        let candidates = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: zodl.id,
            walletAccounts: [zodl, keystone, ledger]
        )

        #expect(candidates == [zodl.id, keystone.id])
        #expect(!candidates.contains(ledger.id))
    }

    @Test func dropsTheSelectedAccountTooWhenItIsLedger() {
        let ledger = Self.account(idByte: 0x04, vendor: .ledger)
        let keystone = Self.account(idByte: 0x05, vendor: .keystone)

        let candidates = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: ledger.id,
            walletAccounts: [ledger, keystone]
        )

        #expect(candidates == [keystone.id])
    }

    @Test func selectedAccountIsFirstAndWalletAccountsFollowInStoredOrder() {
        let first = Self.account(idByte: 0x06, vendor: .zcash)
        let second = Self.account(idByte: 0x07, vendor: .keystone)
        let selected = Self.account(idByte: 0x08, vendor: .zcash)

        let candidates = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selected.id,
            walletAccounts: [first, second, selected]
        )

        #expect(candidates == [selected.id, first.id, second.id])
    }

    @Test func deduplicatesTheSelectedAccountAgainstWalletAccounts() {
        let selected = Self.account(idByte: 0x09, vendor: .zcash)
        let other = Self.account(idByte: 0x0A, vendor: .keystone)

        let candidates = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: selected.id,
            walletAccounts: [selected, other]
        )

        #expect(candidates == [selected.id, other.id])
        #expect(candidates.count == 2)
    }

    @Test func noSelectionFallsBackToWalletAccountsOrderAlone() {
        let a = Self.account(idByte: 0x0B, vendor: .zcash)
        let b = Self.account(idByte: 0x0C, vendor: .ledger)
        let c = Self.account(idByte: 0x0D, vendor: .keystone)

        let candidates = MigrationDerivations.candidateAccountUUIDs(
            selectedAccountUUID: nil,
            walletAccounts: [a, b, c]
        )

        #expect(candidates == [a.id, c.id])
    }
}
