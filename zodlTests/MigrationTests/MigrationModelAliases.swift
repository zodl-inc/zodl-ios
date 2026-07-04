//
//  MigrationModelAliases.swift
//  zodlTests
//
//  The local prototype Ironwood SDK (MOB-1469) publicly exports migration model names identical
//  to the app's own (`Models/Migration/MigrationModels.swift`) — the app models were written first,
//  against the Kotlin draft, and deliberately keep their shapes as the app-facing contract. Inside
//  the app target the current-module declarations shadow the SDK's, but test files combine
//  `@testable import zodl_internal` with `import ZcashLightClientKit`, where the bare names become
//  genuinely ambiguous. These target-wide aliases pin the APP models — the types every store and
//  reducer under test actually speaks. SDK-only names (`PreparedTx`) and app-only names
//  (`MigrationMode`, `MigrationSummary`, `MigrationTransferRow`) don't collide and aren't aliased.
//

@testable import zodl_internal

typealias AttentionReason = zodl_internal.AttentionReason
typealias MigrationProgress = zodl_internal.MigrationProgress
typealias MigrationSchedule = zodl_internal.MigrationSchedule
typealias MigrationState = zodl_internal.MigrationState
typealias NetworkPrivacyOptions = zodl_internal.NetworkPrivacyOptions
typealias NoteSplitProposal = zodl_internal.NoteSplitProposal
typealias TransferProposal = zodl_internal.TransferProposal
typealias TransferResult = zodl_internal.TransferResult
