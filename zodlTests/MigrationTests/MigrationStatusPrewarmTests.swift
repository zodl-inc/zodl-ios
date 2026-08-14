//
//  MigrationStatusPrewarmTests.swift
//  zodlTests
//
//  MOB-1466: the launch-time prewarm renders the Migration Progress screen's heaviest views
//  off-screen with the preview fixtures (see `MigrationStatusPrewarm`). This smoke test pins that
//  the prewarm keeps building and laying out cleanly — its whole value is running before the user
//  ever reaches the screen, so a fixture or view change that breaks it would otherwise only
//  surface as the first-open freeze quietly returning.
//

import ComposableArchitecture
import Testing
@testable import zodl_internal

@Suite(.serialized) @MainActor struct MigrationStatusPrewarmTests {
    @Test func prewarmRendersOffscreenWithoutCrashing() {
        MigrationStatusPrewarm.run()
    }
}
