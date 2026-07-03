//
//  MigrationDebugGalleryView.swift
//  zodl
//
//  DEBUG-only gallery of every Ironwood migration screen (MOB-1460…1464), for visual QA. Reachable
//  by long-pressing the balance on Home (see HomeView). Each row presents its screen with a canned
//  fixture state from `MigrationMockData` — the same construction shape as that screen's own
//  `#Preview`. No new reducer: every migration screen's reducer already swallows its own delegate
//  actions, so this is visual-only plumbing (see MOB-1465 spec).
//

#if DEBUG

import SwiftUI
import ComposableArchitecture

struct MigrationDebugGalleryView: View {
    /// One row in the gallery. `Identifiable` via `title` so `.sheet(item:)` can key off it.
    enum Item: String, Identifiable {
        case entryPrivacy = "Entry — privacy selected"
        case entryImmediate = "Entry — immediate selected"
        case networkPrivacyImmediate = "Network Privacy — immediate"
        case networkPrivacyScheduled = "Network Privacy — scheduled (5 transfers)"
        case noteSplitExplainer = "Explainer"
        case noteSplitSplitting = "Splitting"
        case noteSplitConfirmed = "Confirmed"
        case noteSplitFailure = "Failure sheet"
        case backgroundDelivery = "Background Delivery"
        case notificationsScheduled = "Notifications — scheduled"
        case notificationsManual = "Notifications — manual"
        case planScheduled = "Plan — scheduled (5 fresh rows)"
        case planManual = "Plan — manual"
        case planRecreated = "Plan — re-created (2 sent / 1 ready / 2 pending)"
        case reviewImmediate = "Review — immediate"
        case reviewManualStep = "Review — 3 of 5"
        case sending = "Sending"
        case sent = "Sent"
        case sendingFailure = "Sending failure sheet"
        case migrationScheduled = "Migration Scheduled"
        case statusProgress = "Status — progress (2 sent / 1 active / 2 pending)"
        case statusResume = "Status — resume (overdue)"
        case statusRescheduling = "Status — re-scheduling"
        case recoveryNotesSpent = "Recovery — notes spent"
        case recoveryExpired = "Recovery — expired"
        case completeWithDust = "Complete — with dust"
        case completeClean = "Complete — clean"
        case bannerAllStates = "Banner — all states"

        var id: String { rawValue }
    }

    @State private var selected: Item?

    var body: some View {
        NavigationStack {
            List {
                Section("Entry & Network Privacy") {
                    row(.entryPrivacy)
                    row(.entryImmediate)
                    row(.networkPrivacyImmediate)
                    row(.networkPrivacyScheduled)
                }

                Section("Note Split") {
                    row(.noteSplitExplainer)
                    row(.noteSplitSplitting)
                    row(.noteSplitConfirmed)
                    row(.noteSplitFailure)
                }

                Section("Permissions") {
                    row(.backgroundDelivery)
                    row(.notificationsScheduled)
                    row(.notificationsManual)
                }

                Section("Plan & Review") {
                    row(.planScheduled)
                    row(.planManual)
                    row(.planRecreated)
                    row(.reviewImmediate)
                    row(.reviewManualStep)
                }

                Section("Sending & Scheduled") {
                    row(.sending)
                    row(.sent)
                    row(.sendingFailure)
                    row(.migrationScheduled)
                }

                Section("Status, Recovery & Complete") {
                    row(.statusProgress)
                    row(.statusResume)
                    row(.statusRescheduling)
                    row(.recoveryNotesSpent)
                    row(.recoveryExpired)
                    row(.completeWithDust)
                    row(.completeClean)
                }

                Section("Home banner") {
                    row(.bannerAllStates)
                }
            }
            .navigationTitle("Migration Gallery")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $selected) { item in
            content(for: item)
        }
    }

    private func row(_ item: Item) -> some View {
        Button {
            selected = item
        } label: {
            Text(item.rawValue)
        }
    }

