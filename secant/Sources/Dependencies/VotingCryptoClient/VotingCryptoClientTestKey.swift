#if VOTING_ENABLED
import ComposableArchitecture
import Foundation

extension VotingCryptoClient: TestDependencyKey {
    static let testValue = Self()
}
#endif
