//
//  IncompatibleServerDiagnosticsTests.swift
//  zodlTests
//
//  Covers the diagnostics behind the SDK's server-validation failures (ZCBPEO0011 & friends), all
//  in Utils/ZcashError+DetailedMessage.swift: the `isIncompatibleServer` classification, hex
//  rendering of consensus branch IDs, and `incompatibleServerMessage` — the string the Syncing Error
//  displays and the Report button mails to support.
//
//  The UI wiring that reacts to this classification (SmartBanner's Syncing Error sheet offering a
//  route to Server Setup) is covered by SmartBannerTests/SmartBannerIncompatibleServerTests.swift.
//

import ComposableArchitecture
import Foundation
import Testing
@testable @preconcurrency import ZcashLightClientKit
@testable import zodl_internal

@Suite struct ZcashErrorIncompatibleServerTests {
    /// NU5 -> NU6 style pair; the concrete values are irrelevant, only that they differ.
    private static let localBranch = ConsensusBranchID(bitPattern: 0xc8e7_1055)
    private static let remoteBranch = ConsensusBranchID(bitPattern: 0xc2d6_d0b4)

    @Test func wrongConsensusBranchIdIsIncompatibleServer() {
        // ZCBPEO0011 — the server hasn't been upgraded for the current network upgrade.
        let error = ZcashError.compactBlockProcessorWrongConsensusBranchId(
            Self.localBranch,
            Self.remoteBranch
        )

        #expect(error.code.rawValue == "ZCBPEO0011")
        #expect(error.isIncompatibleServer)
    }

    @Test func siblingServerValidationFailuresAreIncompatibleServer() {
        let errors: [ZcashError] = [
            .compactBlockProcessorNetworkMismatch(.mainnet, .testnet),
            .compactBlockProcessorSaplingActivationMismatch(419_200, 1),
            .compactBlockProcessorChainName("bogus"),
            .compactBlockProcessorConsensusBranchID
        ]

        for error in errors {
            #expect(error.isIncompatibleServer, "\(error.code.rawValue) should be an incompatible-server error")
        }
    }

    /// Consensus branch IDs must reach the user in the hex form ZIPs use. `ConsensusBranchID` is an
    /// `Int32`, so the SDK's own error dump shows them in decimal — the values in the #1948
    /// screenshot were `(1412952880, 933566043)`, which are only recognizable as NU6.2 and
    /// NU6.3/Ironwood once rendered as hex. Values cross-checked against librustzcash
    /// `zcash_protocol::consensus` and Zebra's `CONSENSUS_BRANCH_IDS`.
    @Test func consensusBranchIdRendersAsHex() {
        #expect(ConsensusBranchID(1_412_952_880).hexDescription == "0x5437f330")  // NU6.2
        #expect(ConsensusBranchID(933_566_043).hexDescription == "0x37a5165b")    // NU6.3 (Ironwood)
        // Branch IDs with the high bit set (e.g. NU5's 0xc2d6d0b4) are negative as Int32 and must
        // not render as a signed or sign-extended value.
        #expect(ConsensusBranchID(bitPattern: 0xc2d6_d0b4).hexDescription == "0xc2d6d0b4")
    }

    /// The sheet text and the support report both come from this string, so it has to carry the
    /// server, both branch IDs and the code — that is the whole ask of the bug report.
    @Test func incompatibleServerMessageNamesServerAndBranchIdsInHex() throws {
        let error = ZcashError.compactBlockProcessorWrongConsensusBranchId(
            ConsensusBranchID(1_412_952_880),
            ConsensusBranchID(933_566_043)
        )

        let message = try #require(
            withDependencies {
                $0.zcashSDKEnvironment.serverConfig = {
                    UserPreferencesStorage.ServerConfig(host: "outdated.example.com", port: 443, isCustom: false)
                }
            } operation: {
                error.incompatibleServerMessage
            }
        )

