//
//  PlatformBindable.swift
//  Zashi
//
//  Cross-platform alias for the `@Bindable` property wrapper.
//
//  iOS still targets 16, which predates the Observation framework, so it uses
//  TCA/Perception's backport (`Perception.Bindable`). macOS targets 14+, which has
//  native Observation — there Perception marks its `Bindable` `unavailable` and expects
//  SwiftUI's native `Bindable`.
//
//  Writing `@Bindable` unqualified fails on iOS with "'Bindable' is ambiguous for type
//  lookup" because both `PerceptionCore.Bindable` and `SwiftUI.Bindable` are in scope and
//  type-name lookup doesn't filter by availability. This alias resolves to exactly one
//  type per platform, so it's unambiguous everywhere.
//

import SwiftUI
import ComposableArchitecture

#if os(iOS)
typealias PlatformBindable = Perception.Bindable
#else
typealias PlatformBindable = SwiftUI.Bindable
#endif
