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

    @Test func delegateSharePayloadsPrefersHealthyTargets() async throws {
        let recorder = PostRecorder()
        let servers = [
            "https://s1.example.com",
            "https://s2.example.com",
            "https://s3.example.com",
            "https://s4.example.com"
        ]
        let healthy: Set<String> = ["https://s1.example.com", "https://s2.example.com"]

        let result = try await delegateSharePayloads(
            [makeSharePayload()],
            proposalId: 7,
            initialServerURLs: servers,
            postShare: { server, _ in await recorder.record(server) },
            selectTargets: { candidates, needed in
                Array(orderCandidatesByHealth(candidates, healthy: healthy).prefix(needed))
            }
        )

        let posted = await recorder.servers()
        #expect(Set(posted) == healthy)
        let share = try #require(result.delegatedShares.first)
        #expect(Set(share.acceptedByServers) == healthy)
        #expect(result.remainingServerURLs == servers)
    }

    @Test func delegateSharePayloadsBackfillsUnhealthyAfterHealthyFailure() async throws {
        let recorder = PostRecorder()
        let servers = [
            "https://s1.example.com",
            "https://s2.example.com",
            "https://s3.example.com",
            "https://s4.example.com"
        ]
        let healthy: Set<String> = ["https://s1.example.com", "https://s2.example.com"]
        let unhealthy: Set<String> = ["https://s3.example.com", "https://s4.example.com"]

        let result = try await delegateSharePayloads(
            [makeSharePayload()],
            proposalId: 7,
            initialServerURLs: servers,
            postShare: { server, _ in
                await recorder.record(server)
                if server == "https://s1.example.com" {
                    throw URLError(URLError.Code.cannotConnectToHost)
                }
            },
            selectTargets: { candidates, needed in
                Array(orderCandidatesByHealth(candidates, healthy: healthy).prefix(needed))
            }
        )

        // s1 (healthy but unreachable) is pruned after its initial failure; the
        // backfill tops the target count back up to 2 from the only candidates
        // left once s2 (the other initial target) has already succeeded — the
        // never-veto property from `orderCandidatesByHealth`'s doc comment,
        // exercised dynamically instead of via a static candidate list.
        #expect(result.delegatedShares.count == 1)
        let share = try #require(result.delegatedShares.first)
        #expect(share.acceptedByServers.count == 2)
        #expect(share.acceptedByServers.contains("https://s2.example.com"))
        let backfilled = Set(share.acceptedByServers).subtracting(["https://s2.example.com"])
        #expect(backfilled.count == 1)
        #expect(backfilled.isSubset(of: unhealthy))

        let expectedRemaining = Set(servers).subtracting(["https://s1.example.com"])
        #expect(Set(result.remainingServerURLs) == expectedRemaining)

        let attempts = await recorder.servers()
        #expect(attempts.contains("https://s1.example.com"))
        #expect(attempts.contains("https://s2.example.com"))
        let unhealthyAttempts = Set(attempts).intersection(unhealthy)
        #expect(unhealthyAttempts.count == 1)
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
            orderServers: { orderCandidatesByHealth($0, healthy: healthy) }
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
