//
//  IronwoodAnnouncementTests.swift
//  zodlTests
//
//  Created by Michal Fousek on 25.07.2026.
//
//  Covers Features/IronwoodAnnouncement/IronwoodAnnouncementStore.swift: showing the
//  in-app browser for the inline guide link (the screen's only route to the support
//  article since the duplicate "Learn more" button was removed), and that "Go to Zodl"
//  persists the acknowledgement flag exactly once and never traps the user even if the
//  keychain write fails.
//

import Testing
import Foundation
import ComposableArchitecture
@testable import zodl_internal

@Suite struct IronwoodAnnouncementTests {
    private struct KeychainWriteFailure: Error { }

    @MainActor @Test func guideTappedShowsInAppBrowser() async {
        let store = TestStore(initialState: IronwoodAnnouncement.State()) {
            IronwoodAnnouncement()
        }

        await store.send(.guideTapped) {
            $0.isInAppBrowserOn = true
        }

        await store.finish()
    }

    /// Opening the guide is NOT acknowledgement of the announcement: unlike `continueTapped`,
    /// `guideTapped` must never write the keychain flag. This records every call to the
    /// dependency and asserts the list stays empty, so a regression that starts treating the
    /// guide link as acknowledgement would fail here.
    @MainActor @Test func guideTappedIsNotAcknowledgement() async {
        let calls = LockIsolated<[Bool]>([])

        let store = TestStore(initialState: IronwoodAnnouncement.State()) {
            IronwoodAnnouncement()
        } withDependencies: {
            $0.walletStorage.importIronwoodAnnouncementFlag = { flag in calls.withValue { $0.append(flag) } }
        }

        await store.send(.guideTapped) {
            $0.isInAppBrowserOn = true
        }

        #expect(calls.value.isEmpty)

        await store.finish()
    }

    @MainActor @Test func continueTappedPersistsAcknowledgementFlagExactlyOnce() async {
        let calls = LockIsolated<[Bool]>([])

        let store = TestStore(initialState: IronwoodAnnouncement.State()) {
            IronwoodAnnouncement()
        } withDependencies: {
            $0.walletStorage.importIronwoodAnnouncementFlag = { flag in calls.withValue { $0.append(flag) } }
        }

        await store.send(.continueTapped)

        #expect(calls.value == [true])

        await store.finish()
    }

    /// A keychain write failure must not trap the user on this one-time announcement screen:
    /// `continueTapped` swallows the error with `try?` instead of surfacing or retrying it, so
    /// the action still completes cleanly with no state change and no effect.
    @MainActor @Test func continueTappedSwallowsKeychainWriteFailure() async {
        let store = TestStore(initialState: IronwoodAnnouncement.State()) {
            IronwoodAnnouncement()
        } withDependencies: {
            $0.walletStorage.importIronwoodAnnouncementFlag = { _ in throw KeychainWriteFailure() }
        }

        await store.send(.continueTapped)

        await store.finish()
    }
}
