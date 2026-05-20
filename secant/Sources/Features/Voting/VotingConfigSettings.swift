import ComposableArchitecture
import Foundation

struct CustomChainEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var url: String

    init(id: UUID = UUID(), name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

@Reducer
struct VotingConfigSettings {
    @ObservableState
    struct State: Equatable {
        enum ChainSelection: Equatable {
            case bundled
            case custom(UUID)
        }

        var selection: ChainSelection = .bundled

        var showAddChainFields: Bool = false
        var pendingNewChainName: String = ""
        var pendingNewChainURL: String = ""

        var editingChainId: UUID?
        var editChainName: String = ""
        var editChainURL: String = ""

        var validationStatus: ValidationStatus = .idle

        enum ValidationField: Equatable {
            case title
            case url
        }

        var validationField: ValidationField?

        /// Snapshot URL for the in-flight validation request (stale-result guard).
        var validationRequestURL: String?

        enum ValidationContext: Equatable {
            case none
            case addPanelNewChain
            case applySelectedCustom(UUID)
            case editChain(UUID)
        }

        var validationContext: ValidationContext = .none

        /// Empty means "use the bundled hash-pinned config".
        @Shared(.appStorage(.votingConfigOverrideURL))
        var override: String = ""

        /// JSON array of `CustomChainEntry`.
        @Shared(.appStorage(.votingCustomChains))
        var customChainsJSON: String = ""

        enum ValidationStatus: Equatable {
            case idle
            case validating
            case error(String)
        }
    }

    enum Action: Equatable {
        case onAppear
        case bundledTapped
        case customChainSelected(UUID)
        case customChainDeleteTapped(UUID)
        case addCustomChainButtonTapped
        case pendingNewChainNameChanged(String)
        case pendingNewChainURLChanged(String)
        case editChainTapped(UUID)
        case cancelChainEditTapped
        case editChainNameChanged(String)
        case editChainURLChanged(String)
        case saveTapped
        case validationFailed(String, rawURL: String)
        case validationPassed(PinnedConfigSource, rawURL: String, isDefault: Bool)
        case dismissTapped
        case delegate(Delegate)

        enum Delegate: Equatable {
            case dismiss
            case saved
        }
    }

    private enum CancelID {
        case validation
    }

    static func decodeChains(_ json: String) -> [CustomChainEntry] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([CustomChainEntry].self, from: data)) ?? []
    }

    static func encodeChains(_ chains: [CustomChainEntry]) -> String {
        guard let data = try? JSONEncoder().encode(chains),
              let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                Self.syncSelectionFromOverride(&state)
                state.validationStatus = .idle
                state.validationField = nil
                state.validationContext = .none
                state.validationRequestURL = nil
                state.showAddChainFields = false
                state.pendingNewChainName = ""
                state.pendingNewChainURL = ""
                state.editingChainId = nil
                state.editChainName = ""
                state.editChainURL = ""
                return .cancel(id: CancelID.validation)

            case .bundledTapped:
                state.selection = .bundled
                state.validationStatus = .idle
                state.validationField = nil
                state.validationContext = .none
                state.validationRequestURL = nil
                return .cancel(id: CancelID.validation)

            case .customChainSelected(let id):
                state.selection = .custom(id)
                state.validationStatus = .idle
                state.validationField = nil
                state.validationContext = .none
                state.validationRequestURL = nil
                return .cancel(id: CancelID.validation)

            case .customChainDeleteTapped(let id):
                var chains = Self.decodeChains(state.customChainsJSON)
                guard let index = chains.firstIndex(where: { $0.id == id }) else {
                    return .none
                }
                let deletedURL = chains[index].url.trimmingCharacters(in: .whitespacesAndNewlines)
                chains.remove(at: index)
                state.$customChainsJSON.withLock { $0 = Self.encodeChains(chains) }

                let overrideTrim = state.override.trimmingCharacters(in: .whitespacesAndNewlines)
                if !overrideTrim.isEmpty, overrideTrim == deletedURL {
                    state.$override.withLock { $0 = "" }
                }

                Self.syncSelectionFromOverride(&state)

                if state.editingChainId == id {
                    state.editingChainId = nil
                    state.editChainName = ""
                    state.editChainURL = ""
                }
                state.validationStatus = .idle
                state.validationField = nil
                state.validationContext = .none
                state.validationRequestURL = nil
                return .cancel(id: CancelID.validation)

            case .addCustomChainButtonTapped:
                state.editingChainId = nil
                state.editChainName = ""
                state.editChainURL = ""
                state.showAddChainFields.toggle()
                if !state.showAddChainFields {
                    state.pendingNewChainName = ""
                    state.pendingNewChainURL = ""
                }
                state.validationStatus = .idle
                state.validationField = nil
                return .cancel(id: CancelID.validation)

            case .pendingNewChainNameChanged(let name):
                state.pendingNewChainName = name
                state.validationStatus = .idle
                state.validationField = nil
                return .none

            case .pendingNewChainURLChanged(let url):
                state.pendingNewChainURL = url
                state.validationStatus = .idle
                state.validationField = nil
                return .cancel(id: CancelID.validation)

            case .editChainTapped(let id):
                let chains = Self.decodeChains(state.customChainsJSON)
                guard let chain = chains.first(where: { $0.id == id }) else {
                    return .none
                }
                state.editingChainId = id
                state.editChainName = chain.name
                state.editChainURL = chain.url
                state.showAddChainFields = false
                state.pendingNewChainName = ""
                state.pendingNewChainURL = ""
                state.validationStatus = .idle
                state.validationField = nil
                return .cancel(id: CancelID.validation)

            case .cancelChainEditTapped:
                state.editingChainId = nil
                state.editChainName = ""
                state.editChainURL = ""
                state.validationStatus = .idle
                state.validationField = nil
                return .cancel(id: CancelID.validation)

            case .editChainNameChanged(let name):
                state.editChainName = name
                state.validationStatus = .idle
                state.validationField = nil
                return .none

            case .editChainURLChanged(let url):
                state.editChainURL = url
                state.validationStatus = .idle
                state.validationField = nil
                return .cancel(id: CancelID.validation)

            case .saveTapped:
                if let editId = state.editingChainId {
                    return self.reduceSaveWhileEditing(&state, editId: editId)
                }

                if state.showAddChainFields {
                    let raw = state.pendingNewChainURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let titleError = Self.titleValidationError(state.pendingNewChainName) {
                        state.validationStatus = .error(titleError)
                        state.validationField = .title
                        return .none
                    }
                    guard !raw.isEmpty else {
                        state.validationStatus = .error(Self.invalidChainURLErrorMessage)
                        state.validationField = .url
                        return .none
                    }
                    guard let parsed = try? PinnedConfigSource.parse(raw) else {
                        state.validationStatus = .error(Self.invalidChainURLErrorMessage)
                        state.validationField = .url
                        return .none
                    }
                    if Self.isDuplicatePinnedSource(parsed, chains: Self.decodeChains(state.customChainsJSON), excludingChainId: nil) {
                        state.validationStatus = .error(Self.duplicateChainURLErrorMessage)
                        state.validationField = .url
                        return .none
                    }
                    state.validationStatus = .validating
                    state.validationField = nil
                    state.validationContext = .addPanelNewChain
                    state.validationRequestURL = raw
                    return Self.validate(raw, cancelID: CancelID.validation)
                }

                switch state.selection {
                case .bundled:
                    state.$override.withLock { $0 = "" }
                    state.validationStatus = .idle
                    state.validationField = nil
                    state.validationContext = .none
                    state.validationRequestURL = nil
                    return .merge(
                        .cancel(id: CancelID.validation),
                        .send(.delegate(.saved))
                    )

                case .custom(let id):
                    let chains = Self.decodeChains(state.customChainsJSON)
                    guard let chain = chains.first(where: { $0.id == id }) else {
                        return .none
                    }
                    let raw = chain.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else {
                        return .none
                    }
                    state.validationStatus = .validating
                    state.validationField = nil
                    state.validationContext = .applySelectedCustom(id)
                    state.validationRequestURL = raw
                    return Self.validate(raw, cancelID: CancelID.validation)
                }

            case .validationFailed(let message, let rawURL):
                guard rawURL == state.validationRequestURL else {
                    return .none
                }
                state.validationStatus = .error(message)
                state.validationField = .url
                state.validationContext = .none
                state.validationRequestURL = nil
                return .none

            case .validationPassed(_, let rawURL, let isDefault):
                guard rawURL == state.validationRequestURL else {
                    return .none
                }

                let context = state.validationContext
                state.validationStatus = .idle
                state.validationField = nil
                state.validationRequestURL = nil
                state.validationContext = .none

                if isDefault {
                    state.$override.withLock { $0 = "" }
                    state.syncSelectionAfterBundledDefaultSave()
                    state.showAddChainFields = false
                    state.pendingNewChainName = ""
                    state.pendingNewChainURL = ""
                    return .merge(
                        .cancel(id: CancelID.validation),
                        .send(.delegate(.saved))
                    )
                }

                switch context {
                case .addPanelNewChain:
                    let trimmedName = state.pendingNewChainName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedName = trimmedName.isEmpty ? String(localized: "Custom chain") : trimmedName
                    let entry = CustomChainEntry(name: resolvedName, url: rawURL)
                    var chains = Self.decodeChains(state.customChainsJSON)
                    chains.append(entry)
                    state.$customChainsJSON.withLock { $0 = Self.encodeChains(chains) }
                    state.selection = .custom(entry.id)
                    state.showAddChainFields = false
                    state.pendingNewChainName = ""
                    state.pendingNewChainURL = ""

                case .editChain(let editId):
                    var chains = Self.decodeChains(state.customChainsJSON)
                    if let idx = chains.firstIndex(where: { $0.id == editId }) {
                        chains[idx].url = rawURL
                        let trimmedName = state.editChainName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty {
                            chains[idx].name = trimmedName
                        }
                    }
                    state.$customChainsJSON.withLock { $0 = Self.encodeChains(chains) }
                    state.editingChainId = nil
                    state.editChainName = ""
                    state.editChainURL = ""

                case .applySelectedCustom, .none:
                    break
                }

                state.$override.withLock { $0 = rawURL }
                return .merge(
                    .cancel(id: CancelID.validation),
                    .send(.delegate(.saved))
                )

            case .dismissTapped:
                return .merge(
                    .cancel(id: CancelID.validation),
                    .send(.delegate(.dismiss))
                )

            case .delegate:
                return .none
            }
        }
    }

    private func reduceSaveWhileEditing(
        _ state: inout State,
        editId: UUID
    ) -> Effect<Action> {
        var chains = Self.decodeChains(state.customChainsJSON)
        guard let idx = chains.firstIndex(where: { $0.id == editId }) else {
            return .none
        }

        let trimmedURL = state.editChainURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = state.editChainName.trimmingCharacters(in: .whitespacesAndNewlines)

        if let titleError = Self.titleValidationError(trimmedName) {
            state.validationStatus = .error(titleError)
            state.validationField = .title
            return .none
        }

        guard !trimmedURL.isEmpty else {
            state.validationStatus = .error(Self.invalidChainURLErrorMessage)
            state.validationField = .url
            return .none
        }

        guard let parsed = try? PinnedConfigSource.parse(trimmedURL) else {
            state.validationStatus = .error(Self.invalidChainURLErrorMessage)
            state.validationField = .url
            return .none
        }

        if trimmedURL == chains[idx].url {
            if !trimmedName.isEmpty {
                chains[idx].name = trimmedName
            }
            state.$customChainsJSON.withLock { $0 = Self.encodeChains(chains) }
            state.editingChainId = nil
            state.editChainName = ""
            state.editChainURL = ""
            state.validationStatus = .idle
            state.validationField = nil
            return .merge(
                .cancel(id: CancelID.validation),
                .send(.delegate(.saved))
            )
        }

        if Self.isDuplicatePinnedSource(parsed, chains: chains, excludingChainId: editId) {
            state.validationStatus = .error(Self.duplicateChainURLErrorMessage)
            state.validationField = .url
            return .none
        }

        state.validationStatus = .validating
        state.validationField = nil
        state.validationContext = .editChain(editId)
        state.validationRequestURL = trimmedURL
        return Self.validate(trimmedURL, cancelID: CancelID.validation)
    }

    private static func validate(
        _ rawURL: String,
        cancelID: CancelID
    ) -> Effect<Action> {
        .run { send in
            do {
                let source = try PinnedConfigSource.parse(rawURL)
                _ = try await StaticVotingConfig.loadFromNetwork(source: source, session: .shared)
                await send(.validationPassed(
                    source,
                    rawURL: rawURL,
                    isDefault: Self.isBundledDefault(source)
                ))
            } catch {
                await send(.validationFailed(Self.message(from: error), rawURL: rawURL))
            }
        }
        .cancellable(id: cancelID, cancelInFlight: true)
    }

    private static func syncSelectionFromOverride(_ state: inout State) {
        let overrideTrim = state.override.trimmingCharacters(in: .whitespacesAndNewlines)
        let chains = Self.decodeChains(state.customChainsJSON)
        if overrideTrim.isEmpty {
            state.selection = .bundled
        } else if let entry = chains.first(where: { $0.url == overrideTrim }) {
            state.selection = .custom(entry.id)
        } else {
            state.selection = .bundled
        }
    }

    private static func isBundledDefault(_ source: PinnedConfigSource) -> Bool {
        guard let bundled = try? PinnedConfigSource.parse(StaticVotingConfig.bundledPinnedSource) else {
            return false
        }
        return source.url == bundled.url
    }

    /// User-visible error when adding or switching a chain URL that matches Default or another custom entry.
    private static var duplicateChainURLErrorMessage: String {
        String(localized: "This source URL is already added.")
    }

    private static var invalidChainURLErrorMessage: String {
        String(localized: "Please enter a valid URL (e.g. https://zodl.com/polls)")
    }

    private static var titleTooLongErrorMessage: String {
        String(localized: "Title must be 15 characters or less, including spaces.")
    }

    private static func titleValidationError(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 15 ? titleTooLongErrorMessage : nil
    }

    /// True when `source` matches the bundled default pin (same URL and checksum semantics as `PinnedConfigSource`).
    private static func matchesBundledPinnedSource(_ source: PinnedConfigSource) -> Bool {
        guard let bundled = try? PinnedConfigSource.parse(StaticVotingConfig.bundledPinnedSource) else {
            return false
        }
        return source == bundled
    }

    /// Duplicate if it matches **Default** or any saved custom chain (same `PinnedConfigSource` after parse).
    private static func isDuplicatePinnedSource(
        _ source: PinnedConfigSource,
        chains: [CustomChainEntry],
        excludingChainId: UUID?
    ) -> Bool {
        if matchesBundledPinnedSource(source) {
            return true
        }
        for chain in chains {
            if let excludingChainId, chain.id == excludingChainId {
                continue
            }
            let trimmed = chain.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let other = try? PinnedConfigSource.parse(trimmed) else { continue }
            if other == source {
                return true
            }
        }
        return false
    }

    private static func message(from error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

extension VotingConfigSettings.State {
    var chains: [CustomChainEntry] {
        VotingConfigSettings.decodeChains(customChainsJSON)
    }

    fileprivate mutating func syncSelectionAfterBundledDefaultSave() {
        let overrideTrim = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if overrideTrim.isEmpty {
            selection = .bundled
        }
    }
}
