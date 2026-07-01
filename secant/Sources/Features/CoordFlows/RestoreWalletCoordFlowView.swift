//
//  RestoreWalletCoordFlowView.swift
//  Zashi
//
//  Created by Lukáš Korba on 27-03-2025.
//

import SwiftUI
import Combine
import ComposableArchitecture

struct RestoreWalletCoordFlowView: View {
    @Environment(\.colorScheme) var colorScheme

    @PlatformBindable var store: StoreOf<RestoreWalletCoordFlow>

    init(store: StoreOf<RestoreWalletCoordFlow>) {
        self.store = store
    }
    
    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
#if os(macOS)
                // macOS: the animated sphinx landing IS the onboarding root. It drives the same
                // RestoreWalletCoordFlow actions (`.importExistingWallet` / `.createNewWalletTapped`),
                // so the pushed restore/create destinations below are unchanged. iOS keeps the plain
                // logo/title/CTA root verbatim (Rule #11).
                MacLandingView(store: store)
                    .alert($store.scope(state: \.alert, action: \.alert))
#else
                VStack {
                    Spacer()

                    Asset.Assets.zashiLogo.image
                        .zImage(width: 105, height: 105, color: Asset.Colors.primary.color)
                        .padding(.bottom, 14)

                    Asset.Assets.zashiTitle.image
                        .zImage(width: 203, height: 51, color: Asset.Colors.primary.color)
                        .padding(.bottom, 16)

                    Text(localizable: .plainOnboardingTitle)
                        .zFont(size: 20, style: Design.Text.secondary)
                        .padding(.top, 15)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Spacer()
                    
                    ZashiButton(
                        String(localizable: .plainOnboardingButtonRestoreWallet),
                        type: .tertiary
                    ) {
                        store.send(.importExistingWallet)
                    }
                    .accessibilityIdentifier(AccessibilityID.Onboarding.restoreWallet)
                    .padding(.bottom, 8)

                    ZashiButton(String(localizable: .plainOnboardingButtonCreateNewWallet)) {
                        store.send(.createNewWalletTapped)
                    }
                    .accessibilityIdentifier(AccessibilityID.Onboarding.createWallet)
                    .padding(.bottom, 24)
                }
                .screenHorizontalPadding()
                .applyOnboardingScreenBackground()
                .alert($store.scope(state: \.alert, action: \.alert))
#endif
            } destination: { store in
                switch store.case {
                case let .estimateBirthdaysDate(store):
                    WalletBirthdayEstimateDateView(store: store)
                case let .estimatedBirthday(store):
                    WalletBirthdayEstimatedHeightView(store: store)
                case let .recoverySeedPhraseEntry(store):
                    RecoverySeedPhraseEntryView(store: store)
                case let .restoreInfo(store):
                    RestoreInfoView(store: store)
                case let .walletBirthday(store):
                    WalletBirthdayView(store: store)
                }
            }
            // Both the (?) help and Tor sheets are triggered from pushed destinations (seed
            // entry, wallet birthday). On macOS zashiSheet renders an overlay, which is hidden
            // if attached to a view the NavigationStack has covered — so keep both here on the
            // NavigationStack, where the overlay sits above the whole pushed stack. (On iOS these
            // are native sheets that present window-level from either spot.)
            .zashiSheet(isPresented: $store.isHelpSheetPresented) {
                helpSheetContent()
            }
            .zashiSheet(isPresented: $store.isTorSheetPresented) {
                torSheetContent()
            }
        }
    }

    @ViewBuilder private func helpSheetContent() -> some View {
        VStack(spacing: 0) {
            Text(localizable: .restoreWalletHelpTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)
            
            infoContent(text: String(localizable: .restoreWalletHelpPhrase))
                .padding(.bottom, 12)
            
            infoContent(text: String(localizable: .walletBirthdayHelpDescRecovery))
                .padding(.bottom, 32)
            
            ZashiButton(String(localizable: .restoreInfoGotIt)) {
                store.send(.helpSheetRequested)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func torSheetContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Asset.Assets.infoOutline.image
                .zImage(size: 20, style: Design.Utility.Gray._500)
                .background {
                    Circle()
                        .fill(Design.Utility.Gray._100.color(colorScheme))
                        .frame(width: 44, height: 44)
                }
                .padding(.top, 48)
                .padding(.leading, 12)
            
            Text(localizable: .torSettingsSheetTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 24)
                .padding(.bottom, 12)
            
            Text(localizable: .torSettingsSheetMsg)
                .zFont(size: 14, style: Design.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .padding(.bottom, Design.Spacing._3xl)
            
            DescriptiveToggle(
                isOn: $store.isTorOn,
                title: String(localizable: .torSettingsSheetTitle),
                desc: String(localizable: .torSettingsSheetDesc)
            )
            .padding(.bottom, 32)
            
            ZashiButton(String(localizable: .generalCancel), type: .tertiary) {
                store.send(.restoreCancelTapped)
            }
            .padding(.bottom, Design.Spacing._lg)
            
            ZashiButton(String(localizable: .importWalletButtonRestoreWallet)) {
                store.send(.resolveRestoreRequested)
            }
            .padding(.bottom, Design.Spacing.sheetBottomSpace)
        }
    }
    
    @ViewBuilder private func infoContent(text: String) -> some View {
        HintBox(text, style: .markdown)
    }
}

#Preview {
    NavigationView {
        RestoreWalletCoordFlowView(store: RestoreWalletCoordFlow.placeholder)
    }
}

