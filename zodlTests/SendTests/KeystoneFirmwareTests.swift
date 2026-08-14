//
//  KeystoneFirmwareTests.swift
//  zodlTests
//
//  Covers MOB-1510 (Keystone minimum-firmware check): the `Data.keystoneFirmwareStamp()`
//  byte-scan reader, the raw-to-displayed normalization in `KeystoneDisplayFirmwareVersion.fromStamp`,
//  `Comparable`, and the `SendConfirmationStore` gate at `.foundPCZT` that blocks
//  below-minimum/unstamped firmware before `createTransactionFromPCZT` ever schedules.
//
//  Stamps in these fixtures are written in the numbering the *wire* uses: a device whose screen
//  reads 3.0.1 stamps `[13, 0, 1]`. Expected versions are written in the numbering the *screen*
//  uses. Where the two appear side by side that is the point of the test, not a typo.
//
//  The reader/normalization/Comparable suites are pure and dependency-free, so they run
//  unserialized; see `KeystoneFirmwareGateTests` below for why the gate suite needs more.
//

import Testing
import Foundation
import ComposableArchitecture
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

// A21: the alias that used to live here is gone. The app's type is now
// `KeystoneDisplayFirmwareVersion` (DISPLAYED numbering — `fromStamp` subtracts Keystone's
// `stampedMajorOffset`, so a device reading 3.0.1 stamps `[13, 0, 1]`), and the SDK's
// `KeystoneFirmwareVersion` is the RAW triple off the batch-signing envelope. Distinct names, so
// nothing shadows anything and comparing one against the other no longer compiles by accident —
// which is what would have silently mis-gated the minimum-firmware check.

// MARK: - Data.keystoneFirmwareStamp() reader

@Suite struct KeystoneFirmwareStampReaderTests {
    private static let key = Array("keystone:fw_version".utf8)

    @Test func stampParsesAsWrittenWithoutNormalizing() {
        var data = Data([0x00, 0x01])
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 13, 0, 1])

        #expect(data.keystoneFirmwareStamp() == KeystoneFirmwareStamp(major: 13, minor: 0, build: 1))
    }

    @Test func stampFromTheTwoPointXLineParses() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 12, 4, 6])

        #expect(data.keystoneFirmwareStamp() == KeystoneFirmwareStamp(major: 12, minor: 4, build: 6))
    }

    @Test func missingKeyReturnsNil() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04])

        #expect(data.keystoneFirmwareStamp() == nil)
    }

    @Test func keyPresentButTruncatedValueReturnsNil() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 13, 0]) // only 2 of the 3 version bytes

        #expect(data.keystoneFirmwareStamp() == nil)
    }

    @Test func keyPresentWithWrongLengthPrefixReturnsNil() {
        var data = Data()
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x04, 13, 0, 0]) // wrong prefix, not postcard's 0x03

        #expect(data.keystoneFirmwareStamp() == nil)
    }

    @Test func multipleOccurrencesFirstValidOneWins() {
        var data = Data()
        // First occurrence: wrong length prefix, invalid.
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x05, 9, 9, 9])
        // Second occurrence: valid.
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 13, 1, 2])

        #expect(data.keystoneFirmwareStamp() == KeystoneFirmwareStamp(major: 13, minor: 1, build: 2))
    }

    @Test func versionBytesAtVeryEndOfDataParses() {
        var data = Data([0xFF])
        data.append(contentsOf: Self.key)
        data.append(contentsOf: [0x03, 14, 5, 6])

        #expect(data.count == 1 + Self.key.count + 4)
        #expect(data.keystoneFirmwareStamp() == KeystoneFirmwareStamp(major: 14, minor: 5, build: 6))
    }

    @Test func emptyDataReturnsNil() {
        #expect(Data().keystoneFirmwareStamp() == nil)
    }
}

// MARK: - KeystoneDisplayFirmwareVersion.fromStamp normalization

@Suite struct KeystoneFirmwareNormalizationTests {
    /// The defect this whole change exists for: a device displaying 3.0.1 stamps `[13, 0, 1]`,
    /// and comparing that raw triple against a displayed-numbering minimum let it through.
    @Test func stampedMajorIsOffsetFromTheDisplayedMajor() {
        let stamp = KeystoneFirmwareStamp(major: 13, minor: 0, build: 1)

        #expect(KeystoneDisplayFirmwareVersion.fromStamp(stamp) == KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 1))
    }

    @Test func twoPointXLineNormalizes() {
        let stamp = KeystoneFirmwareStamp(major: 12, minor: 4, build: 6)

        #expect(KeystoneDisplayFirmwareVersion.fromStamp(stamp) == KeystoneDisplayFirmwareVersion(displayMajor: 2, minor: 4, build: 6))
    }