        #expect(message.contains("Server: outdated.example.com:443"))
        #expect(message.contains("Expected branch ID: 0x5437f330"))
        #expect(message.contains("Server's branch ID: 0x37a5165b"))
        #expect(message.contains("Error code: ZCBPEO0011"))
    }

    /// Readability, which is the point of writing this message by hand: a punctuated explanation
    /// first, then one labelled fact per line — not the SDK's run-on sentence with a raw enum dump
    /// concatenated onto it.
    @Test func incompatibleServerMessageIsReadable() throws {
        let error = ZcashError.compactBlockProcessorWrongConsensusBranchId(
            ConsensusBranchID(1_412_952_880),
            ConsensusBranchID(933_566_043)
        )

        let message = try #require(
            withDependencies {
                $0.zcashSDKEnvironment.serverConfig = {
                    UserPreferencesStorage.ServerConfig(host: "outdated.example.com", port: 443, isCustom: false)
                }
            } operation: {
                error.incompatibleServerMessage
            }
        )

        let lines = message.components(separatedBy: "\n")
        // Two-sentence explanation, blank line, then exactly one fact per line.
        #expect(lines.count == 7)
        #expect(lines[0].hasSuffix("."))
        #expect(lines[1].hasSuffix("."))
        #expect(lines[2].isEmpty)
        #expect(lines[3].hasPrefix("Server: "))
        #expect(lines[6].hasPrefix("Error code: "))
        // None of the SDK's unpunctuated text or its raw enum dump leaks in.
        #expect(!message.contains("compactBlockProcessorWrongConsensusBranchId"))
        #expect(!message.contains("expecting This could be caused by"))
        #expect(!message.contains("1412952880"))
    }

    /// `SyncStatusSnapshot` chooses between the written message and the SDK dump, and drops the
    /// "Error: " prefix for the former — it reads as prose, so a prefix would undo the rewrite.
    /// Nothing else asserted this branch; the SmartBanner suite only sees the result.
    @Test func snapshotUsesTheWrittenMessageWithoutTheErrorPrefix() {
        let error = ZcashError.compactBlockProcessorWrongConsensusBranchId(
            ConsensusBranchID(1_412_952_880),
            ConsensusBranchID(933_566_043)
        )

        // All three resolved inside the same scope: `incompatibleServerMessage` reads the server
        // config, so computing the expectation outside would hit the unimplemented test dependency.
        let (incompatible, generic, expected) = withDependencies {
            $0.zcashSDKEnvironment.serverConfig = {
                UserPreferencesStorage.ServerConfig(host: "outdated.example.com", port: 443, isCustom: false)
            }
        } operation: {
            (
                SyncStatusSnapshot.snapshotFor(state: .error(error)),
                SyncStatusSnapshot.snapshotFor(state: .error(ZcashError.compactBlockProcessorCritical)),
                error.incompatibleServerMessage
            )
        }

        #expect(incompatible.message == expected)
        #expect(!incompatible.message.hasPrefix("Error:"))
        // Every other error keeps the pre-existing format, prefix and all.
        #expect(generic.message.hasPrefix("Error:"))
        #expect(generic.message.contains("ZCBPEO0009"))
    }

    @Test func incompatibleServerMessageIsNilForUnrelatedErrors() {
        // No dependency override: an unrelated error must not even reach for the server config.
        #expect(ZcashError.synchronizerNotPrepared.incompatibleServerMessage == nil)
        #expect(ZcashError.compactBlockProcessorCritical.incompatibleServerMessage == nil)
    }

    /// A sibling validation failure carries no branch IDs, so it gets the explanation, the server and
    /// the code — and must not fabricate a branch-ID line.
    @Test func siblingFailureOmitsTheBranchIdLine() throws {
        let message = try #require(
            withDependencies {
                $0.zcashSDKEnvironment.serverConfig = {
                    UserPreferencesStorage.ServerConfig(host: "wrongnet.example.com", port: 443, isCustom: false)
                }
            } operation: {
                ZcashError.compactBlockProcessorNetworkMismatch(.mainnet, .testnet).incompatibleServerMessage
            }
        )

        #expect(message.contains("Server: wrongnet.example.com:443"))
        #expect(message.contains("Error code: ZCBPEO0012"))
        #expect(!message.contains("branch ID"))
        #expect(message.components(separatedBy: "\n").count == 5)
    }

    @Test func unrelatedErrorsAreNotIncompatibleServer() {
        let errors: [ZcashError] = [
            .synchronizerNotPrepared,
            .serviceGetInfoFailed(.timeOut),
            .compactBlockProcessorConnectionTimeout,
            .compactBlockProcessorCritical
        ]

        for error in errors {
            #expect(!error.isIncompatibleServer, "\(error.code.rawValue) should not be an incompatible-server error")
        }
    }
}
