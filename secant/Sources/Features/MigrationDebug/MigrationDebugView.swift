//
//  MigrationDebugView.swift
//  zodl
//
//  PROTOTYPE / DEBUG control panel for the simulated migration.
//

import ComposableArchitecture
import SwiftUI

struct MigrationDebugView: View {
    @Perception.Bindable var store: StoreOf<MigrationDebug>
    @Environment(\.dismiss) private var dismiss

    init(store: StoreOf<MigrationDebug>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            NavigationStack {
                Form {
                    Section("Current state") {
                        Text(store.snapshot.isEmpty ? "—" : store.snapshot)
                            .font(.system(.caption, design: .monospaced))
                        Button("Refresh") { store.send(.refresh) }
                    }

                    Section("Seed") {
                        TextField("Orchard ZEC", text: $store.orchardZec)
                            .keyboardType(.decimalPad)
                        Stepper("Note count: \(store.noteCount)", value: $store.noteCount, in: 1...10)
                        Button("Save and restart simulation") { store.send(.seedTapped) }
                        Button("Reset migration", role: .destructive) { store.send(.resetTapped) }
                    }

                    Section("Drive simulation") {
                        // 50 blocks ≈ one 6h transfer window in the sim, so blocks * 6 / 50 ≈ hours fast-forwarded.
                        Stepper("Fast-forward: \(store.advanceBlocks) blocks (≈\(store.advanceBlocks * 6 / 50) h)", value: $store.advanceBlocks, in: 10...5000, step: 10)
                        Button("Fast-forward simulated time") { store.send(.advanceHeightTapped) }
                        Button("Confirm note split now") { store.send(.confirmSplitTapped) }
                        Button("▶︎ Run background task now") { store.send(.runBackgroundTaskTapped) }
                    }

                    Section("Arm next transfer result") {
                        Button("Success") { store.send(.armNextResult(.success(txId: "debug"))) }
                        Button("Network error") { store.send(.armNextResult(.networkError(retryable: true))) }
                        Button("Invalid note") { store.send(.armNextResult(.invalidNote)) }
                        Button("Expired") { store.send(.armNextResult(.expired)) }
                    }

                    Section("Jump to state") {
                        Button("Overdue") { store.send(.jumpTo(.overdue)) }
                        Button("Requires attention (invalid)") { store.send(.jumpTo(.invalidTransfer)) }
                        Button("Sync required") { store.send(.jumpTo(.syncRequired)) }
                        Button("Complete") { store.send(.jumpTo(.complete)) }
                        Button("Complete with dust") { store.send(.jumpTo(.completeWithDust)) }
                    }

                    Section("Background task log") {
                        if store.runLog.isEmpty {
                            Text("No background runs recorded yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.runLog) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption)
                                    Text(entry.summary)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(tint(entry.severity))
                                }
                            }
                            Button("Clear log", role: .destructive) { store.send(.clearLogTapped) }
                        }
                    }
                }
                .navigationTitle("Migration Debug")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .onAppear { store.send(.onAppear) }
                .alert(
                    store:
                        store.scope(
                            state: \.$alert,
                            action: \.alert
                        )
                )
            }
        }
    }

    private func tint(_ severity: MigrationBackgroundRun.Severity) -> Color {
        switch severity {
        case .success: return .green
        case .failure: return .red
        case .neutral: return .secondary
        }
    }
}
