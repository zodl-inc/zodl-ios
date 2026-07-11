//
//  TransactionsManagerView.swift
//  Zashi
//
//  Created by Lukáš Korba on 01-22-2025.
//

import SwiftUI
import Combine
import ComposableArchitecture
@preconcurrency import ZcashLightClientKit

struct TransactionsManagerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @PlatformBindable var store: StoreOf<TransactionsManager>
    let tokenName: String
    
    @Shared(.appStorage(.sensitiveContent)) var isSensitiveContentHidden = false

    init(store: StoreOf<TransactionsManager>, tokenName: String) {
        self.store = store
        self.tokenName = tokenName
    }

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
#if !os(macOS)
                // macOS: search + filter live in the window toolbar (see the `.toolbar` below);
                // the content area is the full transaction list.
                HStack(spacing: 0) {
                    ZashiTextField(
                        text: $store.searchTerm,
                        placeholder: String(localizable: .filterSearch),
                        eraseAction: { store.send(.eraseSearchTermTapped) },
                        accessoryView: !store.searchTerm.isEmpty ? Asset.Assets.Icons.xClose.image
                            .zImage(size: 16, style: Design.Btns.Tertiary.fg) : nil,
                        prefixView: Asset.Assets.Icons.search.image
                            .zImage(size: 20, style: Design.Dropdowns.Default.text)
                    )
                    .padding(.trailing, 8)

                    Button {
                        store.send(.filterTapped)
                    } label: {
                        ZStack {
                            Asset.Assets.Icons.filter.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(10)
                                .background {
                                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                                        .fill(Design.Btns.Secondary.bg.color(colorScheme))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: Design.Radius._xl)
                                                .stroke(store.activeFilters.count > 0
                                                        ? Design.Utility.Gray._900.color(colorScheme)
                                                        : Design.Utility.Gray._100.color(colorScheme),
                                                        style: StrokeStyle(lineWidth: store.activeFilters.count > 0 ? 2.0 : 1.0)
                                                )
                                        }
                                }
                            
                            if store.activeFilters.count > 0 {
                                Text("\(store.activeFilters.count)")
                                    .zFont(.medium, size: 12, style: Design.Text.opposite)
                                    .background {
                                        Circle()
                                            .fill(Design.Utility.Gray._900.color(colorScheme))
                                            .frame(width: 20, height: 20)
                                            .background {
                                                Circle()
                                                    .fill(Asset.Colors.background.color)
                                                    .frame(width: 24, height: 24)
                                            }
                                    }
                                    .offset(x: 22, y: -22)
                            }
                        }
                    }
                }
                .screenHorizontalPadding()
                .padding(.vertical, 12)
#endif
                
                if store.transactionSections.isEmpty && !store.isInvalidated {
                    noTransactionsView()
                        .macContentRowCap()

                    Spacer()
                } else {
                    ScrollViewReader { scrollViewProxy in
                        List {
                            if store.isInvalidated {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(0..<15) { _ in
                                        NoTransactionPlaceholder(true)
                                    }
                                    
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity)
                                .macContentRowCap()
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Asset.Colors.background.color)
                                .listRowSeparator(.hidden)
                            } else {
                                ForEach(store.transactionSections) { section in
                                    WithPerceptionTracking {
                                        Section {
                                            ForEach(section.transactions) { transaction in
                                                WithPerceptionTracking {
                                                    Button {
                                                        store.send(.transactionTapped(transaction.id))
                                                    } label: {
                                                        TransactionRowView(
                                                            transaction: transaction,
                                                            tokenName: tokenName,
                                                            isUnread: TransactionsManager.isUnread(transaction),
                                                            isSwap: TransactionsManager.isSwap(transaction),
                                                            divider: section.latestTransactionId != transaction.id
                                                        )
                                                        .onAppear {
                                                            if transaction.requiresAutoUpdate {
                                                                store.send(.transactionOnAppear(transaction.id))
                                                            }
                                                        }
                                                    }
                                                    .macContentRowCap()
                                                    .listRowInsets(EdgeInsets())
                                                }
                                            }
                                            .listRowBackground(Asset.Colors.background.color)
                                            .listRowSeparator(.hidden)
                                        } header: {
                                            Text(section.id)
                                                .zFont(.medium, size: 16, style: Design.Text.tertiary)
                                                .screenHorizontalPadding()
                                                .macContentRowCap()
                                                .listRowInsets(EdgeInsets())
                                                .listRowBackground(Asset.Colors.background.color)
                                                .listRowSeparator(.hidden)
                                                .id(section.id)
                                        }
                                    }
                                }
                            }
                        }
                        .onChange(of: store.transactionSections) { _ in
                            scrollViewProxy.scrollTo(store.transactionSections.first?.id, anchor: .top)
                        }
                    }
                }
            }
            .disabled(store.transactions.isEmpty)
            // macOS: full-width List so the (visible) scroll indicator hits the window edge, not the
            // 530-column edge. Each row/empty-state caps its own content via `.macContentRowCap()`.
            // iOS unaffected — `capped: false` collapses to the same background-only path there (Rule #11).
            .applyScreenBackground(capped: false)
            .listStyle(.plain)
            .zashiHideListBackground()
            .onAppear { store.send(.onAppear) }
