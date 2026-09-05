import Dependencies
import Foundation

extension DelegationEscrowClient: TestDependencyKey {
    static let testValue = Self()
}
