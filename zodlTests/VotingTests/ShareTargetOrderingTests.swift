#if VOTING_ENABLED
import Foundation
import Testing
@testable import zodl_internal

private actor PostRecorder {
    private var recorded: [String] = []

    func record(_ server: String) {
        recorded.append(server)
    }

    func servers() -> [String] {
        recorded
    }
}

private func makeSharePayload(index: UInt32 = 0) -> SharePayload {
    SharePayload(
        wireJson: "{\"share_index\":\(index),\"submit_at\":1}",
        shareIndex: index
    )
}

private func distinctShareCounts(_ shares: [DelegatedShareInfo]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for share in shares {
        for server in Set(share.acceptedByServers) {
            counts[server, default: 0] += 1
        }
    }
    return counts
}

struct ShareTargetOrderingTests {
    @Test func orderCandidatesByHealthPartitionsHealthyFirst() {
        let candidates = ["a", "b", "c", "d"]
        let healthy: Set<String> = ["a", "c"]

        let ordered = orderCandidatesByHealth(candidates, healthy: healthy)

        #expect(ordered.count == 4)
        #expect(Set(ordered) == Set(candidates))
        #expect(Set(ordered.prefix(2)) == healthy)
        #expect(Set(ordered.suffix(2)) == Set(["b", "d"]))
    }

    @Test func orderCandidatesByHealthDegeneratesToPermutation() {
        let candidates = ["a", "b", "c"]

        let noneHealthy = orderCandidatesByHealth(candidates, healthy: [])
        #expect(noneHealthy.count == 3)
        #expect(Set(noneHealthy) == Set(candidates))

        let allHealthy = orderCandidatesByHealth(candidates, healthy: Set(candidates))
        #expect(allHealthy.count == 3)
        #expect(Set(allHealthy) == Set(candidates))

        #expect(orderCandidatesByHealth([], healthy: ["a"]).isEmpty)
    }

    @Test func orderCandidatesByHealthIgnoresHealthyEntriesNotInCandidates() {
        let ordered = orderCandidatesByHealth(["a", "b"], healthy: ["b", "z"])

        #expect(ordered == ["b", "a"])
    }

    // Deterministic guard exercise: with the prefix selector, the old code's
    // backfill for A's omission share reached A first (A precedes D in the
    // candidate order once B is tried and C is pruned) — the exact re-admission
    // the every-round omission filter now forbids.
    @Test func omissionGuardExcludesOmittedHelperFromBackfill() async throws {
        let helperB = "https://helper-b.example.com"
        let helperC = "https://helper-c.example.com"
        let helperA = "https://helper-a.example.com"
        let helperD = "https://helper-d.example.com"
        let servers = [helperB, helperC, helperA, helperD]

        let result = try await delegateSharePayloads(
            (0..<16).map { makeSharePayload(index: UInt32($0)) },
            proposalId: 7,
            initialServerURLs: servers,
            postShare: { server, body in
                if server == helperC && body["share_index"] as? Int == 2 {
                    throw URLError(URLError.Code.cannotConnectToHost)
                }
            },
            selectTargets: { candidates, needed in Array(candidates.prefix(needed)) }
        )

        // A sits at configured position 2, so share 2 is A's omitted share. Its
        // round-1 targets are [B, C]; C fails and is pruned; the backfill
        // candidates are [A, D] and the filter must hand the share to D.
        let shareTwo = try #require(result.delegatedShares.first { $0.shareIndex == 2 })
        #expect(!shareTwo.acceptedByServers.contains(helperA))
        #expect(Set(shareTwo.acceptedByServers) == Set([helperB, helperD]))

        #expect(result.delegatedShares.count == 16)
        for (server, count) in distinctShareCounts(result.delegatedShares) {
            #expect(count < 16, "\(server) accumulated every share of the commitment")
        }
    }

    // Default-selector sanity net: assertions hold on every random draw; the
    // guard itself is exercised in the draws whose round-1 targets include the
    // failing helper (the deterministic test above carries guaranteed coverage).
    @Test func productionSpreadNeverHandsAHelperItsOmittedShare() async throws {
        let helperA = "https://helper-a.example.com"
        let helperB = "https://helper-b.example.com"
        let helperC = "https://helper-c.example.com"
        let helperD = "https://helper-d.example.com"
        let servers = [helperA, helperB, helperC, helperD]

        let result = try await delegateSharePayloads(
            (0..<16).map { makeSharePayload(index: UInt32($0)) },
            proposalId: 7,
            initialServerURLs: servers,
            postShare: { server, body in
                if server == helperC && body["share_index"] as? Int == 0 {
                    throw URLError(URLError.Code.cannotConnectToHost)
                }
            }
        )

        let shareZero = try #require(result.delegatedShares.first { $0.shareIndex == 0 })
        #expect(!shareZero.acceptedByServers.contains(helperA))
        #expect(result.delegatedShares.count == 16)
        for (server, count) in distinctShareCounts(result.delegatedShares) {
            #expect(count < 16, "\(server) accumulated every share of the commitment")
        }
    }

    // The guard must not turn into a veto: when pruning leaves only the omitted
    // helper untried, the share still goes out (the crate weighs a lost share
    // as worse than a completed set).
    @Test func omissionGuardFailsOpenWhenOnlyOmittedHelperRemains() async throws {
        let helperA = "https://helper-a.example.com"
        let helperB = "https://helper-b.example.com"
        let helperC = "https://helper-c.example.com"

        let result = try await delegateSharePayloads(
            (0..<16).map { makeSharePayload(index: UInt32($0)) },
            proposalId: 7,
            initialServerURLs: [helperA, helperB, helperC],
            postShare: { server, body in
                if server == helperC && body["share_index"] as? Int == 0 {
                    throw URLError(URLError.Code.cannotConnectToHost)
                }
            }
        )

        // Share 0 omits A; its round-1 targets are therefore exactly {B, C}.
        // C fails and is pruned, leaving A as the only untried helper — the
        // filter empties and the fail-open must deliver the share to A.
        let shareZero = try #require(result.delegatedShares.first { $0.shareIndex == 0 })
        #expect(shareZero.acceptedByServers.contains(helperA))
        #expect(result.delegatedShares.count == 16)
    }

    @Test func resubmitOrdersHealthyUntriedFirstAndSentLast() async {
        let recorder = PostRecorder()
        let configured = [
            "https://a.example.com",
            "https://b.example.com",
            "https://c.example.com",
            "https://d.example.com"
        ]
        let healthy: Set<String> = ["https://b.example.com"]

        let accepted = await resubmitSharePayload(
            makeSharePayload(),
            configuredServerURLs: configured,
            sentToURLs: ["https://d.example.com"],
            postShare: { server, _ in
                await recorder.record(server)
                throw URLError(URLError.Code.cannotConnectToHost)
            },
            orderServers: healthOrderedWalk(healthy: healthy)
        )

        #expect(accepted.isEmpty)
        let attempts = await recorder.servers()
        #expect(attempts.count == 4)
        #expect(attempts.first == "https://b.example.com")
        #expect(attempts.last == "https://d.example.com")
        #expect(Set(attempts.dropFirst().dropLast()) == Set(["https://a.example.com", "https://c.example.com"]))
    }
}
#endif
