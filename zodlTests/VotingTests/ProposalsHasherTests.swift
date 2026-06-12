//
//  ProposalsHasherTests.swift
//  zodlTests
//
//  Created by Michal Fousek on 12.06.2026.
//

import Foundation
import Testing
@testable import zodl_internal

// Test fixtures contain pinned canonical JSON strings that intentionally exceed
// the project's line-length limit — keeping them single-line makes the expected
// byte output obvious and prevents accidental line-ending differences from
// changing the pinned hash.
// swiftlint:disable line_length

/// Covers MOB-1365: the proposal metadata shown to the voter (and from which the
/// signed `proposalId`/`choice` is derived) must recompute to the chain-committed
/// `proposals_hash`; any tampering with titles, option labels or numeric IDs while
/// the round EA key stays valid must change the computed hash.
@Suite struct ProposalsHasherTests {
    /// ZIP 1244 worked example.
    private static let zipExampleProposal = VotingProposal(
        id: 1,
        title: "Approve protocol upgrade",
        description: "Approve or oppose the proposed protocol upgrade.",
        options: [
            VoteOption(index: 0, label: "Support"),
            VoteOption(index: 1, label: "Oppose")
        ]
    )
    private static let zipExampleCanonical =
        #"[{"id":1,"title":"Approve protocol upgrade","description":"Approve or oppose the proposed protocol upgrade.","options":[{"index":0,"label":"Support"},{"index":1,"label":"Oppose"}]}]"#
    /// SHA-256 of the canonical string above, computed with `shasum -a 256` for reference.
    private static let zipExampleHashHex = "3f9a361d43c4ddb77ad138a091374e2e2958718e64937f33df99a09bd567e63d"

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    @Test func canonicalJSONMatchesZIPExample() {
        let canonical = ProposalsHasher.canonicalProposalsJSON([Self.zipExampleProposal])

        #expect(canonical == Self.zipExampleCanonical)
    }

    @Test func computeProposalsHashMatchesZIPExample() {
        let hash = ProposalsHasher.computeProposalsHash([Self.zipExampleProposal])

        #expect(Self.hexString(from: hash) == Self.zipExampleHashHex)
    }

