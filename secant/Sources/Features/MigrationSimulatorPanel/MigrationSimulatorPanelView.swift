// NOTE: Every string literal in this file is deliberately inline English, not routed through
// `String(localizable:)` / `Localizable.xcstrings` — an approved deviation (spec §6) for this
// debug-only panel, which never ships outside testnet builds (`MigrationSimulatorFlag.isEnabled`
// is a constant `false` everywhere else).
//
//  MigrationSimulatorPanelView.swift
//  zodl
//
//  Debug panel for the migration SDK simulator (MOB-1480): a plain `Form` in a `NavigationStack`
//  presenting the engine's status readout plus every control from
//  `MigrationSimulatorPanelStore.swift`. Reached via a long-press on the Home balance amount
//  (`WalletBalancesView.balanceContent()`), gated by `MigrationSimulatorFlag.isEnabled`.
//

import SwiftUI
@preconcurrency import ZcashLightClientKit
import ComposableArchitecture

struct MigrationSimulatorPanelView: View {
    @Environment(\.dismiss) private var dismiss

    @Perception.Bindable var store: StoreOf<MigrationSimulatorPanel>

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    statusSection()
                    simulationSection()
                    seedSection()
                    presetsSection()
                    driveSection()
                    armResultSection()
                    flowSection()
                    notesSection()
                }
                .navigationTitle("Migration Simulator")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                store.send(.onAppear)
            }
        }
    }

    @ViewBuilder private func statusSection() -> some View {
        Section("Status") {
            if let readout = store.readout {
                Text(summary(for: readout))
                    .font(.system(.footnote, design: .monospaced))

                Toggle(
                    "Simulation active",
                    isOn: Binding(
                        get: { readout.isActive },
                        set: { store.send(.activeToggled($0)) }
                    )
                )

                if readout.rows.isEmpty {
                    Text("No transfers scheduled yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(readout.rows) { row in
                        Text(summary(for: row))
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            } else {
                Text("Loading…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func simulationSection() -> some View {
        Section("Simulation") {
            Button("Reset simulation", role: .destructive) {
                store.send(.resetSimulationTapped)
            }

            Button("Reset app migration flags", role: .destructive) {
                store.send(.resetAppFlagsTapped)
            }

            Button("Reset Tor setup flag", role: .destructive) {
                store.send(.resetTorFlagTapped)
            }
        }
    }

    @ViewBuilder private func seedSection() -> some View {
        Section("Seed") {
            HStack {
                Text("Orchard ZEC")

                Spacer()

                TextField("12.458", text: $store.orchardZec)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }

            Stepper("Notes: \(store.noteCount)", value: $store.noteCount, in: 1...5)

            Button("Apply & restart") {
                store.send(.applySeedTapped)
            }
        }
    }

    @ViewBuilder private func presetsSection() -> some View {
        Section("Presets") {
            ForEach(SimulatorPreset.allCases, id: \.rawValue) { preset in
                Button(Self.label(for: preset)) {
                    store.send(.presetTapped(preset))
                }
            }
        }
    }

    @ViewBuilder private func driveSection() -> some View {
        Section("Drive") {
            Button("Advance +1h") {
                store.send(.advanceTimeTapped(hours: 1))
            }

            Button("Advance +6h") {
                store.send(.advanceTimeTapped(hours: 6))
            }

            Button("Make next transfer due now") {
                store.send(.makeNextDueNowTapped)
            }

            Button("Confirm note split now") {
                store.send(.confirmSplitNowTapped)
            }

            Button("Run background session now") {
                store.send(.runBackgroundSessionTapped)
            }
        }
    }

    @ViewBuilder private func armResultSection() -> some View {
        Section("Arm next result") {
            Button("Success") {
                store.send(.armResultTapped(MigrationTransferResult.success(txId: "")))
            }

            Button("Network error") {
                store.send(.armResultTapped(MigrationTransferResult.networkError(retryable: true)))
            }

            Button("Invalid note") {
                store.send(.armResultTapped(MigrationTransferResult.invalidNote))
            }

            Button("Expired") {
                store.send(.armResultTapped(MigrationTransferResult.expired))
            }

            Button("Arm note-split failure") {
                store.send(.armSplitFailureTapped)
            }
        }
    }

    @ViewBuilder private func flowSection() -> some View {
        Section("Flow") {
            Button("Open migration flow") {
                store.send(.openMigrationFlowTapped)
            }
        }
    }

    @ViewBuilder private func notesSection() -> some View {
        Section("Notes") {
            Text(
                """
                Strings on this screen are intentionally left in English — it's a debug-only tool, \
                never shown outside testnet builds, and isn't part of the localized catalogue.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Text(
                """
                LLDB, to fire the real background task: e -l objc -- (void)[[BGTaskScheduler \
                sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"co.electriccoin.migration_transfer"]
                """
            )
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private func summary(for readout: SimulatorReadout) -> String {
        """
        active: \(readout.isActive)
        state: \(String(describing: readout.state))
        mode: \(String(describing: readout.mode))
        balance: \(readout.orchardBalance.decimalZashiFullFormatted()) ZEC
        time offset: \(Int(readout.timeOffset))s
        split pending: \(readout.isSplitPending)
        signed batches: \(readout.signedBatchCount)
        armed result: \(readout.armedResultDescription ?? "none")
        last bg run: \(readout.lastBackgroundRunSummary ?? "none")
        dust: \(readout.dustRemainder.amount > 0 ? "\(readout.dustRemainder.decimalZashiFullFormatted()) ZEC\(readout.isDustLocked ? " · locked" : "")" : "none")
        """
    }

    private func summary(for row: MigrationTransferRow) -> String {
        let statusText = String(describing: row.status)
        let broadcasting = row.isBroadcasting ? " · sending now" : ""
        let sentRecently = row.sentMinutesAgo.map { " · sent \($0)m ago" } ?? ""
        let amountText = row.amount.decimalZashiFullFormatted()
        return "#\(row.index) \(amountText) ZEC — \(statusText)\(broadcasting) · due in \(row.hoursFromNow)h\(sentRecently)"
    }

    private static func label(for preset: SimulatorPreset) -> String {
        switch preset {
        case .freshRequired: return "Fresh — migration required"
        case .splitting: return "Splitting"
        case .readyToPropose: return "Ready to propose"
        case .inProgress: return "In progress (2 of 5 sent)"
        case .transferReadyManual: return "Transfer ready (manual)"
        case .transferStalled: return "Transfer stalled"
        case .updatePlanInvalid: return "Update plan (invalid)"
        case .transfersExpired: return "Transfers expired"
        case .syncRequired: return "Sync required"
        case .complete: return "Complete"
        case .completeWithDust: return "Complete with dust"
        }
    }
}
