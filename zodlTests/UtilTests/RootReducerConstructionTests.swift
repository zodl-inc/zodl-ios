import ComposableArchitecture
import Darwin
import Foundation
import Testing
@testable import zodl_internal

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RootReducerConstructionTests {
    // An oversized Root construction frame must fail this bounded-stack probe.
    @Test func rootBodyConstructsWithinStartupStackBudget() async {
        let stackBudget = 512 * 1024
        let actualStackSize = await withCheckedContinuation { continuation in
            let thread = Thread {
                withDependencies {
                    $0.context = .test
                } operation: {
                    let reducer = Root().body
                    withExtendedLifetime(reducer) {
                        continuation.resume(returning: pthread_get_stacksize_np(pthread_self()))
                    }
                }
            }
            thread.stackSize = stackBudget
            thread.start()
        }
        // Foundation's allocation can include guard/alignment overhead beyond the request.
        #expect(actualStackSize > 0)
        #expect(actualStackSize <= stackBudget + 32 * 1024)
    }
}
