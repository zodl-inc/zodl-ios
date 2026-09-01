#if VOTING_ENABLED && ZODL_INTERNAL
import SwiftUI
import ComposableArchitecture

/// Diagnostics for the delegation recovery. Internal builds only.
///
/// THE SPLIT, if this is ever shown more widely. Two kinds of thing are on
/// this screen and they do not carry the same risk:
///
/// - Metadata (which copies exist, their sizes, and the intact-or-replaced
///   verdict) is safe to show anyone and is genuinely useful for support.
/// - The carved ROWS put key material on screen. `van_comm_rand` is elided,
///   but both ends are kept, and it is the one secret in the system that
///   cannot be regenerated. A screenshot is a real disclosure.
///
/// So if the gate is relaxed, relax it for `sources(_:)` minus `rowLine(_:)`,
/// and keep the rows behind `ZODL_INTERNAL`. Do not simply widen the file.
struct DelegationRecoveryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Perception.Bindable var store: StoreOf<DelegationRecovery>

    init(store: StoreOf<DelegationRecovery>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(localizable: .delegationRecoveryHeadline)
                        .zFont(.semiBold, size: 24, style: Design.Text.primary)
                        .padding(.top, 32)

                    Text(localizable: .delegationRecoveryExplanation)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .padding(.top, 8)

                    if let inspection = store.inspection {
                        verdict(inspection)
                        sources(inspection)
                        actions(inspection)
                    } else {
                        Text(localizable: .delegationRecoveryReading)
                            .zFont(size: 14, style: Design.Text.tertiary)
                            .padding(.top, 32)
                    }

                    if let report = store.report {
                        result(report)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .onAppear { store.send(.onAppear) }
            .applyScreenBackground()
            .zashiBack()
            .screenTitle(String(localizable: .settingsRecoverDelegation))
        }
    }

    // MARK: - Verdict

    @ViewBuilder
    private func verdict(_ inspection: DelegationRecoveryInspection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizable: .delegationRecoveryStatusTitle)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)

            if inspection.needsRecovery {
                Text(
                    localizable: .delegationRecoveryStatusReplaced(inspection.restorableBundles)
                )
                .zFont(.medium, size: 14, style: Design.Text.error)
            } else {
                Text(localizable: .delegationRecoveryStatusIntact)
                    .zFont(.medium, size: 14, style: Design.Text.primary)
            }

            if inspection.escrowedBundles > 0 {
                Text(
                    localizable: .delegationRecoveryStatusEscrowed(
                        inspection.escrowedBundles,
                        inspection.escrowedRounds
                    )
                )
                .zFont(size: 13, style: Design.Text.tertiary)
            }
        }
        .padding(.top, 28)
    }

    // MARK: - The databases

    @ViewBuilder
    private func sources(_ inspection: DelegationRecoveryInspection) -> some View {
        Text(localizable: .delegationRecoveryDatabasesTitle)
            .zFont(.semiBold, size: 16, style: Design.Text.primary)
            .padding(.top, 28)

        ForEach(inspection.sources) { source in
            VStack(alignment: .leading, spacing: 3) {
                Text("\(source.name)  /  \(source.fileName)")
                    .zFont(.medium, size: 14, style: Design.Text.primary)

                Text(verdictLine(source))
                    .zFont(size: 13, style: verdictStyle(source))

                if source.databaseBytes > 0 {
                    Text(sizeLine(source))
                        .zFont(size: 12, style: Design.Text.quaternary)
                }

                if !source.rows.isEmpty {
                    ForEach(source.rows) { row in
                        rowLine(row)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Design.Surfaces.bgSecondary.color(colorScheme))
            .cornerRadius(12)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func rowLine(_ row: DelegationRecoveryInspection.Row) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(row.isOriginal ? "->" : "  ")
                .zFont(.medium, size: 12, style: Design.Text.primary)

            VStack(alignment: .leading, spacing: 1) {
                Text("bundle \(row.bundleIndex)  \(row.vanCommRand)")
                    .zFont(.medium, size: 12, style: Design.Text.primary)

                Text("\(row.origin)\(row.isPlausible ? "" : "  (not a field element)")")
                    .zFont(size: 11, style: Design.Text.quaternary)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(_ inspection: DelegationRecoveryInspection) -> some View {
        Text(
            inspection.needsRecovery
                ? String(localizable: .delegationRecoveryWillRestore(inspection.restorableBundles))
                : String(localizable: .delegationRecoveryWillDoNothing)
        )
        .zFont(size: 13, style: Design.Text.tertiary)
        .padding(.top, 28)

        ZashiButton(
            store.isRecovering
                ? String(localizable: .delegationRecoveryRunning)
                : String(localizable: .delegationRecoveryRun)
        ) {
            store.send(.recoverTapped)
        }
        .disabled(store.isRecovering || store.isInspecting)
        .padding(.top, 12)

        ZashiButton(
            String(localizable: .delegationRecoveryRefresh),
            type: .tertiary
        ) {
            store.send(.refreshTapped)
        }
        .disabled(store.isRecovering || store.isInspecting)
        .padding(.top, 8)
    }

    // MARK: - Result of a run

    @ViewBuilder
    private func result(_ report: DelegationRecoveryReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizable: .delegationRecoveryResultTitle)
                .zFont(.semiBold, size: 16, style: Design.Text.primary)

            Text(resultLine(report))
                .zFont(size: 14, style: Design.Text.primary)

            if report.bundlesRejected > 0 {
                Text(localizable: .delegationRecoveryResultRejected(report.bundlesRejected))
                    .zFont(size: 13, style: Design.Text.tertiary)
            }
            if report.bundlesWithoutVan > 0 {
                Text(localizable: .delegationRecoveryResultNoVan(report.bundlesWithoutVan))
                    .zFont(size: 13, style: Design.Text.tertiary)
            }
        }
        .padding(.top, 28)
    }

    // MARK: - Lines

    private func verdictLine(_ source: DelegationRecoveryInspection.Source) -> String {
        switch source.verdict {
        case let .replacedDelegation(bundles):
            return String(localizable: .delegationRecoverySourceReplaced(bundles))
        case .intact:
            return String(localizable: .delegationRecoverySourceIntact)
        case .unreadable:
            return String(localizable: .delegationRecoverySourceUnreadable)
        case .absent:
            return String(localizable: .delegationRecoverySourceAbsent)
        }
    }

    private func verdictStyle(
        _ source: DelegationRecoveryInspection.Source
    ) -> Design.Text {
        switch source.verdict {
        case .replacedDelegation: return Design.Text.error
        case .intact: return Design.Text.primary
        case .unreadable, .absent: return Design.Text.tertiary
        }
    }

    private func sizeLine(_ source: DelegationRecoveryInspection.Source) -> String {
        String(
            localizable: .delegationRecoverySourceSizes(
                kilobytes(source.databaseBytes),
                kilobytes(source.walBytes),
                kilobytes(source.shmBytes)
            )
        )
    }

    private func resultLine(_ report: DelegationRecoveryReport) -> String {
        switch report.outcome {
        case .recovered:
            return String(
                localizable: .delegationRecoveryResultRecovered(
                    report.bundlesEscrowed,
                    report.rounds
                )
            )
        case .nothingToRecover:
            return String(localizable: .delegationRecoveryResultNothing)
        case .noSnapshot:
            return String(localizable: .delegationRecoveryResultNoSnapshot)
        case .failed:
            return String(localizable: .delegationRecoveryResultFailed)
        }
    }

    private func kilobytes(_ bytes: Int) -> String {
        bytes == 0 ? "0" : String(format: "%.1f", Double(bytes) / 1024)
    }
}
#endif
