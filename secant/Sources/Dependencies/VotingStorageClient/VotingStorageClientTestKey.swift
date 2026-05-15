import ComposableArchitecture
import Foundation

extension VotingStorageClient: TestDependencyKey {
    static let testValue = Self()
}
