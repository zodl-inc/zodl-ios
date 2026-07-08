//
//  BridgeRequestView.swift
//  Zashi
//
//  The Zodl Bridge card content, presented via `.zashiSheet` at the RootView root
//  (the house MacCard — global over the whole window, MODALS.md Rule #5).
//  Everything shown comes from the engine Proposal, never from page text (BR-4).
//

import ComposableArchitecture
import SwiftUI
@preconcurrency import ZcashLightClientKit

struct BridgeRequestView: View {
    let store: StoreOf<BridgeRequest>
    let tokenName: String

    var body: some View {
        WithPerceptionTracking {
            VStack(alignment: .leading, spacing: 16) {
                switch store.phase {
                case .review:
                    review
                case .sending:
                    centered(title: String(bridge: .bridgeSending)) {
                        ProgressView()
                    }
                case .success(let txid):
                    centered(title: String(bridge: .bridgeSuccessTitle)) {
                        if !txid.isEmpty {
                            Text(txid)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        ZashiButton(String(bridge: .bridgeClose)) {
                            store.send(.closeTapped)
                        }
                    }
                case .failure(let message):
                    centered(title: String(bridge: .bridgeFailureTitle)) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        ZashiButton(String(bridge: .bridgeClose)) {
                            store.send(.closeTapped)
                        }
                    }
                case .refused(let message):
                    centered(title: String(bridge: .bridgeRefusedTitle)) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        ZashiButton(String(bridge: .bridgeClose)) {
                            store.send(.closeTapped)
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 380)
        }
    }

    @ViewBuilder private var review: some View {
        Text(String(bridge: .bridgeReviewTitle))
            .font(.title3.weight(.semibold))

        // Provenance first: where the request came from + whether it is verifiable.
        VStack(alignment: .leading, spacing: 6) {
            Text(
                store.origin.isEmpty
                    ? String(bridge: .bridgeOriginManual)
                    : String(bridge: .bridgeOriginFrom(store.origin))
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            switch store.tier {
            case .verified(let domain):
                Text(String(bridge: .bridgeTierVerified(domain)))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            case .pageEmbedded:
                Text(String(bridge: .bridgeTierUnverified))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }

        Divider()

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(String(bridge: .bridgeAmount)).foregroundStyle(.secondary)
                Text("\(store.amount.decimalString()) \(tokenName)")
                    .font(.body.weight(.semibold))
            }
            GridRow {
                Text(String(bridge: .bridgeFee)).foregroundStyle(.secondary)
                Text("\(store.feeRequired.decimalString()) \(tokenName)")
            }
            GridRow(alignment: .top) {
                Text(String(bridge: .bridgeTo)).foregroundStyle(.secondary)
                Text(store.address)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            if !store.memoText.isEmpty {
                GridRow(alignment: .top) {
                    Text(String(bridge: .bridgeMemo)).foregroundStyle(.secondary)
                    Text(store.memoText).lineLimit(4)
                }
            }
        }
        .font(.callout)

        // Default action = Cancel (spec BR-4: the pay path is the deliberate one).
        HStack(spacing: 12) {
            ZashiButton(String(bridge: .bridgeCancel), type: .ghost) {
                store.send(.cancelTapped)
            }
            ZashiButton(String(bridge: .bridgePay)) {
                store.send(.payTapped)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func centered(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity)
    }
}
