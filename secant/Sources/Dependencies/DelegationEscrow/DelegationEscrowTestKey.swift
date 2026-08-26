#if VOTING_ENABLED
import ComposableArchitecture
import Foundation

extension DelegationEscrowClient: TestDependencyKey {
    static let testValue = Self()
}
#endif
