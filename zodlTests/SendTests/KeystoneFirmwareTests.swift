//
//  KeystoneFirmwareTests.swift
//  zodlTests
//
//  Covers MOB-1510 (Keystone minimum-firmware check): the `Data.keystoneFirmwareVersion()`
//  byte-scan reader, `KeystoneFirmwareVersion`'s `Comparable` conformance, and the
//  `SendConfirmationStore` gate at `.foundPCZT` that blocks below-minimum/unstamped firmware
//  before `createTransactionFromPCZT` ever schedules.
//
//  `KeystoneFirmwareGateTests`: `SendConfirmation.State` carries `@Shared(.inMemory(...))`
//  process-global storage, so — mirroring `MultiServerSubmitPCZTRoutingTests`'s own reasoning —
//  the suite is serialized. The reader/Comparable suites are pure/dependency-free, so unserialized.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// MARK: - Data.keystoneFirmwareVersion() reader

@Suite struct KeystoneFirmwareVersionReaderTests {
    private static let key = Array("keystone:fw_version".utf8)

    @Test func stampedVersionAtMinimumParses() {
        var data = Data([0x00, 0x01])
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 3, 0, 0])

        #expect(data.keystoneFirmwareVersion() == KeystoneFirmwareVersion(major: 3, minor: 0, build: 0))
    }

    @Test func stampedVersionBelowMinimumParses() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 2, 4, 6])

        #expect(data.keystoneFirmwareVersion() == KeystoneFirmwareVersion(major: 2, minor: 4, build: 6))
    }

    @Test func missingKeyReturnsNil() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04])

        #expect(data.keystoneFirmwareVersion() == nil)
    }

    @Test func keyPresentButTruncatedValueReturnsNil() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 3, 0]) // only 2 of the 3 version bytes

        #expect(data.keystoneFirmwareVersion() == nil)
    }

    @Test func keyPresentWithWrongLengthPrefixReturnsNil() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x04, 3, 0, 0]) // wrong prefix, not postcard's 0x03

        #expect(data.keystoneFirmwareVersion() == nil)
    }

    @Test func multipleOccurrencesFirstValidOneWins() {
        var data = Data()
        // First occurrence: wrong length prefix, invalid.
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x05, 9, 9, 9])
        // Second occurrence: valid.
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 3, 1, 2])

        #expect(data.keystoneFirmwareVersion() == KeystoneFirmwareVersion(major: 3, minor: 1, build: 2))
    }

    @Test func versionBytesAtVeryEndOfDataParses() {
        var data = Data([0xFF])
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 4, 5, 6])

        #expect(data.count == 1 + Self.key.count + 4)
        #expect(data.keystoneFirmwareVersion() == KeystoneFirmwareVersion(major: 4, minor: 5, build: 6))
    }

    @Test func emptyDataReturnsNil() {
        #expect(Data().keystoneFirmwareVersion() == nil)
    }
}

// MARK: - KeystoneFirmwareVersion.Comparable

@Suite struct KeystoneFirmwareVersionComparableTests {
    @Test func lowerMajorIsBelowMinimum() {
        #expect(KeystoneFirmwareVersion(major: 2, minor: 9, build: 9) < KeystoneFirmwareVersion.minimumSupported)
    }

    @Test func minimumIsExactlyThreeZeroZero() {
        #expect(KeystoneFirmwareVersion.minimumSupported == KeystoneFirmwareVersion(major: 3, minor: 0, build: 0))
    }

    @Test func minimumIsNotBelowItself() {
        #expect(!(KeystoneFirmwareVersion.minimumSupported < KeystoneFirmwareVersion.minimumSupported))
    }

    @Test func higherBuildIsAboveMinimum() {
        #expect(KeystoneFirmwareVersion(major: 3, minor: 0, build: 1) > KeystoneFirmwareVersion.minimumSupported)
    }

    @Test func comparisonIsLexicographicOnMajorThenMinorThenBuild() {
        // A higher minor must not be shadowed by comparing major alone.
        #expect(KeystoneFirmwareVersion(major: 2, minor: 99, build: 99) < KeystoneFirmwareVersion(major: 3, minor: 0, build: 0))
        // A higher build must not be shadowed by comparing major/minor alone.
        #expect(KeystoneFirmwareVersion(major: 3, minor: 0, build: 0) < KeystoneFirmwareVersion(major: 3, minor: 0, build: 1))
    }
}