    /// A 3.0.1 device must read as below a 3.0.3 minimum, not above it — the exact comparison
    /// that was inverted. Written against literals so it holds whatever `minimumSupported` is.
    @Test func threeZeroOneDeviceIsBelowThreeZeroThree() {
        let detected = KeystoneDisplayFirmwareVersion.fromStamp(KeystoneFirmwareStamp(major: 13, minor: 0, build: 1))

        #expect(detected < KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 3))
    }

    /// Guards the second arm: if Keystone ever applies the offset firmware-side, a stamp already
    /// in displayed numbering must pass through untouched rather than underflow to -7.
    @Test func rawMajorBelowTheOffsetIsTakenAsAlreadyNormalized() {
        let stamp = KeystoneFirmwareStamp(major: 3, minor: 0, build: 1)

        #expect(KeystoneDisplayFirmwareVersion.fromStamp(stamp) == KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 1))
    }

    @Test(arguments: [
        (KeystoneFirmwareStamp(major: 10, minor: 0, build: 0), KeystoneDisplayFirmwareVersion(displayMajor: 0, minor: 0, build: 0)),
        (KeystoneFirmwareStamp(major: 9, minor: 9, build: 9), KeystoneDisplayFirmwareVersion(displayMajor: 9, minor: 9, build: 9))
    ])
    func offsetBoundaryNormalizes(stamp: KeystoneFirmwareStamp, expected: KeystoneDisplayFirmwareVersion) {
        #expect(KeystoneDisplayFirmwareVersion.fromStamp(stamp) == expected)
    }

    @Test func minorAndBuildAreNeverOffset() {
        let stamp = KeystoneFirmwareStamp(major: 13, minor: 12, build: 11)

        #expect(KeystoneDisplayFirmwareVersion.fromStamp(stamp) == KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 12, build: 11))
    }
}

// MARK: - KeystoneDisplayFirmwareVersion.Comparable

@Suite struct KeystoneFirmwareVersionComparableTests {
    @Test func lowerMajorIsBelowMinimum() {
        #expect(KeystoneDisplayFirmwareVersion(displayMajor: 2, minor: 9, build: 9) < KeystoneDisplayFirmwareVersion.minimumSupported)
    }

    @Test func minimumIsExactlyThreeZeroOne() {
        #expect(KeystoneDisplayFirmwareVersion.minimumSupported == KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 1))
    }

    @Test func minimumIsNotBelowItself() {
        #expect(!(KeystoneDisplayFirmwareVersion.minimumSupported < KeystoneDisplayFirmwareVersion.minimumSupported))
    }

    @Test func higherBuildIsAboveMinimum() {
        #expect(KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 2) > KeystoneDisplayFirmwareVersion.minimumSupported)
    }

    @Test func comparisonIsLexicographicOnMajorThenMinorThenBuild() {
        // A higher minor must not be shadowed by comparing major alone.
        #expect(
            KeystoneDisplayFirmwareVersion(displayMajor: 2, minor: 99, build: 99)
            < KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 0)
        )
        // A higher build must not be shadowed by comparing major/minor alone.
        #expect(
            KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 0)
            < KeystoneDisplayFirmwareVersion(displayMajor: 3, minor: 0, build: 1)
        )
    }
}

// MARK: - SendConfirmationStore gate

// `SendConfirmation.State` carries `@Shared(.inMemory(...))` process-global storage (address book
// contacts, feature flags, wallet accounts). `.serialized` only orders this suite's own tests — it
// does NOT prevent other suites from running in parallel with it — so each test also binds a fresh
// in-memory store via `withDependencies { $0.defaultInMemoryStorage = InMemoryStorage() }`, which is
// what actually isolates this suite from cross-suite races on that storage.
@Suite(.serialized) @MainActor struct KeystoneFirmwareGateTests {
    private func makeStore() -> TestStore<SendConfirmation.State, SendConfirmation.Action> {
        let initialState = SendConfirmation.State(
            address: "ztestaddr",
            amount: Zatoshi(100_000),
            feeRequired: Zatoshi(10_000),
            message: "",
            proposal: .testOnlyFakeProposal(totalFee: 10_000)
        )

        return TestStore(initialState: initialState) {
            SendConfirmation()
        } withDependencies: {
            $0.mainQueue = .immediate
            // `KeystoneHandlerClient` provides only `liveValue` (no `testValue`), so the override
            // must happen in this construction-time closure: mutating `store.dependencies`
            // afterward would read (and fail on) the missing test value before the override is
            // ever applied. Same idiom as `AddKeystoneHWWalletTests.swift`'s `readyToScanTapped`
            // test.
            $0.keystoneHandler.resetQRDecoder = { }
        }
    }

