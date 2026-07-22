//
//  MigrationSimulatorPanelStore.swift
//  zodl
//
//  Debug-only panel driving the migration SDK simulator engine (MOB-1480, testnet builds only —
//  gated end-to-end by `MigrationSimulatorFlag.isEnabled` at the entry gesture). Every control
//  action calls the matching `MigrationSimulatorClient`/`MigrationManagerClient`/`WalletStorageClient`
//  closure and then re-sends `.refresh` to reload the status readout. Presets additionally clear the
//  app-side persisted flags first for the two "finished flow" presets (`.complete`/
//  `.completeWithDust` — the acknowledged flag must be cleared for the complete banner/route to
//  show) and always align the manual-delivery flag afterward via `preset.requiresManualDelivery`.
//  See docs/superpowers/specs/2026-07-13-mob1480-migration-sdk-simulator-design.md §5.3 and §6.
//

import Foundation
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

@Reducer
struct MigrationSimulatorPanel {
    @ObservableState
    struct State: Equatable {
        var noteCount = 1
        var orchardZec = "12.458"
        var readout: SimulatorReadout?

        var isActive: Bool {
            readout?.isActive ?? false
        }

        init(
            noteCount: Int = 1,
            orchardZec: String = "12.458",
            readout: SimulatorReadout? = nil
        ) {
            self.noteCount = noteCount
            self.orchardZec = orchardZec
            self.readout = readout
        }
    }

    enum Action: BindableAction, Equatable {
        case activeToggled(Bool)
        case advanceTimeTapped(hours: Int)
        case applySeedTapped
        case armResultTapped(MigrationTransferResult)
        case armSplitFailureTapped
        case binding(BindingAction<State>)
        case confirmSplitNowTapped
        case delegate(Delegate)
        case makeNextDueNowTapped
        case onAppear
        case openMigrationFlowTapped
        case presetTapped(SimulatorPreset)
        case readoutLoaded(SimulatorReadout)
        case refresh
        case resetAppFlagsTapped
        case resetSimulationTapped
        case resetTorFlagTapped
        case runBackgroundSessionTapped

        enum Delegate: Equatable {
            case openMigrationFlow
            case runBackgroundSession
        }
    }

    @Dependency(\.migrationManager) var migrationManager
    @Dependency(\.migrationSimulator) var migrationSimulator
    @Dependency(\.walletStorage) var walletStorage

    init() { }

    var body: some Reducer<State, Action> {
        BindingReducer()

        Reduce { state, action in
            switch action {
            case .activeToggled(let isActive):
                // Synchronous, non-throwing dependency closure — no effect needed.
                migrationSimulator.setActive(isActive)
                return .send(.refresh)

            case .advanceTimeTapped(let hours):
                migrationSimulator.advanceTime(TimeInterval(hours * 3600))
                return .send(.refresh)

            case .applySeedTapped:
                migrationSimulator.seed(Self.parsedOrchardBalance(state.orchardZec), state.noteCount)
                return .send(.refresh)

            case .armResultTapped(let result):
                migrationSimulator.armTransferResult(result)
                return .send(.refresh)

            case .armSplitFailureTapped:
                migrationSimulator.armSplitFailure()
                return .send(.refresh)

            case .binding:
                return .none

            case .confirmSplitNowTapped:
                migrationSimulator.confirmSplitNow()
                return .send(.refresh)

            case .delegate:
                return .none

            case .makeNextDueNowTapped:
                migrationSimulator.makeNextTransferDueNow()
                return .send(.refresh)

            case .onAppear:
                return .send(.refresh)

            case .openMigrationFlowTapped:
                return .send(.delegate(.openMigrationFlow))

            case .presetTapped(let preset):
                // The complete presets represent an already-finished flow — the app-side
                // acknowledged/mode/manual/network-privacy flags must be cleared BEFORE the preset
                // is applied, or the complete banner/re-entry route derivation would still see the
                // previous run's stale flags.
                if preset == .complete || preset == .completeWithDust {
                    migrationManager.resetPersistedFlags()
                }
                migrationSimulator.applyPreset(preset)
                // Every preset (not just the complete ones) aligns the manual-delivery flag — the
                // engine itself has no notion of "manual delivery", only the panel knows which
                // presets need it.
                migrationManager.setManualDelivery(preset.requiresManualDelivery)
                return .send(.refresh)

            case .readoutLoaded(let readout):
                state.readout = readout
                return .none

            case .refresh:
                return .send(.readoutLoaded(migrationSimulator.readout()))

            case .resetAppFlagsTapped:
                migrationManager.resetPersistedFlags()
                return .send(.refresh)

            case .resetSimulationTapped:
                migrationSimulator.reset()
                return .send(.refresh)

            case .resetTorFlagTapped:
                try? walletStorage.importTorSetupFlag(false)
                return .send(.refresh)

            case .runBackgroundSessionTapped:
                return .send(.delegate(.runBackgroundSession))
            }
        }
    }

    /// Parses the panel's "orchard ZEC" seed field (a plain decimal string, e.g. `"12.458"`) into
    /// `Zatoshi` for `MigrationSimulatorClient.seed`. Unparseable input seeds a zero balance rather
    /// than crashing — this is a debug tool, not a validated user-facing amount field.
    private static func parsedOrchardBalance(_ text: String) -> Zatoshi {
        guard let decimalZec = Decimal(string: text) else {
            return Zatoshi.zero
        }
        let zatoshiDecimal = decimalZec * Decimal(Zatoshi.Constants.oneZecInZatoshi)
        return Zatoshi(NSDecimalNumber(decimal: zatoshiDecimal).int64Value)
    }
}
