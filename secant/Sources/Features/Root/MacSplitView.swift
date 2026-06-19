//
//  MacSplitView.swift
//  Zashi
//
//  macOS-only two-column split (Mail-style): left control rail + right content panel.
//
//  Approach A — the sidebar drives the existing `Root.path` via the *same* `Home` actions the
//  iOS HomeView buttons send (RootCoordinator already does `state.X = .initial` + `state.path =`),
//  and the right panel renders the *existing* path-destination views. No new reducer/selection
//  state; reset-on-switch and in-panel back arrows come free from the existing coordinator.
//

#if os(macOS)
import SwiftUI
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct MacSplitView: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: StoreOf<Root>
    let tokenName: String
    let networkType: NetworkType

    var body: some View {
        WithPerceptionTracking {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 260)

                Divider()

                rightPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .applyScreenBackground()
            .onAppear {
                // Default the right panel to Activity (the full transaction manager).
                if store.path == nil {
                    store.send(.home(.seeAllTransactionsTapped))
                }
            }
            .onChange(of: store.path) { _, newPath in
                // A finished flow sets path = nil; the split has no empty "home" state on macOS,
                // so fall back to Activity rather than showing a blank panel.
                if newPath == nil {
                    store.send(.home(.seeAllTransactionsTapped))
                }
            }
        }
    }

    // MARK: - Left rail

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            // TODO: [#1755] Phase 3 — account switcher + balance + currency + sync banner here.
            Text("Zashi")
                .zFont(.semiBold, size: 20, style: Design.Text.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 16)

            ForEach(MacSection.allCases, id: \.self) { section in
                sidebarRow(section)
            }

            Spacer()
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sidebarRow(_ section: MacSection) -> some View {
        WithPerceptionTracking {
            Button {
                store.send(section.action)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 22)
                    Text(section.title)
                        .zFont(.medium, size: 16, style: Design.Text.primary)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Design.Text.primary.color(colorScheme))
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._lg)
                        .fill(isSelected(section) ? Design.Surfaces.bgSecondary.color(colorScheme) : .clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func isSelected(_ section: MacSection) -> Bool {
        switch section {
        case .activity: return store.path == .transactionsCoordFlow
        case .receive: return store.path == .receive
        case .send: return store.path == .sendCoordFlow
        case .swap: return store.path == .swapAndPayCoordFlow && store.swapAndPayCoordFlowState.isSwapExperience
        case .pay: return store.path == .swapAndPayCoordFlow && !store.swapAndPayCoordFlowState.isSwapExperience
        case .more: return store.path == .settings
        }
    }

    // MARK: - Right panel

    @ViewBuilder private var rightPanel: some View {
        WithPerceptionTracking {
            if let path = store.path {
                switch path {
                case .transactionsCoordFlow:
                    TransactionsCoordFlowView(
                        store: store.scope(state: \.transactionsCoordFlowState, action: \.transactionsCoordFlow),
                        tokenName: tokenName
                    )
                case .receive:
                    ReceiveView(
                        store: store.scope(state: \.receiveState, action: \.receive),
                        networkType: networkType,
                        tokenName: tokenName
                    )
                case .sendCoordFlow:
                    SendCoordFlowView(
                        store: store.scope(state: \.sendCoordFlowState, action: \.sendCoordFlow),
                        tokenName: tokenName
                    )
                case .swapAndPayCoordFlow:
                    SwapAndPayCoordFlowView(
                        store: store.scope(state: \.swapAndPayCoordFlowState, action: \.swapAndPayCoordFlow),
                        tokenName: tokenName
                    )
                case .settings:
                    SettingsView(
                        store: store.scope(state: \.settingsState, action: \.settings)
                    )
                default:
                    // TODO: [#1755] Phase 2 — remaining sections (scan, currency conversion, etc.).
                    Color.clear
                }
            } else {
                Color.clear
            }
        }
    }
}

private enum MacSection: CaseIterable {
    case activity, receive, send, pay, swap, more

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .receive: return String(localizable: .tabsReceive)
        case .send: return String(localizable: .tabsSend)
        case .pay: return String(localizable: .swapAndPayPay)
        case .swap: return String(localizable: .swapAndPaySwap)
        case .more: return "More"
        }
    }

    var systemImage: String {
        switch self {
        case .activity: return "house"
        case .receive: return "arrow.down.circle"
        case .send: return "arrow.up.circle"
        case .pay: return "creditcard"
        case .swap: return "arrow.2.squarepath"
        case .more: return "ellipsis"
        }
    }

    var action: Root.Action {
        switch self {
        case .activity: return .home(.seeAllTransactionsTapped)
        case .receive: return .home(.receiveTapped)
        case .send: return .home(.sendTapped)
        case .pay: return .home(.payWithNearTapped)
        case .swap: return .home(.swapWithNearTapped)
        case .more: return .home(.settingsTapped)
        }
    }
}
#endif