    /// `stamp` is in the wire's numbering — pass what the device would actually write.
    private func signedPczt(stamp: (major: Int, minor: Int, build: Int)?) -> Pczt {
        var data = Data()
        if let stamp {
            data.append(contentsOf: Array("keystone:fw_version".utf8))
            data.append(contentsOf: [0x03, UInt8(stamp.major), UInt8(stamp.minor), UInt8(stamp.build)])
        }
        return Pczt(data)
    }

    // Below-minimum firmware in four shapes — a clearly-old device (2.4.6), the boundary case one
    // build below the 3.0.1 minimum (3.0.0), the highest 2.x there can be (2.9.9, blocked on the
    // major alone), and a raw stamp below the offset — all must be blocked and must never schedule
    // `createTransactionFromPCZT`. The three stamps in the 12.x/13.x range are also what proves the
    // normalization is load-bearing: unnormalized they would each read as far *above* the minimum.
    @Test(arguments: [(12, 4, 6), (13, 0, 0), (12, 9, 9), (2, 4, 6)])
    func belowMinimumFirmwarePresentsUpdateScreen(major: Int, minor: Int, build: Int) async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            let pczt = signedPczt(stamp: (major, minor, build))
            let expected = KeystoneDisplayFirmwareVersion.fromStamp(
                KeystoneFirmwareStamp(major: major, minor: minor, build: build)
            )

            await store.send(.foundPCZT(pczt)) {
                $0.isKeystoneCodeFound = true
                $0.detectedKeystoneFirmware = expected
            }
            await store.receive(.keystoneFirmwareUpdateRequired)
            // No further action arrives: `createTransactionFromPCZT` is never scheduled. An
            // exhaustive `TestStore` fails on any unasserted action, so reaching `finish()`
            // cleanly here IS the "never schedules" assertion.
            await store.finish()

            #expect(store.state.pcztWithSigs == nil)
        }
    }

    /// The screen must show the version printed on the device, not the wire's internal major.
    @Test func detectedVersionIsReportedInTheNumberingTheDeviceDisplays() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()

            await store.send(.foundPCZT(signedPczt(stamp: (12, 4, 6)))) {
                $0.isKeystoneCodeFound = true
                $0.detectedKeystoneFirmware = KeystoneDisplayFirmwareVersion(displayMajor: 2, minor: 4, build: 6)
            }
            await store.receive(.keystoneFirmwareUpdateRequired)
            await store.finish()

            #expect(store.state.detectedKeystoneFirmware?.versionString == "2.4.6")
        }
    }

    @Test func atMinimumFirmwareProceedsUnchanged() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            // Device displaying 3.0.1 — exactly the minimum.
            let pczt = signedPczt(stamp: (13, 0, 1))

            await store.send(.foundPCZT(pczt)) {
                $0.isKeystoneCodeFound = true
                $0.pcztWithSigs = pczt
            }
            await store.receive(.keystoneFirmwareAccepted)
            // `createTransactionFromPCZT`'s own guard bails with no state change: `pcztWithProofs`
            // was never set, so this proves scheduling happened without needing to mock the
            // synchronizer.
            await store.receive(.createTransactionFromPCZT)
            await store.finish()

            #expect(store.state.detectedKeystoneFirmware == nil)
        }
    }

    @Test func unstampedFirmwarePresentsUpdateScreenWithNilDetectedVersion() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            let pczt = signedPczt(stamp: nil)

            await store.send(.foundPCZT(pczt)) {
                $0.isKeystoneCodeFound = true
            }
            await store.receive(.keystoneFirmwareUpdateRequired)
            await store.finish()

            #expect(store.state.detectedKeystoneFirmware == nil)
            #expect(store.state.pcztWithSigs == nil)
        }
    }

    @Test func closeClearsStateForRescan() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let store = makeStore()
            let pczt = signedPczt(stamp: (12, 4, 6))

            await store.send(.foundPCZT(pczt)) {
                $0.isKeystoneCodeFound = true
                $0.detectedKeystoneFirmware = KeystoneDisplayFirmwareVersion(displayMajor: 2, minor: 4, build: 6)
            }
            await store.receive(.keystoneFirmwareUpdateRequired)

            // The reset now lives in the coordinators, not here: they pop this path element before
            // this reducer would see the action. Covered by `KeystoneFirmwareCoordFlowTests`.
            await store.send(.keystoneFirmwareUpdateCloseTapped)
            await store.finish()
        }
    }
}
