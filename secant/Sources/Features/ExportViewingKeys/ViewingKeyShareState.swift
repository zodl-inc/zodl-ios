import Foundation
import os

enum QRFailure: Error, Equatable, Sendable {
    case generationFailed
}

struct ViewingKeySharePayload: Identifiable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id: UUID
    let key: ViewingKeyMaterial
    let png: ViewingKeyPNG

    var description: String { "<redacted viewing key share payload>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .struct)
    }
}

final class ViewingKeyShareOwnership: @unchecked Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private enum Phase: Sendable {
        case prepared
        case nativeOwned
        case cancelled
        case finished
    }

    let payloadID: UUID
    private let phase = OSAllocatedUnfairLock(initialState: Phase.prepared)

    var hasNativeOwnership: Bool {
        phase.withLock { $0 == .nativeOwned }
    }

    var wasCancelledBeforeHandoff: Bool {
        phase.withLock { $0 == .cancelled }
    }

    var isFinished: Bool {
        phase.withLock { $0 == .finished }
    }

    var description: String { "<redacted viewing key share ownership>" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, unlabeledChildren: EmptyCollection<Any>(), displayStyle: .class)
    }

    init(payloadID: UUID) {
        self.payloadID = payloadID
    }

    func claimNativeOwnership() -> Bool {
        phase.withLock { phase in
            guard phase == .prepared else { return false }
            phase = .nativeOwned
            return true
        }
    }

    func cancelPreparedUnlessNativeOwned() -> Bool {
        phase.withLock { phase in
            switch phase {
            case .prepared:
                phase = .cancelled
                return false
            case .nativeOwned:
                return true
            case .cancelled, .finished:
                return false
            }
        }
    }

    func finish() {
        phase.withLock { $0 = .finished }
    }

    static func == (lhs: ViewingKeyShareOwnership, rhs: ViewingKeyShareOwnership) -> Bool {
        guard lhs !== rhs else { return true }
        let lhsPhase = lhs.phase.withLock { $0 }
        let rhsPhase = rhs.phase.withLock { $0 }
        return lhs.payloadID == rhs.payloadID && lhsPhase == rhsPhase
    }
}