    @ViewBuilder private func content(for item: Item) -> some View {
        switch item {
        case .entryPrivacy:
            NavigationStack {
                MigrationEntryView(
                    store: StoreOf<MigrationEntry>(initialState: MigrationMockData.entryPrivacy) {
                        MigrationEntry()
                    }
                )
            }
        case .entryImmediate:
            NavigationStack {
                MigrationEntryView(
                    store: StoreOf<MigrationEntry>(initialState: MigrationMockData.entryImmediate) {
                        MigrationEntry()
                    }
                )
            }
        case .networkPrivacyImmediate:
            NavigationStack {
                MigrationNetworkPrivacyView(
                    store: StoreOf<MigrationNetworkPrivacy>(
                        initialState: MigrationMockData.networkPrivacyImmediate
                    ) {
                        MigrationNetworkPrivacy()
                    }
                )
            }
        case .networkPrivacyScheduled:
            NavigationStack {
                MigrationNetworkPrivacyView(
                    store: StoreOf<MigrationNetworkPrivacy>(
                        initialState: MigrationMockData.networkPrivacyScheduled
                    ) {
                        MigrationNetworkPrivacy()
                    }
                )
            }
        case .noteSplitExplainer:
            NavigationStack {
                MigrationNoteSplitView(
                    store: StoreOf<MigrationNoteSplit>(initialState: MigrationMockData.noteSplitExplainer) {
                        MigrationNoteSplit()
                    }
                )
            }
        case .noteSplitSplitting:
            NavigationStack {
                MigrationNoteSplitView(
                    store: StoreOf<MigrationNoteSplit>(initialState: MigrationMockData.noteSplitSplitting) {
                        MigrationNoteSplit()
                    }
                )
            }
        case .noteSplitConfirmed:
            NavigationStack {
                MigrationNoteSplitView(
                    store: StoreOf<MigrationNoteSplit>(initialState: MigrationMockData.noteSplitConfirmed) {
                        MigrationNoteSplit()
                    }
                )
            }
        case .noteSplitFailure:
            NavigationStack {
                MigrationNoteSplitView(
                    store: StoreOf<MigrationNoteSplit>(initialState: MigrationMockData.noteSplitFailure) {
                        MigrationNoteSplit()
                    }
                )
            }
        case .backgroundDelivery:
            NavigationStack {
                MigrationBackgroundDeliveryView(
                    store: StoreOf<MigrationBackgroundDelivery>(
                        initialState: MigrationMockData.backgroundDelivery
                    ) {
                        MigrationBackgroundDelivery()
                    }
                )
            }
        case .notificationsScheduled:
            NavigationStack {
                MigrationNotificationsView(
                    store: StoreOf<MigrationNotifications>(
                        initialState: MigrationMockData.notificationsScheduled
                    ) {
                        MigrationNotifications()
                    }
                )
            }
        case .notificationsManual:
            NavigationStack {
                MigrationNotificationsView(
                    store: StoreOf<MigrationNotifications>(
                        initialState: MigrationMockData.notificationsManual
                    ) {
                        MigrationNotifications()
                    }
                )
            }
        case .planScheduled:
            NavigationStack {
                MigrationTransferPlanView(
                    store: StoreOf<MigrationTransferPlan>(initialState: MigrationMockData.planScheduled) {
                        MigrationTransferPlan()
                    }
                )
            }
        case .planManual:
            NavigationStack {
                MigrationTransferPlanView(
                    store: StoreOf<MigrationTransferPlan>(initialState: MigrationMockData.planManual) {
                        MigrationTransferPlan()
                    }
                )
            }
        case .planRecreated:
            NavigationStack {
                MigrationTransferPlanView(
                    store: StoreOf<MigrationTransferPlan>(initialState: MigrationMockData.planRecreated) {
                        MigrationTransferPlan()
                    }
                )
            }
        case .reviewImmediate:
            NavigationStack {
                MigrationReviewTransferView(
                    store: StoreOf<MigrationReviewTransfer>(initialState: MigrationMockData.reviewImmediate) {
                        MigrationReviewTransfer()
                    }
                )
            }
        case .reviewManualStep:
            NavigationStack {
                MigrationReviewTransferView(
                    store: StoreOf<MigrationReviewTransfer>(initialState: MigrationMockData.reviewManualStep) {
                        MigrationReviewTransfer()
                    }
                )
            }
        case .sending:
            NavigationStack {
                MigrationSendingView(
                    store: StoreOf<MigrationSending>(initialState: MigrationMockData.sending) {
                        MigrationSending()
                    }
                )
            }
        case .sent:
            NavigationStack {
                MigrationSendingView(
                    store: StoreOf<MigrationSending>(initialState: MigrationMockData.sent) {
                        MigrationSending()
                    }
                )
            }
        case .sendingFailure:
            NavigationStack {
                MigrationSendingView(
                    store: StoreOf<MigrationSending>(initialState: MigrationMockData.sendingFailure) {
                        MigrationSending()
                    }
                )
            }
        case .migrationScheduled:
            NavigationStack {
                MigrationScheduledView(
                    store: StoreOf<MigrationScheduled>(initialState: MigrationMockData.migrationScheduled) {
                        MigrationScheduled()
                    }
                )
            }
        case .statusProgress:
            NavigationStack {
                MigrationStatusView(
                    store: StoreOf<MigrationStatus>(initialState: MigrationMockData.statusProgress) {
                        MigrationStatus()
                    }
                )
            }
        case .statusResume:
            NavigationStack {
                MigrationStatusView(
                    store: StoreOf<MigrationStatus>(initialState: MigrationMockData.statusResume) {
                        MigrationStatus()
                    }
                )
            }
        case .statusRescheduling:
            NavigationStack {
                MigrationStatusView(
                    store: StoreOf<MigrationStatus>(initialState: MigrationMockData.statusRescheduling) {
                        MigrationStatus()
                    }
                )
            }
        case .recoveryNotesSpent:
            NavigationStack {
                MigrationRecoveryView(
                    store: StoreOf<MigrationRecovery>(initialState: MigrationMockData.recoveryNotesSpent) {
                        MigrationRecovery()
                    }
                )
            }
        case .recoveryExpired:
            NavigationStack {
                MigrationRecoveryView(
                    store: StoreOf<MigrationRecovery>(initialState: MigrationMockData.recoveryExpired) {
                        MigrationRecovery()
                    }
                )
            }
        case .completeWithDust:
            NavigationStack {
                MigrationCompleteView(
                    store: StoreOf<MigrationComplete>(initialState: MigrationMockData.completeWithDust) {
                        MigrationComplete()
                    }
                )
            }
        case .completeClean:
            NavigationStack {
                MigrationCompleteView(
                    store: StoreOf<MigrationComplete>(initialState: MigrationMockData.completeClean) {
                        MigrationComplete()
                    }
                )
            }
        case .bannerAllStates:
            NavigationStack {
                bannerAllStatesContent()
            }
        }
    }

    @ViewBuilder private func bannerAllStatesContent() -> some View {
        ScrollView {
            VStack(spacing: 16) {
                bannerStrip(.required)
                bannerStrip(.splitting)
                bannerStrip(.inProgress(done: 2, total: 5))
                bannerStrip(.transferWaiting(number: 3))
                bannerStrip(.updatePlan)
                bannerStrip(.transfersExpired(first: 3, last: 5))
                bannerStrip(.transferReady(number: 4))
                bannerStrip(.complete)
            }
            .padding(16)
        }
        .navigationTitle("Banner — all states")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bannerStrip(_ variant: MigrationBannerVariant) -> some View {
        MigrationBannerContentView(variant: variant, onButtonTap: {})
            .padding(16)
            .background {
                LinearGradient(
                    stops: [
                        Gradient.Stop(color: Design.Utility.Purple._700.color(.light), location: 0.00),
                        Gradient.Stop(color: Design.Utility.Purple._950.color(.light), location: 1.00)
                    ],
                    startPoint: UnitPoint(x: 0.5, y: 0.0),
                    endPoint: UnitPoint(x: 0.5, y: 1.0)
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius._2xl))
    }
}

#Preview {
    MigrationDebugGalleryView()
}

#endif
