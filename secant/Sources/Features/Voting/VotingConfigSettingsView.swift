#if VOTING_ENABLED
import SwiftUI
import Combine
import ComposableArchitecture
import Foundation

private enum VotingChainDisplayURL {
    /// Display uses the canonical HTTPS URL (checksum query stripped). `full` is the stored string (pin preserved).
    static func compactAndFull(for raw: String) -> (compact: String, full: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pinned = try? PinnedConfigSource.parse(trimmed) else {
            return (trimmed, trimmed)
        }
        return (displayString(for: pinned.url), trimmed)
    }

    static var defaultBundled: (compact: String, full: String) {
        compactAndFull(for: StaticVotingConfig.bundledPinnedSource)
    }

    private static func displayString(for url: URL) -> String {
        guard let host = url.host else {
            return url.absoluteString
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }
}

private enum SourceFormMode {
    case add
    case edit
}

private enum SourceField: Hashable {
    case addTitle
    case addURL
    case editTitle
    case editURL
}

struct VotingConfigSettingsView: View {
    let store: StoreOf<VotingConfigSettings>

    @FocusState private var focusedSourceField: SourceField?

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        sourceListHeader

                        VStack(spacing: 8) {
                            defaultChainOption

                            ForEach(store.chains) { chain in
                                customChainRow(chain)
                            }
                        }
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .applyScreenBackground()
            .screenTitle(String(localizable: .coinVoteConfigSettingsScreenTitle))
            .zashiBack { store.send(.dismissTapped) }
#if os(macOS)
            .zashiSelectorSheet(isPresented: addCustomChainSheetBinding) {
                addCustomChainSheet
            }
            .zashiSelectorSheet(isPresented: editCustomChainSheetBinding) {
                editCustomChainSheet
            }
#else
            .sheet(isPresented: addCustomChainSheetBinding) {
                addCustomChainSheet
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
            .sheet(isPresented: editCustomChainSheetBinding) {
                editCustomChainSheet
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
#endif
            .onAppear {
                store.send(.onAppear)
            }
        }
    }

    private var sourceListHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizable: .coinVoteConfigSettingsSectionTitle)
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .tracking(-0.384)
                .fixedSize(horizontal: false, vertical: true)

            Text(localizable: .coinVoteConfigSettingsSectionSubtitle)
                .zFont(size: 14, style: Design.Text.tertiary)
                .tracking(-0.084)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var defaultChainOption: some View {
        let isSelected = store.selection == .bundled
        let pair = VotingChainDisplayURL.defaultBundled

        return chainSourceCard(
            name: String(localizable: .coinVoteConfigSettingsBundledName),
            url: pair.compact,
            isDefault: true,
            isSelected: isSelected,
            selectAccessibilityLabel: String(localizable: .coinVoteConfigSettingsAccessibilityDefault),
            onSelectTap: { store.send(.bundledTapped) },
            onContentTap: nil
        )
        .accessibilityElement(children: .contain)
    }

    private func customChainRow(_ chain: CustomChainEntry) -> some View {
        let isSelected = isCustomSelected(chain.id)
        let pair = VotingChainDisplayURL.compactAndFull(for: chain.url)

        return chainSourceCard(
            name: chain.name,
            url: pair.compact,
            isDefault: false,
            isSelected: isSelected,
            selectAccessibilityLabel: String(localizable: .coinVoteConfigSettingsAccessibilitySelectChain(chain.name)),
            onSelectTap: { store.send(.customChainSelected(chain.id)) },
            onContentTap: { store.send(.editChainTapped(chain.id)) }
        )
    }

