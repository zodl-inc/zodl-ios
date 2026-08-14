//
//  ZcashError+DetailedMessage.swift
//  
//
//  Created by Lukáš Korba on 24.03.2024.
//

import ComposableArchitecture
import Foundation
@preconcurrency import ZcashLightClientKit

// NOTE: `ConsensusBranchID` is the SDK's typealias for `Int32`, so this extends `Int32` — kept
// internal and narrowly named for that reason. (The SDK itself extends the same typealias with
// `fromString(_:)`.)
extension ConsensusBranchID {
    /// A consensus branch ID as ZIPs, `zcashd` and lightwalletd spell it (`0x37a5165b`), which is
    /// the only form support staff can cross-reference. Being an `Int32`, both `detailedMessage`'s
    /// `"\(self)"` dump and plain interpolation render it in decimal (`933566043`) instead —
    /// unrecognizable against any documentation.
    var hexDescription: String {
        String(format: "0x%08x", UInt32(bitPattern: self))
    }
}

extension ZcashError {
    var detailedMessage: String {
        "[\(self.code.rawValue)] \(self.message)\n\(self)"
    }
    
    var isInsufficientBalance: Bool {
        detailedMessage.lowercased().contains("insufficient balance")
        || detailedMessage.lowercased().contains("the transaction requires an additional change output of zatbalance")
    }

    /// Server-validation failures the SDK raises from `ValidateServerAction` on every sync attempt:
    /// the lightwalletd instance we're talking to disagrees with this build about which network /
    /// consensus rules are in effect.
    ///
    /// **Either side can be the stale one, and the error cannot tell you which.** Consensus branch
    /// IDs are arbitrary constants, not ordered values, so `expectedLocally` vs `found` says nothing
    /// about which is newer. Observed in #1948: the server published NU6.3/Ironwood (`0x37a5165b`)
    /// while the app expected NU6.2 (`0x5437f330`) — the *app* was behind, and switching servers
    /// would not have helped. Any user-facing copy must therefore offer both remedies (update ZODL,
    /// or change server) rather than blaming the server.
    ///
    /// Sync can never make progress in this state — retrying is pointless — and the raw
    /// `detailedMessage` names neither the server involved nor a way out. Hence
    /// `incompatibleServerMessage` below, and the "Switch server" row this flag gates in the SmartBanner's
    /// Syncing Error sheet (`SmartBanner.State.lastKnownErrorIsIncompatibleServer`).
    var isIncompatibleServer: Bool {
        switch self {
        case .compactBlockProcessorWrongConsensusBranchId,      // ZCBPEO0011
            .compactBlockProcessorNetworkMismatch,              // ZCBPEO0012
            .compactBlockProcessorSaplingActivationMismatch,    // ZCBPEO0013
            .compactBlockProcessorChainName,                    // ZCBPEO0016
            .compactBlockProcessorConsensusBranchID:            // ZCBPEO0017
            return true

        default:
            return false
        }
    }

    /// A written explanation of the server-validation failures above, followed by the facts support
    /// needs, each on its own labelled line. `nil` for every other error.
    ///
    /// Deliberately **not** built on top of `detailedMessage`. For these cases that would lead with
    /// the SDK's own run-on sentence — "…than the one your App is expecting This could be caused by…",
    /// missing its full stop — and then append a raw `"\(self)"` enum dump whose two decimal integers
    /// are exactly the branch IDs spelled out properly below: unpunctuated text concatenated onto
    /// more unpunctuated text, which is unreadable and tells the user nothing they can act on. What
    /// someone relaying this to Application Support needs is the server, both branch IDs in hex, and
    /// the error code, as discrete lines.
    ///
    /// This is the string the Syncing Error sheet displays and the Report button mails.
    var incompatibleServerMessage: String? {
        guard isIncompatibleServer else {
            return nil
        }

        @Dependency(\.zcashSDKEnvironment) var zcashSDKEnvironment

        var lines = [
            String(localizable: .syncMessageErrorIncompatibleServer),
            "",
            String(localizable: .syncMessageErrorServer(zcashSDKEnvironment.serverConfig().serverString()))
        ]

        if case let .compactBlockProcessorWrongConsensusBranchId(expectedLocally, found) = self {
            lines.append(String(localizable: .syncMessageErrorBranchId(expectedLocally.hexDescription, found.hexDescription)))
        }

        lines.append(String(localizable: .syncMessageErrorCode(code.rawValue)))

        return lines.joined(separator: "\n")
    }
}
