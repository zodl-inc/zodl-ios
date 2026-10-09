//
//  SensitiveDataTests.swift
//  secantTests
//
//  Created by Lukáš Korba on 06.02.2023.
//

import Testing
@preconcurrency import MnemonicSwift
@preconcurrency import ZODLSwiftWalletSDK
@testable import zodl_internal

@Suite struct SensitiveDataTests {
    @Test func seedPhraseConformsToUndescribable() throws {
        #if UNREDACTED
        #expect((SeedPhrase.self as? Undescribable) == nil)
        #else
        #expect((SeedPhrase.self as? Undescribable) != nil)
        #endif
    }

    @Test func birthdayConformsToUndescribable() throws {
        #if UNREDACTED
        #expect((Birthday.self as? Undescribable) == nil)
        #else
        #expect((Birthday.self as? Undescribable) != nil)
        #endif
    }

    @Test func redactableStringConformsToUndescribable() throws {
        #if UNREDACTED
        #expect((RedactableString.self as? Undescribable) == nil)
        #else
        #expect((RedactableString.self as? Undescribable) != nil)
        #endif
    }

    @Test func redactableBlockHeightConformsToUndescribable() throws {
        #if UNREDACTED
        #expect((RedactableBlockHeight.self as? Undescribable) == nil)
        #else
        #expect((RedactableBlockHeight.self as? Undescribable) != nil)
        #endif
    }

    @Test func redactableInt64ConformsToUndescribable() throws {
        #if UNREDACTED
        #expect((RedactableInt64.self as? Undescribable) == nil)
        #else
        #expect((RedactableInt64.self as? Undescribable) != nil)
        #endif
    }
}
