//
//  ClampedTests.swift
//  zodlTests
//
//  Covers the @Clamped property wrapper (Utils/Clamped.swift).
//

import Testing
@testable import zodl_internal

@Suite struct ClampedTests {
    private struct InRangeBox {
        @Clamped(0...10) var value: Int = 5
    }

    private struct AboveRangeBox {
        @Clamped(0...10) var value: Int = 20
    }

    private struct BelowRangeBox {
        @Clamped(0...10) var value: Int = -5
    }

    @Test func initialValueWithinRangeIsKept() {
        #expect(InRangeBox().value == 5)
    }

    @Test func initialValueAboveRangeIsClampedToUpper() {
        #expect(AboveRangeBox().value == 10)
    }

    @Test func initialValueBelowRangeIsClampedToLower() {
        #expect(BelowRangeBox().value == 0)
    }

    @Test func assigningInRangeValueUpdatesIt() {
        var box = InRangeBox()
        box.value = 8
        #expect(box.value == 8)
    }

    @Test func assigningAboveRangeClampsToUpper() {
        var box = InRangeBox()
        box.value = 20
        #expect(box.value == 10)
    }

    @Test func assigningBelowRangeClampsToLower() {
        var box = InRangeBox()
        box.value = -5
        #expect(box.value == 0)
    }
}