    private func chainSourceCard(
        name: String,
        url: String,
        isDefault: Bool,
        isSelected: Bool,
        selectAccessibilityLabel: String,
        onSelectTap: @escaping () -> Void,
        onContentTap: (() -> Void)?
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: onSelectTap) {
                selectionIndicator(isSelected: isSelected)
                    .contentShape(Rectangle())
            }
            .zashiPlainButtonStyle()
            .accessibilityLabel(selectAccessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            chainSourceCardContent(
                name: name,
                url: url,
                isDefault: isDefault,
                showChevron: onContentTap != nil,
                contentTap: onContentTap ?? onSelectTap
            )
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius._2xl)
                .fill(isSelected
                    ? Design.Surfaces.bgPrimary.color(colorScheme)
                    : Design.Surfaces.bgSecondary.color(colorScheme))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Design.Radius._2xl)
                    .stroke(Design.Surfaces.bgAlt.color(colorScheme), lineWidth: 1)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Design.Radius._2xl + 2)
                    .stroke(Design.Utility.Gray._200.color(colorScheme), lineWidth: 2)
                    .padding(-2)
            }
        }
        .padding(.horizontal, 2)
    }

    /// Right-hand portion of the source card: name + url, plus an optional
    /// trailing chevron. Rows with a chevron route to the edit popover via
    /// `contentTap`; rows without a chevron fall through to selection.
    private func chainSourceCardContent(
        name: String,
        url: String,
        isDefault: Bool,
        showChevron: Bool,
        contentTap: @escaping () -> Void
    ) -> some View {
        Button(action: contentTap) {
            chainSourceCardContentRow(name: name, url: url, isDefault: isDefault, showChevron: showChevron)
                .contentShape(Rectangle())
        }
        .zashiPlainButtonStyle()
    }

    private func chainSourceCardContentRow(
        name: String,
        url: String,
        isDefault: Bool,
        showChevron: Bool
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(name)
                        .zFont(.medium, size: 16, style: Design.Text.primary)
                        .tracking(-0.256)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isDefault {
                        defaultBadge()
                    }
                }

                Text(url)
                    .zFont(size: 14, style: Design.Text.tertiary)
                    .tracking(-0.224)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showChevron {
                Asset.Assets.chevronRight.image
                    .zImage(size: 20, style: Design.Text.tertiary)
            }
        }
    }

    private func defaultBadge() -> some View {
        Text(localizable: .coinVoteConfigSettingsDefaultBadge)
            .zFont(.medium, size: 12, color: Design.Utility.Gray._700.color(colorScheme))
            .tracking(-0.072)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._sm)
                    .fill(Design.Utility.Gray._100.color(colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius._sm)
                            .stroke(Design.Utility.Gray._200.color(colorScheme), lineWidth: 1)
                    }
            }
    }

    // macOS caps the "add a custom source" affordance to ZashiButton's width (Rule #7) so it lines up
    // with the Save button below; iOS keeps it full-width (byte-identical to before).
    private var addSourceMaxWidth: CGFloat {
#if os(macOS)
        Design.Mac.maxButtonWidth
#else
        .infinity
#endif
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Button {
                store.send(.addCustomChainButtonTapped)
            } label: {
                HStack(spacing: 6) {
                    Asset.Assets.Icons.plus.image
                        .zImage(size: 20, style: Design.Text.primary)

                    Text(localizable: .coinVoteConfigSettingsAddCustomSource)
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        .tracking(-0.256)
                }
                .frame(maxWidth: addSourceMaxWidth)
                .frame(height: 48)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Design.Inputs.Default.bg.color(colorScheme))
                }
#if os(macOS)
                // Capped above to ZashiButton's macOS width (Rule #7); expand + center so it lines up with
                // the Save button below instead of stretching full-width.
                .frame(maxWidth: .infinity, alignment: .center)
