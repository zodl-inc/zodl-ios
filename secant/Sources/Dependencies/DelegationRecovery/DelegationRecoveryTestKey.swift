#if RECOVERY_VOTING_ENABLED
import ComposableArchitecture
import Foundation

extension DelegationRecoveryClient: TestDependencyKey {
    static let testValue = Self()
}
#endif