// MARK: - Placeholders

extension RestoreWalletCoordFlow.State {
    static var initial: RestoreWalletCoordFlow.State { RestoreWalletCoordFlow.State() }
}

extension RestoreWalletCoordFlow {
    @MainActor static let placeholder = StoreOf<RestoreWalletCoordFlow>(
        initialState: .initial
    ) {
        RestoreWalletCoordFlow()
    }
}

struct RecoverySeedPhraseEntryView: View {
    enum FocusTextField: Hashable {
        case field(Int)
    }

    @Environment(\.colorScheme) var colorScheme

    @PlatformBindable var store: StoreOf<RestoreWalletCoordFlow>

    @FocusState private var focusedField: FocusTextField?
    @State private var keyboardVisible: Bool = false

    init(store: StoreOf<RestoreWalletCoordFlow>) {
        self.store = store
    }

    var body: some View {
        WithPerceptionTracking {
            seedEntryLayout
                .frame(maxWidth: .infinity)
                .trackKeyboardVisibility($keyboardVisible)
                .onChange(of: keyboardVisible) { value in
                    store.send(.updateKeyboardFlag(value))
                }
                .onChange(of: focusedField) { handle in
                    if case .field(let index) = handle {
                        store.send(.selectedIndex(index))
                    }

                    if handle == nil {
                        store.send(.selectedIndex(nil))
                    }
                }
                .onChange(of: store.nextIndex) { value in
                    if let nextIndex = value {
                        focusedField = .field(nextIndex)
                    }
                }
                .onChange(of: store.isKeyboardVisible) { value in
                    if keyboardVisible && !value {
                        keyboardVisible = value
                        focusedField = nil
                    }
                }
                .applyScreenBackground()
                .zashiNavigationBarItems(
                    trailing:
                        Button {
                            store.send(.helpSheetRequested)
                        } label: {
#if os(macOS)
                            // macOS 26 sizes the glass capsule to the icon's WIDTH — a bare SF symbol is narrow
                            // → tall capsule. zashiToolbarIconPadding() widens it to circular (matches the back).
                            Image(systemName: "info.circle")
                                .zashiToolbarIconPadding()
#else
                            Asset.Assets.Icons.help.image
                                .zImage(size: 24, style: Design.Text.primary)
                                .padding(Design.Spacing.navBarButtonPadding)
#endif
                        }
                )
                .zashiBack()
                .screenTitle(String(localizable: .importWalletButtonRestoreWallet))
                // macOS seed-input hardening (S1 secure event input + S2 capture-exclusion); no-op on iOS.
                // See docs/macos/SEED_INPUT_SECURITY.md.
                .seedScreenSecurityGuard()
#if os(iOS)
                .overlay(keyboardSuggestionsBar)
#endif
        }
    }

    // Two layouts share the same word fields / chips. iOS: the grid scrolls and the suggestion bar is
    // pinned above the software keyboard (`keyboardSuggestionsBar` overlay). macOS: there is NO software
    // keyboard, so that bar would never show — instead the matches WRAP (FlowLayout) into a band BETWEEN
    // the grid and the Next CTA, visible only while there are suggestions. Rule #11: the iOS branch is the
    // original tree, untouched.
    @ViewBuilder private var seedEntryLayout: some View {
#if os(macOS)
        // No software keyboard on macOS, so the suggestions can't ride above it: they wrap (FlowLayout)
        // directly BELOW the word grid, scrolling with it. Shown from the FIRST character (matching iOS's
        // timing), but capped to 2 lines (`maxRows: 2` + `.clipped()`) so a 1–2 char prefix's many matches
        // can't flood the window — which words fit depends on width, narrowing as the user types.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    seedEntryGrid

                    if !store.suggestedWords.isEmpty {
                        FlowLayout(spacing: 8, alignment: .leading, maxRows: 2) {
                            ForEach(store.suggestedWords, id: \.self) { suggestedWord in
                                suggestionChip(suggestedWord)
                            }
                        }
                        .clipped()
                        .padding(.top, 12)
                    }
                }
                .screenHorizontalPadding()
            }
            .padding(.vertical, 1)

            nextButton
                .padding(.top, 16)
                .padding(.bottom, 24)
                .screenHorizontalPadding()
        }
