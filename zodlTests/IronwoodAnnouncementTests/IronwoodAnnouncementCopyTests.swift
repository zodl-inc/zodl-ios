//
//  IronwoodAnnouncementCopyTests.swift
//  zodlTests
//
//  Covers the eight `ironwoodAnnouncement.*` keys in secant/Resources/Localizable.xcstrings behind
//  the Ironwood announcement screen's approved final copy. These are cheap guards against classes
//  of mistake that are invisible in code review: a catalogue entry that silently fails to resolve
//  at runtime, a significant space quietly trimmed from one of the guide-sentence fragments, and
//  someone "fixing" the intentionally mixed-case button text back to the app's usual house style.
//

import Testing
import Foundation
@testable import zodl_internal

@Suite struct IronwoodAnnouncementCopyTests {
    // MARK: - Fixtures

    /// One resolved catalogue entry paired with a short, human-readable name, so a failing
    /// assertion in the parameterised test below points at the specific key, not an opaque index.
    struct Entry: Sendable {
        let name: String
        let value: String
    }

    private static let entries: [Entry] = [
        Entry(name: "title", value: String(localizable: .ironwoodAnnouncementTitle)),
        Entry(name: "body1", value: String(localizable: .ironwoodAnnouncementBody1)),
        Entry(name: "body2", value: String(localizable: .ironwoodAnnouncementBody2)),
        Entry(name: "body3", value: String(localizable: .ironwoodAnnouncementBody3)),
        Entry(name: "guidePrefix", value: String(localizable: .ironwoodAnnouncementGuidePrefix)),
        Entry(name: "guideLink", value: String(localizable: .ironwoodAnnouncementGuideLink)),
        Entry(name: "guideSuffix", value: String(localizable: .ironwoodAnnouncementGuideSuffix)),
        Entry(name: "continue", value: String(localizable: .ironwoodAnnouncementContinue))
    ]

    // MARK: - Case 1: every key resolves to real, non-empty copy

    /// A mistyped or forgotten catalogue entry does not crash and does not fail to compile — it
    /// silently falls back to rendering the raw key itself (e.g. "ironwoodAnnouncement.title") at
    /// runtime, which is easy to miss in review and would only surface as a screen full of raw
    /// keys in a screenshot or on a device. Guard all eight keys at once: each must resolve to
    /// non-empty text, and none may contain the catalogue namespace, which is what that
    /// failed-lookup fallback would produce.
    @Test(arguments: entries)
    func keyResolvesToNonEmptyTranslatedText(_ entry: Entry) {
        #expect(!entry.value.isEmpty, "ironwoodAnnouncement.\(entry.name) resolved to an empty string")
        #expect(
            !entry.value.contains("ironwoodAnnouncement"),
            "ironwoodAnnouncement.\(entry.name) resolved to '\(entry.value)', which looks like a failed lookup"
        )
    }

    // MARK: - Case 2: the guide sentence concatenates correctly

    /// `guidePrefix`, `guideLink` and `guideSuffix` are concatenated directly with no separator
    /// added at the call site, so the significant trailing space on the prefix and leading space
    /// on the suffix live only inside the string catalogue. Losing either — e.g. to an editor
    /// silently trimming trailing whitespace — glues words together ("choose?Our guide" /
    /// "guideexplains") without breaking compilation or showing up in a code-review diff context.
    @Test func guideSentenceConcatenatesToApprovedCopy() {
        let prefix = String(localizable: .ironwoodAnnouncementGuidePrefix)
        let link = String(localizable: .ironwoodAnnouncementGuideLink)
        let suffix = String(localizable: .ironwoodAnnouncementGuideSuffix)

        #expect(prefix + link + suffix == "Not sure which to choose? Our guide explains both options.")

        // If the assertion above ever fails, these two point straight at which fragment lost its space.
        #expect(prefix.hasSuffix(" "), "guidePrefix must keep its trailing space, or the sentence reads 'choose?Our guide'")
        #expect(suffix.hasPrefix(" "), "guideSuffix must keep its leading space, or the sentence reads 'guideexplains'")
    }

    // MARK: - Case 2b: the same guide sentence, in every shipped language

    /// The significant-space trap above is not an English-only risk — it is *more* likely in a
    /// translation, where the fragments are handed over individually and a trailing space looks
    /// like an accident. This walks every localisation the app ships and asserts the two outer
    /// fragments still carry their spaces, so a future language cannot land the "waitour guide"
    /// bug unnoticed. Reads the compiled `.lproj` catalogues directly, since `String(localizable:)`
    /// only ever resolves the test process's own locale.
    @Test func guideFragmentsKeepTheirSignificantSpacesInEveryLanguage() throws {
        let localizations = Bundle.main.localizations.filter { $0 != "Base" }
        #expect(localizations.contains("es"), "expected the Spanish catalogue to ship")

        for code in localizations {
            let bundle = try #require(
                Bundle.main.path(forResource: code, ofType: "lproj").flatMap { Bundle(path: $0) },
                "no compiled catalogue for \(code)"
            )
            let prefix = bundle.localizedString(forKey: "ironwoodAnnouncement.guidePrefix", value: nil, table: "Localizable")
            let suffix = bundle.localizedString(forKey: "ironwoodAnnouncement.guideSuffix", value: nil, table: "Localizable")

            #expect(prefix.hasSuffix(" "), "[\(code)] guidePrefix lost its trailing space: \(prefix)")
            #expect(suffix.hasPrefix(" "), "[\(code)] guideSuffix lost its leading space: \(suffix)")
        }
    }

    // MARK: - Case 3: the primary button's intentional mixed-case exception

    /// Elsewhere in the app the product name is always written all-uppercase "ZODL" (see this
    /// repo's CLAUDE.md, "App name"). This button is an explicit, approved exception to that house
    /// rule per the final design and must read "Zodl", mixed case. If this test ever fails because
    /// someone "corrected" the catalogue value to "ZODL", the fix is to revert that change — this
    /// test is the guard, not the bug.
    @Test func continueButtonReadsGoToZodlWithApprovedMixedCase() {
        #expect(String(localizable: .ironwoodAnnouncementContinue) == "Go to Zodl")
    }
}
