import ComposableArchitecture
import Foundation

extension VotingAPIClient: TestDependencyKey {
    static let testValue = Self()
}
