import SwiftUI
import ComposableArchitecture

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

    @Dependency(\.pasteboard) private var pasteboard
    @FocusState private var focusedSourceField: SourceField?

    private let copyTapFeedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        WithPerceptionTracking {
            VStack(spacing: 0) {
                header
                    .padding(.vertical, 12)

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .applyScreenBackground()
            .zashiSheet(
                isPresented: addCustomChainSheetBinding,
                horizontalPadding: 0,
                dragIndicatorVisibility: .hidden
            ) {
                addCustomChainSheet
            }
            .zashiSheet(
                isPresented: editCustomChainSheetBinding,
                horizontalPadding: 0,
                dragIndicatorVisibility: .hidden
            ) {
                editCustomChainSheet
            }
            .onAppear {
                store.send(.onAppear)
            }
        }
    }

    private var sourceListHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Poll Data Source"))
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .tracking(-0.384)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "Pick a poll source, or add your own."))
                .zFont(size: 14, style: Design.Text.tertiary)
                .tracking(-0.084)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        ZStack {
            Text(String(localized: "SELECT DATA SOURCE"))
                .zFont(.semiBold, size: 16, style: Design.Text.primary)
                .textCase(.uppercase)
                .tracking(-0.176)

            HStack {
                Button {
                    store.send(.dismissTapped)
                } label: {
                    Asset.Assets.Icons.arrowNarrowLeft.image
                        .zImage(size: 20, style: Design.Text.primary)
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: Design.Radius._md)
                                .fill(Design.Btns.Ghost.bg.color(colorScheme))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Back"))

                Spacer()
            }
        }
    }

    private var defaultChainOption: some View {
        let isSelected = store.selection == .bundled
        let pair = VotingChainDisplayURL.defaultBundled

        return chainSourceCard(
            name: String(localized: "Coinholder Poll"),
            url: pair.compact,
            isDefault: true,
            isSelected: isSelected,
            selectAccessibilityLabel: String(localized: "Default data source"),
            onSelectTap: { store.send(.bundledTapped) }
        ) {
            sourceActionsMenu(fullURL: pair.full, chain: nil)
        }
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
            selectAccessibilityLabel: String(localized: "Select \(chain.name)"),
            onSelectTap: { store.send(.customChainSelected(chain.id)) }
        ) {
            sourceActionsMenu(fullURL: pair.full, chain: chain)
        }
    }

    private func chainSourceCard<MenuContent: View>(
        name: String,
        url: String,
        isDefault: Bool,
        isSelected: Bool,
        selectAccessibilityLabel: String,
        onSelectTap: @escaping () -> Void,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Button(action: onSelectTap) {
                HStack(alignment: .top, spacing: 16) {
                    selectionIndicator(isSelected: isSelected)
                        .padding(.top, 2)

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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(selectAccessibilityLabel)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            menuContent()
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
    }

    private func sourceActionsMenu(fullURL: String, chain: CustomChainEntry?) -> some View {
        Menu {
            Button {
                copyToPasteboard(fullURL)
            } label: {
                Label(String(localized: "Copy Data Source URL"), systemImage: "doc.on.doc")
            }

            if let chain {
                Button {
                    store.send(.editChainTapped(chain.id))
                } label: {
                    Label(String(localized: "Edit"), systemImage: "pencil")
                }

                Button(role: .destructive) {
                    store.send(.customChainDeleteTapped(chain.id))
                } label: {
                    Label(String(localized: "Delete"), systemImage: "trash.fill")
                }
            }
        } label: {
            Asset.Assets.Icons.dotsMenu.image
                .zImage(size: 20, style: Design.Text.primary)
                .padding(8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Source actions"))
    }

    private func defaultBadge() -> some View {
        Text(String(localized: "Default"))
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

    private func copyToPasteboard(_ string: String) {
        pasteboard.setString(string.redacted)
        copyTapFeedback.prepare()
        copyTapFeedback.impactOccurred()
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Button {
                store.send(.addCustomChainButtonTapped)
            } label: {
                HStack(spacing: 6) {
                    Asset.Assets.Icons.plus.image
                        .zImage(size: 20, style: Design.Text.primary)

                    Text(String(localized: "Add custom source"))
                        .zFont(.semiBold, size: 16, style: Design.Text.primary)
                        .tracking(-0.256)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius._xl)
                        .fill(Design.Inputs.Default.bg.color(colorScheme))
                }
            }
            .buttonStyle(.plain)

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

            VStack(alignment: .leading, spacing: 0) {
                sourceFormHeader(for: mode)

                VStack(spacing: 16) {
                    sourceTextField(
                        title: String(localized: "Title"),
                        text: isEditing ? editChainNameBinding : pendingNewChainNameBinding,
                        error: validationError(for: .title),
                        focusField: isEditing ? .editTitle : .addTitle
                    )

                    sourceTextField(
                        title: String(localized: "URL"),
                        text: isEditing ? editChainURLBinding : pendingNewChainURLBinding,
                        placeholder: String(localized: "Enter..."),
                        error: validationError(for: .url),
                        focusField: isEditing ? .editURL : .addURL,
                        isURL: true
                    )
                }
                .padding(.top, 16)

                Spacer(minLength: 24)

                VStack(spacing: 12) {
                    if isEditing {
                        ZashiButton(String(localized: "Delete"), type: .destructive1, minHeight: 48) {
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
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 52)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, minHeight: sourceFormSheetMinHeight, alignment: .top)
        .onAppear {
            focusedSourceField = isEditing ? nil : .addTitle
        }
    }

    private func sourceFormToolbar(for mode: SourceFormMode) -> some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(Color(red: 0.72, green: 0.70, blue: 0.66))
                .frame(width: 36, height: 4)
                .padding(.top, 8)

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
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Close"))

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
            .padding(.top, 24)
        }
        .padding(.horizontal, 16)
        .frame(height: 92)
        .frame(maxWidth: .infinity)
    }

    private func sourceFormHeader(for mode: SourceFormMode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: sourceFormHeaderTitle(for: mode)))
                .zFont(.semiBold, size: 24, style: Design.Text.primary)
                .tracking(-0.384)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: sourceFormBody(for: mode)))
                .zFont(size: 14, style: Design.Text.primary)
                .tracking(-0.224)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceFormToolbarTitle(for mode: SourceFormMode) -> String {
        switch mode {
        case .add: return String(localized: "ADD SOURCE")
        case .edit: return String(localized: "EDIT SOURCE")
        }
    }

    private func sourceFormHeaderTitle(for mode: SourceFormMode) -> String.LocalizationValue {
        switch mode {
        case .add: return "Add Custom Source"
        case .edit: return "Edit Custom Source"
        }
    }

    private func sourceFormBody(for mode: SourceFormMode) -> String.LocalizationValue {
        switch mode {
        case .add:
            return "Add a poll source that isn't listed by default. You'll need a valid chain URL from the provider hosting the poll."
        case .edit:
            return "Update the title or URL for this custom poll source. You'll need a valid chain URL from the provider hosting the poll."
        }
    }

    private func sourceFormSaveTitle(for mode: SourceFormMode) -> String {
        if isValidating {
            return String(localized: "Validating...")
        }
        switch mode {
        case .add:
            return String(localized: "Save")
        case .edit:
            return String(localized: "Save changes")
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
                .keyboardType(isURL ? .URL : .default)
                .textInputAutocapitalization(isURL ? .never : .words)
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
        isValidating ? String(localized: "Validating...") : String(localized: "Save changes")
    }

    private var isValidating: Bool {
        store.validationStatus == .validating
    }

    private var sourceFormSheetMinHeight: CGFloat {
        max(620, UIScreen.main.bounds.height - 62)
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
