#if VOTING_ENABLED
//
//  AccountUUID+Voting.swift
//  Zashi
//

import Foundation
@preconcurrency import ZcashLightClientKit

extension AccountUUID {
    /// The account id in the hyphenated form `zcash_voting` parses.
    ///
    /// The SDK carries the id as its 16 raw bytes, while a round session's
    /// inputs name the account as text, so the two have to be bridged
    /// somewhere. An id that is not 16 bytes cannot be a UUID at all and
    /// answers with an empty string, which the session then refuses — better
    /// than inventing a different account's id by padding.
    var votingUUIDString: String {
        guard id.count == 16 else { return "" }
        let bytes = (
            id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7],
            id[8], id[9], id[10], id[11], id[12], id[13], id[14], id[15]
        )
        return UUID(uuid: bytes).uuidString
    }
}
#endif
