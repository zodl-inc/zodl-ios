#if VOTING_ENABLED
//
//  VotingTeardown.swift
//  Zashi
//

@preconcurrency import Combine
import Foundation
import os

/// The window in which nothing may open the voting sidecar or a round session.
///
/// A wallet reset and a stale-database heal both delete `Documents/voting.sqlite3`, and both do
/// it from Root while the voting flow's own effects may still be in flight. Those effects
/// cannot be relied on to be cancelled: Root composes Settings — and the voting flow under it —
/// through a case-filtered scope, so the presentation reducer that would cancel a child's
/// effects does not run on the reset path, and cancellation is cooperative anyway. An effect
/// suspended in a config fetch would otherwise wake up between the close and the delete and
/// recreate the file.
///
/// So the side that is about to delete the file opens this window first, and every voting open
/// asks twice: once before it starts, and once more immediately before the call that would
/// create the database or the session.
///
/// One of these lives in the live ``VotingCryptoClient``, which makes it process-wide — the
/// wallet being torn down is the only wallet there is — while leaving every test with the
/// client's own inert defaults unless it asks for this.
///
/// The two fields answer two different races. `isDraining` refuses an open that would *start*
/// during the window. `generation` is monotonic and refuses an open that started *before* it:
/// such an open captured the previous generation, and no longer matching is what tells it the
/// wallet it was opening for is gone — which stays true after the window closes.
final class VotingTeardown: Sendable {
    private struct Phase: Sendable {
        var generation: UInt64 = 0
        var isDraining = false
    }

    private let phase = OSAllocatedUnfairLock(initialState: Phase())

    /// `nonisolated(unsafe)` because a `PassthroughSubject` is not `Sendable`; sending on one is
    /// safe from any thread, and this one is sent on only by ``begin()``.
    nonisolated(unsafe) private let subject = PassthroughSubject<Void, Never>()

    init() {}

    /// Announced when a teardown begins, for the parts of the app that can act rather than only
    /// refuse: a flow that is still alive cancels its in-flight opens and gives back the
    /// sessions it holds instead of waiting to be told no.
    var began: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Open the window and move the generation on. Every call is balanced by ``end()``.
    func begin() {
        phase.withLock { phase in
            phase.generation &+= 1
            phase.isDraining = true
        }
        subject.send(())
    }

    /// Close the window. An open that started before it is still refused, because the generation
    /// it captured has moved.
    func end() {
        phase.withLock { $0.isDraining = false }
    }

    /// The generation an open should capture, or nil when a teardown is under way and the open
    /// must not start at all.
    var generationIfIdle: UInt64? {
        phase.withLock { $0.isDraining ? nil : $0.generation }
    }

    /// Whether an open that captured `capturedGeneration` may still go ahead.
    func allowsOpen(capturedGeneration: UInt64) -> Bool {
        phase.withLock { !$0.isDraining && $0.generation == capturedGeneration }
    }
}
#endif
