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
                        Button("Seed wallet") { store.send(.seedTapped) }
                        Button("Reset migration", role: .destructive) { store.send(.resetTapped) }
                    }

                    Section("Drive simulation") {
                        Stepper("Advance: \(store.advanceBlocks) blocks", value: $store.advanceBlocks, in: 10...5000, step: 10)
                        Button("Advance block height") { store.send(.advanceHeightTapped) }
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
                }
                .navigationTitle("Migration Debug")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .onAppear { store.send(.onAppear) }
            }
        }
    }
}