#else
        ZStack {
            ScrollView {
                seedEntryGrid
                    .screenHorizontalPadding()
            }
            .padding(.vertical, 1)

            VStack {
                Spacer()

                nextButton
                    .padding(.bottom, 24)
                    .screenHorizontalPadding()
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
#endif
    }

    @ViewBuilder private var seedEntryGrid: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(localizable: .restoreWalletTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .padding(.top, 20)
                .onLongPressGesture {
#if DEBUG
                    store.send(.debugPasteSeed)
#endif
                }

            Text(localizable: .restoreWalletInfo)
                .zFont(size: 14, style: Design.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 20)

            ForEach(0..<8, id: \.self) { j in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        WithPerceptionTracking {
                            HStack(spacing: 0) {
                                Text("\(j * 3 + i + 1)")
                                    .zFont(.medium, size: 14, style: Design.Tags.tcCountFg)
                                    .frame(minWidth: 12)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 4)
                                    .background {
                                        RoundedRectangle(cornerRadius: Design.Radius._lg)
                                            .fill(Design.Tags.tcCountBg.color(colorScheme))
                                    }
                                    .padding(.trailing, 4)

                                TextField("", text: $store.words[j * 3 + i])
                                    .zFont(size: 16, style: Design.Text.primary)
                                    .disableAutocorrection(true)
#if os(iOS)
                                    .textInputAutocapitalization(.never)
#endif
                                    .focused($focusedField, equals: .field((j * 3 + i)))
#if os(iOS)
                                    .keyboardType(.alphabet)
#endif
                                    .submitLabel(.next)
                                    .onSubmit {
                                        focusedField = ((j * 3 + i) < 23)
                                        ? .field((j * 3 + i) + 1)
                                        : .field(0)
                                    }
                            }
                            .padding(6)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius._xl)
                                    .fill(
                                        focusedField == .field(j * 3 + i)
                                        ? Design.Surfaces.bgPrimary.color(colorScheme)
                                        : Design.Surfaces.bgSecondary.color(colorScheme)
                                    )
                                    .background {
                                        RoundedRectangle(cornerRadius: Design.Radius._xl)
                                            .stroke(strokeColor(index: j * 3 + i), lineWidth: 2)
                                    }
                            }
                            .padding(2)
                            .padding(.bottom, 4)
                        }
                    }
                }
            }

            if keyboardVisible {
                Color.clear
                    .frame(height: 44)
            }
        }
    }

    @ViewBuilder private var nextButton: some View {
        ZashiButton(String(localizable: .generalNext)) {
            store.send(.nextTapped)
        }
        .disabled(!store.isValidSeed)
    }

    @ViewBuilder private func suggestionChip(_ word: String) -> some View {
        Button {
            store.send(.suggestedWordTapped(word))
        } label: {
            Text(word)
                .zFont(size: 16, style: Design.Text.primary)
                .fixedSize()
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Design.Surfaces.bgSecondary.color(colorScheme))
                }
        }
    }

#if os(iOS)
    // iOS-only: suggestion bar pinned above the software keyboard (collapses to 0 height when the
    // keyboard is down). macOS surfaces suggestions inline in `seedEntryLayout` (no keyboard there).
    @ViewBuilder private var keyboardSuggestionsBar: some View {
        VStack(spacing: 0) {
            Spacer()

            Asset.Colors.primary.color
                .frame(height: 1)
                .opacity(0.1)

            HStack(alignment: .center) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(store.suggestedWords, id: \.self) { suggestedWord in
                            suggestionChip(suggestedWord)
                        }
                    }
                    .padding(.leading, 4)
                }
                .mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Design.Surfaces.bgSecondary.color(colorScheme).opacity(0.7), location: 0.9),
                            .init(color: Design.Surfaces.bgSecondary.color(colorScheme).opacity(0), location: 0.98)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 38)

                Spacer()

                Button {
                    focusedField = nil
                } label: {
                    Text(String(localizable: .generalDone).uppercased())
                        .zFont(.regular, size: 14, style: Design.Text.primary)
                }
                .padding(.trailing, 24)
                .padding(.leading, 4)
            }
            .applyScreenBackground()
            .frame(height: keyboardVisible ? 44 : 0)
            .frame(maxWidth: .infinity)
            .opacity(keyboardVisible ? 1 : 0)
        }
    }
#endif

    private func strokeColor(index: Int) -> Color {
        !store.wordsValidity[index]
        ? Design.Inputs.ErrorFilled.stroke.color(colorScheme)
        : focusedField == .field(index)
        ? Design.Text.primary.color(colorScheme)
        : Design.Surfaces.bgSecondary.color(colorScheme)
    }
}
