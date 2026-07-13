//
//  MigrationTypeDisambiguation.swift
//  zodlTests
//
//  [MOB-1458] The app now builds against the ironwood-support SDK, which exports migration model
//  types with the same names as the app's local draft models (deliberate — the app adopts the SDK
//  types when the real engine wiring lands and the local copies retire). Inside the app module the
//  local types shadow the SDK's, but this test module imports BOTH modules, so unqualified lookups
//  turn ambiguous. These module-internal typealiases pin the app-module meaning for the whole test
//  target in one place. Delete this file with the model dedupe.
//

import ZcashLightClientKit
@testable import zodl_internal

typealias MigrationProgress = zodl_internal.MigrationProgress
typealias NoteSplitProposal = zodl_internal.NoteSplitProposal
typealias TransferProposal = zodl_internal.TransferProposal
typealias MigrationSchedule = zodl_internal.MigrationSchedule
typealias NetworkPrivacyOptions = zodl_internal.NetworkPrivacyOptions
typealias AttentionReason = zodl_internal.AttentionReason
typealias TransferResult = zodl_internal.TransferResult
typealias MigrationState = zodl_internal.MigrationState