#if os(macOS)
            // macOS: search + filter live in the window toolbar as two SEPARATE glass capsules —
            // search first (native NSSearchField), filter second (clean icon-only circle).
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NativeSearchField(
                        text: $store.searchTerm,
                        placeholder: String(localizable: .filterSearch)
                    )
                    .frame(width: Design.Mac.toolbarSearchFieldWidth)
                }
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItem(placement: .primaryAction) {
                    macFilterToolbarButton()
                }
            }
            // A title MUST be set or `.primaryAction` items collapse to the LEADING edge — landing
            // over the sidebar / traffic lights instead of trailing. `.screenTitle` is a no-op on
            // macOS, so anchor it here. The window hides the title text (titleVisibility = .hidden in
            // the split), so this is placement-only: search + filter snap right, over the content.
            .navigationTitle("")
#endif
#if !os(macOS)
            // macOS: the hide-balance eye lives in the split's left rail; don't duplicate it.
            .zashiNavigationBarItems(trailing: hideBalancesButton())
#endif
            .zashiSheet(isPresented: $store.filtersRequest) {
                filtersContent()
            }
        }
        .zashiNavBarTitleDisplayMode(.inline)
#if !os(macOS)
        // macOS: this is the split's default content (Activity) — no back-to-home.
        .zashiBack() {
            store.send(.dismissRequired)
        }
#endif
        .screenTitle(String(localizable: .generalActivity).uppercased())
    }

#if os(macOS)
    /// Native window-toolbar filter button (macOS). Provide ONLY the SF Symbol — no `.resizable()`,
    /// no frame, no color: the system sizes it and wraps it in a clean circular glass capsule.
    /// (Forcing a size via `zImage` is what turned it into a scaled-up capsule.) An active filter is
    /// signalled by swapping to the filled-circle glyph (the Finder/Mail idiom): it keeps the capsule
    /// intact, unlike a count badge, which needs an overlay that breaks it. The exact count stays in
    /// the filter sheet. `WithPerceptionTracking` so the glyph refreshes when `activeFilters` changes.
    @ViewBuilder func macFilterToolbarButton() -> some View {
        WithPerceptionTracking {
            Button {
                store.send(.filterTapped)
            } label: {
                Image(systemName: store.activeFilters.count > 0
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease")
            }
            // The app sets a global `.zashiPlainButtonStyle()` for content buttons; that cascades into
            // the toolbar and strips the native glass capsule. Resetting to `.automatic` restores the
            // toolbar's default — a clean circular glass button.
            .buttonStyle(.automatic)
        }
    }
#endif

    @ViewBuilder func hideBalancesButton() -> some View {
        Button {
            $isSensitiveContentHidden.withLock { $0.toggle() }
        } label: {
            let image = isSensitiveContentHidden ? Asset.Assets.eyeOff.image : Asset.Assets.eyeOn.image
            image
                .zImage(size: 24, color: Asset.Colors.primary.color)
                .padding(Design.Spacing.navBarButtonPadding)
        }
    }
    
    @ViewBuilder func noTransactionsView() -> some View {
        WithPerceptionTracking {
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<5) { _ in
                        NoTransactionPlaceholder()
                    }
                    
                    Spacer()
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: .clear, location: 0.0),
                            Gradient.Stop(color: Asset.Colors.background.color, location: 0.3)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                
                VStack(spacing: 0) {
                    Asset.Assets.Illustrations.emptyState.image
                        .resizable()
                        .frame(width: 164, height: 164)
                        .padding(.bottom, 20)

                    Text(localizable: .filterNoResults)
                        .zFont(.semiBold, size: 20, style: Design.Text.primary)
                        .padding(.bottom, 8)

                    Text(localizable: .filterWeTried)
                        .zFont(size: 14, style: Design.Text.tertiary)
                        .padding(.bottom, 20)
                }
                .padding(.top, 40)
            }
        }
    }
}

// MARK: - Previews

#Preview {
    TransactionsManagerView(store: TransactionsManager.initial, tokenName: "ZEC")
}

// MARK: - Store

extension TransactionsManager {
    @MainActor static var initial = StoreOf<TransactionsManager>(
        initialState: .initial
    ) {
        TransactionsManager()
    }
}

// MARK: - Placeholders

extension TransactionsManager.State {
    static var initial: TransactionsManager.State { TransactionsManager.State() }
}