    @Test func canonicalJSONSortsProposalsByIdAndOptionsByIndex() {
        let unsorted = [
            VotingProposal(
                id: 2,
                title: "B",
                description: "second",
                options: [VoteOption(index: 1, label: "No"), VoteOption(index: 0, label: "Yes")]
            ),
            VotingProposal(
                id: 1,
                title: "A",
                description: "first",
                options: [VoteOption(index: 0, label: "X"), VoteOption(index: 1, label: "Y")]
            )
        ]

        let canonical = ProposalsHasher.canonicalProposalsJSON(unsorted)

        #expect(
            canonical ==
            #"[{"id":1,"title":"A","description":"first","options":[{"index":0,"label":"X"},{"index":1,"label":"Y"}]},{"id":2,"title":"B","description":"second","options":[{"index":0,"label":"Yes"},{"index":1,"label":"No"}]}]"#
        )
    }

    /// Pins the canonicalization to Rust `serde_json::to_string` byte output for a
    /// title containing `/`. Swift's default JSON encoding would emit `\/`; Rust
    /// emits `/`. A mismatch here would make every wallet fail closed against the
    /// chain's `proposals_hash` for any round with a slash in a title or label.
    @Test func canonicalJSONDoesNotEscapeForwardSlashInTitles() {
        let proposal = VotingProposal(
            id: 1,
            title: "NU5/NU6 activation",
            description: "Should we activate NU5/NU6?",
            options: [
                VoteOption(index: 0, label: "Yes"),
                VoteOption(index: 1, label: "No")
            ]
        )

        let canonical = ProposalsHasher.canonicalProposalsJSON([proposal])

        #expect(
            canonical ==
            #"[{"id":1,"title":"NU5/NU6 activation","description":"Should we activate NU5/NU6?","options":[{"index":0,"label":"Yes"},{"index":1,"label":"No"}]}]"#
        )
        #expect(
            Self.hexString(from: ProposalsHasher.computeProposalsHash([proposal])) == "d4a105be1f44c96ca4abc6c952d7a6deb3f7cf4df2059a2afe4bb828b96078a1"
        )
    }

    @Test func canonicalJSONEscapesSpecialCharactersInStrings() {
        let proposal = VotingProposal(
            id: 1,
            title: "Quote \" and backslash \\",
            description: "tab\there",
            options: [VoteOption(index: 0, label: "tab\there")]
        )

        let canonical = ProposalsHasher.canonicalProposalsJSON([proposal])

        #expect(canonical.contains(#"\""#), "should escape double quotes")
        #expect(canonical.contains(#"\\"#), "should escape backslashes")
        #expect(canonical.contains(#"\t"#), "should escape tabs")
    }

    /// UI-only metadata (option descriptions, ZIP numbers, forum links) is outside
    /// the ZIP 1244 canonical form and must not change the hash.
    @Test func uiOnlyMetadataDoesNotAffectHash() {
        let withMetadata = VotingProposal(
            id: 1,
            title: "Approve protocol upgrade",
            description: "Approve or oppose the proposed protocol upgrade.",
            options: [
                VoteOption(index: 0, label: "Support", description: "richer copy"),
                VoteOption(index: 1, label: "Oppose", description: "more copy")
            ],
            zipNumber: "1244",
            forumURL: URL(string: "https://forum.example.com/t/1")
        )

        let hash = ProposalsHasher.computeProposalsHash([withMetadata])

        #expect(Self.hexString(from: hash) == Self.zipExampleHashHex)
    }

    // MARK: - Tamper detection (acceptance criteria: title, option order, numeric ids)

    @Test func tamperedTitleChangesHash() {
        var proposals = [Self.zipExampleProposal]
        let chainHash = ProposalsHasher.computeProposalsHash(proposals)

        proposals = [
            VotingProposal(
                id: 1,
                title: "Reject protocol upgrade",
                description: Self.zipExampleProposal.description,
                options: Self.zipExampleProposal.options
            )
        ]

        #expect(ProposalsHasher.computeProposalsHash(proposals) != chainHash)
    }

    @Test func swappedOptionLabelsChangeHash() {
        let chainHash = ProposalsHasher.computeProposalsHash([Self.zipExampleProposal])

        // The attacker swaps which numeric choice maps to which label.
        let swapped = VotingProposal(
            id: 1,
            title: Self.zipExampleProposal.title,
            description: Self.zipExampleProposal.description,
            options: [
                VoteOption(index: 0, label: "Oppose"),
                VoteOption(index: 1, label: "Support")
            ]
        )

        #expect(ProposalsHasher.computeProposalsHash([swapped]) != chainHash)
    }

    @Test func reorderedOptionArrayKeepsHash() {
        let chainHash = ProposalsHasher.computeProposalsHash([Self.zipExampleProposal])

        // Pure array reordering with index→label mapping intact is not a tamper;
        // the canonical form sorts by index.
        let reordered = VotingProposal(
            id: 1,
            title: Self.zipExampleProposal.title,
            description: Self.zipExampleProposal.description,
            options: [
                VoteOption(index: 1, label: "Oppose"),
                VoteOption(index: 0, label: "Support")
            ]
        )

        #expect(ProposalsHasher.computeProposalsHash([reordered]) == chainHash)
    }

    @Test func tamperedNumericIdChangesHash() {
        let chainHash = ProposalsHasher.computeProposalsHash([Self.zipExampleProposal])

        let renumbered = VotingProposal(
            id: 2,
            title: Self.zipExampleProposal.title,
            description: Self.zipExampleProposal.description,
            options: Self.zipExampleProposal.options
        )

        #expect(ProposalsHasher.computeProposalsHash([renumbered]) != chainHash)
    }
}
