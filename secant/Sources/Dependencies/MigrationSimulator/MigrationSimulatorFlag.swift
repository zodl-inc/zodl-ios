//
//  MigrationSimulatorFlag.swift
//  zodl
//
//  Compile-time master switch for the migration SDK simulator (MOB-1480). This is the ONLY `#if`
//  in the whole feature — everything else checks `MigrationSimulatorFlag.isEnabled` at runtime, so
//  all simulator code compiles in every target (required: `zodlTests` builds `zodl-internal` /
//  `SECANT_MAINNET` and must still be able to unit-test the engine directly). In non-testnet
//  builds the flag is constant `false` and every hook fed by it is inert.
//
enum MigrationSimulatorFlag {
    /// Hardcoded master switch. Flip to `false` to disable the simulator in testnet builds too.
    static let isEnabled: Bool = {
        #if SECANT_TESTNET
        return true
        #else
        return false
        #endif
    }()
}
