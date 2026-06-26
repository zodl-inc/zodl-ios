//
//  RootVotingSensitivityTests.swift
//  zodlTests
//
//  Voting must mark the Root flow "sensitive" so an automatic server switch is never applied
//  mid-vote. iOS presents voting from inside Settings (`path == .settings`); macOS presents it as a
//  peer-section with no `Root.path`, so it carries the same signal via `isMacVotingSectionActive`
//  (issue [#1755], A3). Fund-safety is separately guaranteed by the synchronizer's `switchIfIdle`
//  (it never interrupts a live broadcast); these tests cover the iOS/macOS parity of the deferral.
//

import Testing
import ComposableArchitecture
@testable import zodl_internal

@Suite struct RootVotingSensitivityTests {
    /// iOS mechanism (also valid on macOS): voting lives under Settings, so `path == .settings`
    /// classifies the flow sensitive.
    @Test func settingsHostedVotingIsSensitive() {
        var state = Root.State.initial
        state.path = .settings

        #expect(state.isSensitiveFlowActive == true)
    }

#if os(macOS)
    /// A3: macOS voting is a peer-section with no `path`, so `isMacVotingSectionActive` is what makes
    /// the flow sensitive — without it, `guard let path` would short-circuit to `false`.
    @Test func macVoteSectionMarksFlowSensitiveDespiteNilPath() {
        var state = Root.State.initial
        state.path = nil

        state.isMacVotingSectionActive = false
        #expect(state.isSensitiveFlowActive == false)

        state.isMacVotingSectionActive = true
        #expect(state.isSensitiveFlowActive == true)
    }

    /// A3 effect: while the macOS Vote section is active, an automatic server switch is deferred
    /// (`canApplyAutoServerSwitch == false`) and resumes once the user leaves the section.
    @Test func macVoteSectionDefersAutomaticServerSwitch() {
        var state = Root.State.initial
        state.path = nil

        state.isMacVotingSectionActive = true
        #expect(state.canApplyAutoServerSwitch == false)

        state.isMacVotingSectionActive = false
        #expect(state.canApplyAutoServerSwitch == true)
    }
#endif
}