#endif
            }
            .zashiPlainButtonStyle()

            ZashiButton(saveTitle) {
                store.send(.saveTapped)
            }
            .disabled(saveDisabled)
        }
    }

    private var addCustomChainSheet: some View {
        sourceFormSheet(.add)
    }

    private var editCustomChainSheet: some View {
        sourceFormSheet(.edit)
    }

    private func sourceFormSheet(_ mode: SourceFormMode) -> some View {
        let isEditing = mode == .edit

        return VStack(spacing: 0) {
            sourceFormToolbar(for: mode)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sourceFormHeader(for: mode)

                    VStack(spacing: 16) {
                        sourceTextField(
                            title: String(localizable: .coinVoteConfigSettingsTitleField),
                            text: isEditing ? editChainNameBinding : pendingNewChainNameBinding,
                            error: validationError(for: .title),
                            focusField: isEditing ? .editTitle : .addTitle
                        )

                        sourceTextField(
                            title: String(localizable: .coinVoteConfigSettingsUrlField),
                            text: isEditing ? editChainURLBinding : pendingNewChainURLBinding,
                            placeholder: String(localizable: .coinVoteConfigSettingsUrlPlaceholder),
                            error: validationError(for: .url),
                            focusField: isEditing ? .editURL : .addURL,
                            isURL: true
                        )
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 12) {
                if isEditing {
                    ZashiButton(String(localizable: .coinVoteConfigSettingsDelete), type: .destructive1, minHeight: 48) {
                        if let id = store.editingChainId {
                            store.send(.customChainDeleteTapped(id))
                        }
                    }
                }

                ZashiButton(sourceFormSaveTitle(for: mode), minHeight: 48) {
                    store.send(.saveTapped)
                }
                .disabled(saveDisabled)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if !os(macOS)
        // macOS presents this in a MacCard (Liquid Glass); a screen background would cover the glass.
        .applyScreenBackground()
#endif
        .onAppear {
            focusedSourceField = isEditing ? .editTitle : .addTitle
        }
    }

    private func sourceFormToolbar(for mode: SourceFormMode) -> some View {
        ZStack {
            HStack {
                Button {
                    switch mode {
                    case .add:
                        store.send(.addCustomChainButtonTapped)
                    case .edit:
                        store.send(.cancelChainEditTapped)
                    }
                } label: {
                    Asset.Assets.buttonCloseX.image
                        .zImage(size: 20, style: Design.Text.tertiary)
                        .frame(width: 44, height: 44)
                        .background {
                            Circle()
                                .fill(Design.Btns.Tertiary.bg.color(colorScheme))
                        }
                }
                .zashiPlainButtonStyle()
                .accessibilityLabel(String(localizable: .coinVoteConfigSettingsAccessibilityClose))

                Spacer()

                Color.clear
                    .frame(width: 44, height: 44)
            }

            Text(sourceFormToolbarTitle(for: mode))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Design.Text.primary.color(colorScheme))
                .tracking(-0.43)
                .lineLimit(1)
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }

    private func sourceFormHeader(for mode: SourceFormMode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sourceFormHeaderTitle(for: mode))
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .tracking(-0.384)
                .fixedSize(horizontal: false, vertical: true)

            Text(sourceFormBody(for: mode))
                .zFont(size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceFormToolbarTitle(for mode: SourceFormMode) -> String {
        switch mode {
        case .add: return String(localizable: .coinVoteConfigSettingsToolbarAdd)
        case .edit: return String(localizable: .coinVoteConfigSettingsToolbarEdit)
        }
    }

    private func sourceFormHeaderTitle(for mode: SourceFormMode) -> String {
        switch mode {
        case .add: return String(localizable: .coinVoteConfigSettingsHeaderAddTitle)
        case .edit: return String(localizable: .coinVoteConfigSettingsHeaderEditTitle)
        }
    }

    private func sourceFormBody(for mode: SourceFormMode) -> String {
        switch mode {
        case .add: return String(localizable: .coinVoteConfigSettingsHeaderAddBody)
        case .edit: return String(localizable: .coinVoteConfigSettingsHeaderEditBody)
        }
    }

    private func sourceFormSaveTitle(for mode: SourceFormMode) -> String {
        if isValidating {
            return String(localizable: .coinVoteConfigSettingsValidating)
        }
        switch mode {
        case .add:
            return String(localizable: .coinVoteConfigSettingsSave)
        case .edit:
            return String(localizable: .coinVoteConfigSettingsSaveChanges)
        }
    }

    private func sourceTextField(
        title: String,
        text: Binding<String>,
        placeholder: String = "",
        error: String?,
        focusField: SourceField,
        isURL: Bool = false
    ) -> some View {
        let isFocused = focusedSourceField == focusField
        let hasError = error != nil

        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.custom(FontFamily.Inter.medium.name, size: 14))
                .foregroundColor(Design.Text.primary.color(colorScheme))
                .tracking(-0.224)

            HStack(spacing: 8) {
                TextField(
                    "",
                    text: text,
                    prompt: Text(placeholder)
                        .font(.custom(FontFamily.Inter.regular.name, size: 16))
                        .foregroundColor(Design.Text.tertiary.color(colorScheme))
                )
                .font(.custom(
                    text.wrappedValue.isEmpty
                        ? FontFamily.Inter.regular.name
                        : FontFamily.Inter.medium.name,
                    size: 16
                ))
                .foregroundColor(Design.Inputs.Filled.text.color(colorScheme))
                .tracking(-0.256)
                .lineLimit(1)
                .truncationMode(.middle)
#if os(iOS)
                .keyboardType(isURL ? .URL : .default)
#endif
#if os(iOS)
                .textInputAutocapitalization(isURL ? .never : .words)
#endif
                .autocorrectionDisabled()
                .focused($focusedSourceField, equals: focusField)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius._lg)
                    .fill((isFocused || hasError)
                        ? Design.Surfaces.bgPrimary.color(colorScheme)
                        : Design.Inputs.Default.bg.color(colorScheme))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Radius._lg)
                            .stroke(sourceInputStrokeColor(hasError: hasError, isFocused: isFocused), lineWidth: 1)
                    }
                    .overlay {
                        if isFocused || hasError {
                            RoundedRectangle(cornerRadius: Design.Radius._lg + 2)
                                .stroke(sourceInputFocusRingColor(hasError: hasError), lineWidth: 2)
                                .padding(-2)
                        }
                    }
            }

            if let error {
                Text(error)
                    .zFont(size: 14, style: Design.Inputs.ErrorFilled.hint)
                    .tracking(-0.224)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceInputStrokeColor(hasError: Bool, isFocused: Bool) -> Color {
        if hasError {
            return Design.Inputs.ErrorFilled.stroke.color(colorScheme)
        }
        if isFocused {
            return Design.Inputs.Filled.text.color(colorScheme)
        }
        return .clear
    }

    private func sourceInputFocusRingColor(hasError: Bool) -> Color {
        hasError
            ? Design.Utility.ErrorRed._200.color(colorScheme)
            : Design.Utility.Gray._200.color(colorScheme)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected
                    ? Design.Checkboxes.onBg.color(colorScheme)
                    : Design.Checkboxes.offBg.color(colorScheme))
                .frame(width: 20, height: 20)

            if isSelected {
                Circle()
                    .fill(Design.Checkboxes.onFg.color(colorScheme))
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .stroke(Design.Checkboxes.offStroke.color(colorScheme), lineWidth: 1)
                    .frame(width: 20, height: 20)
            }
        }
    }

    private var pendingNewChainNameBinding: Binding<String> {
        Binding(
            get: { store.pendingNewChainName },
            set: { store.send(.pendingNewChainNameChanged($0)) }
        )
    }

    private var pendingNewChainURLBinding: Binding<String> {
        Binding(
            get: { store.pendingNewChainURL },
            set: { store.send(.pendingNewChainURLChanged($0)) }
        )
    }

    private var editChainNameBinding: Binding<String> {
        Binding(
            get: { store.editChainName },
            set: { store.send(.editChainNameChanged($0)) }
        )
    }

    private var editChainURLBinding: Binding<String> {
        Binding(
            get: { store.editChainURL },
            set: { store.send(.editChainURLChanged($0)) }
        )
    }

    private var addCustomChainSheetBinding: Binding<Bool> {
        Binding(
            get: { store.showAddChainFields },
            set: { isPresented in
                if !isPresented, store.showAddChainFields {
                    store.send(.addCustomChainButtonTapped)
                }
            }
        )
    }

    private var editCustomChainSheetBinding: Binding<Bool> {
        Binding(
            get: { store.editingChainId != nil },
            set: { isPresented in
                if !isPresented, store.editingChainId != nil {
                    store.send(.cancelChainEditTapped)
                }
            }
        )
    }

    @Environment(\.colorScheme)
    private var colorScheme

    private func isCustomSelected(_ id: UUID) -> Bool {
        if case .custom(let sid) = store.selection {
            return sid == id
        }
        return false
    }

    private func validationError(for field: VotingConfigSettings.State.ValidationField) -> String? {
        if store.validationField == field,
           case .error(let message) = store.validationStatus {
            return message
        }
        return nil
    }

    private var saveDisabled: Bool {
        isValidating
    }

    private var saveTitle: String {
        isValidating
            ? String(localizable: .coinVoteConfigSettingsValidating)
            : String(localizable: .coinVoteConfigSettingsSaveChanges)
    }

    private var isValidating: Bool {
        store.validationStatus == .validating
    }

    private var sourceFormSheetMinHeight: CGFloat {
        max(620, PlatformScreen.bounds.height - 62)
    }
}

#Preview {
    VotingConfigSettingsView(
        store: Store(
            initialState: VotingConfigSettings.State()
        ) {
            VotingConfigSettings()
        }
    )
}
#endif
