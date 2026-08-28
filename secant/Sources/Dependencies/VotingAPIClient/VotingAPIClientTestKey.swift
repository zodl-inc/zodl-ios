#if VOTING_ENABLED
import ComposableArchitecture
import Foundation

extension VotingAPIClient: TestDependencyKey {
    static let testValue: Self = {
        var value = Self()
        // Fire-and-forget advisory hint invoked unconditionally by submission
        // effects — silent here so unrelated tests stay green; every other
        // endpoint keeps the macro's unimplemented reporting.
        value.startHealthProbeSweep = { }
        return value
    }()
}
#endif