// MARK: - SendConfirmationStore gate

// `SendConfirmation.State` carries `@Shared(.inMemory(...))` process-global storage (address book
// contacts, feature flags, wallet accounts) — serialized to avoid cross-suite races on that
// storage, mirroring `MultiServerSubmitPCZTRoutingTests`'s own reasoning.
@Suite(.serialized) @MainActor struct KeystoneFirmwareGateTests {
    private func makeStore() -> TestStore<SendConfirmation.State, SendConfirmation.Action> {
        let initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )

        let store = TestStore(initialState: initialState) {
            SendConfirmation()
        }
        store.dependencies.mainQueue = .immediate
        // `KeystoneHandlerClient` has no `testValue` (only `liveValue`), so a `TestStore` requires
        // a full override rather than a partial-property mutation — the latter reads the current
        // (missing) test value first and fails before the override is ever applied.
        store.dependencies.keystoneHandler = .noOp
        return store
    }

    private func signedPczt(firmware: (major: Int, minor: Int, build: Int)?) -> Pczt {
        var data = Data()
        if let firmware {
            data.append(contentsOf: Array("keystone:fw_version".utf8))
            data.append(contentsOf: [0x03, UInt8(firmware.major), UInt8(firmware.minor), UInt8(firmware.build)])
        }
        return Pczt(data)
    }

    @Test func belowMinimumFirmwarePresentsUpdateScreenAndNeverSchedulesCreateTransaction() async {
        let store = makeStore()
        let pczt = signedPczt(firmware: (2, 4, 6))

        await store.send(.foundPCZT(pczt)) {
            $0.isKeystoneCodeFound = true
            $0.detectedKeystoneFirmware = KeystoneFirmwareVersion(major: 2, minor: 4, build: 6)
        }
        await store.receive(.keystoneFirmwareUpdateRequired)
        // No further action arrives: `createTransactionFromPCZT` is never scheduled. An exhaustive
        // `TestStore` fails on any unasserted action, so reaching `finish()` cleanly here IS the
        // "never schedules" assertion.
        await store.finish()

        #expect(store.state.pcztWithSigs == nil)
    }

    @Test func atMinimumFirmwareProceedsUnchanged() async {
        let store = makeStore()
        let pczt = signedPczt(firmware: (3, 0, 0))

        await store.send(.foundPCZT(pczt)) {
            $0.isKeystoneCodeFound = true
            $0.pcztWithSigs = pczt
        }
        // `createTransactionFromPCZT`'s own guard bails with no state change: `pcztWithProofs` was
        // never set, so this proves scheduling happened without needing to mock the synchronizer.
        await store.receive(.createTransactionFromPCZT)
        await store.finish()

        #expect(store.state.detectedKeystoneFirmware == nil)
    }

    @Test func unstampedFirmwarePresentsUpdateScreenWithNilDetectedVersion() async {
        let store = makeStore()
        let pczt = signedPczt(firmware: nil)

        await store.send(.foundPCZT(pczt)) {
            $0.isKeystoneCodeFound = true
        }
        await store.receive(.keystoneFirmwareUpdateRequired)
        await store.finish()

        #expect(store.state.detectedKeystoneFirmware == nil)
        #expect(store.state.pcztWithSigs == nil)
    }

    @Test func closeClearsStateForRescan() async {
        let store = makeStore()
        let pczt = signedPczt(firmware: (2, 4, 6))

        await store.send(.foundPCZT(pczt)) {
            $0.isKeystoneCodeFound = true
            $0.detectedKeystoneFirmware = KeystoneFirmwareVersion(major: 2, minor: 4, build: 6)
        }
        await store.receive(.keystoneFirmwareUpdateRequired)

        await store.send(.keystoneFirmwareUpdateCloseTapped) {
            $0.detectedKeystoneFirmware = nil
            $0.isKeystoneCodeFound = false
        }
        await store.finish()
    }
}
