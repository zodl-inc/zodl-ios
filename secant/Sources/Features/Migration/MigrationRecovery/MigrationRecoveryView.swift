//
//  MigrationRecoveryView.swift
//  zodl
//
//  Simplified recovery prompt (overdue / invalid). Figma C4 / C5 (2621:10289).
//

import ComposableArchitecture
import SwiftUI

struct MigrationRecoveryView: View {
    @Perception.Bindable var store: StoreOf<MigrationRecovery>
    let tokenName: String

    init(store: StoreOf<MigrationRecovery>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch store.kind {
                        case .overdue:
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)
                                .padding(.top, 24)

                            Text("Transfers ready to send")
                                .zFont(.semiBold, size: 24, style: Design.Text.primary)

                            Text("Background delivery was delayed — this can happen on some devices. Send the pending transfers now, or reschedule them for later.")
                                .zFont(.regular, size: 16, style: Design.Text.tertiary)

                        case .invalid:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.orange)
                                .padding(.top, 24)

                            Text("A transfer is no longer valid")
                                .zFont(.semiBold, size: 24, style: Design.Text.primary)

                            Text("Some funds were spent, so a scheduled transfer can't go through. We'll create a new transfer for your remaining Orchard balance.")
                                .zFont(.regular, size: 16, style: Design.Text.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                switch store.kind {
                case .overdue:
                    ZashiButton("Send now") {
                        store.send(.sendNowTapped)
                    }
                    .padding(.top, 8)

                    ZashiButton("Reschedule", type: .secondary) {
                        store.send(.rescheduleTapped)
                    }
                    .padding(.bottom, 24)

                case .invalid:
                    ZashiButton("Continue") {
                        store.send(.recreateTapped)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .screenHorizontalPadding()
        }
        .applyScreenBackground()
    }
}
