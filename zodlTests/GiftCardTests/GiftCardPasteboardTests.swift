import Foundation
import Testing
import UIKit
@testable import zodl_internal

@Suite(.serialized) @MainActor struct GiftCardPasteboardTests {
    private static let secret = "  https://gift.zodl.com/#v=1&key=synthetic-clipboard-fixture\n"

    // An empty helper fails this assertion, proving the actual UIKit mutation is covered.
    @Test func matchingConsumedGiftIsCleared() throws {
        let name = UIPasteboard.Name("gift-card-test-\(UUID().uuidString)")
        let pasteboard = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        pasteboard.string = Self.secret
        PasteboardClient.clearIfMatches(Self.secret.redacted, in: pasteboard)
        #expect(pasteboard.string == nil)
        #expect(pasteboard.items.isEmpty)
    }

    // Unconditional clearing would erase a replacement between reading and consuming the gift.
    @Test func replacementClipboardContentIsPreserved() throws {
        let name = UIPasteboard.Name("gift-card-test-\(UUID().uuidString)")
        let pasteboard = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        pasteboard.string = Self.secret
        let consumed = try #require(pasteboard.string).redacted
        pasteboard.string = "replacement"
        PasteboardClient.clearIfMatches(consumed, in: pasteboard)
        #expect(pasteboard.string == "replacement")
    }

    @Test(arguments: [nil, ""] as [String?])
    func missingOrEmptyReplacementIsPreserved(replacement: String?) throws {
        let name = UIPasteboard.Name("gift-card-test-\(UUID().uuidString)")
        let pasteboard = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        pasteboard.string = replacement
        let before = pasteboard.items.count
        PasteboardClient.clearIfMatches(Self.secret.redacted, in: pasteboard)
        #expect(pasteboard.string == replacement)
        #expect(pasteboard.items.count == before)
    }
}
