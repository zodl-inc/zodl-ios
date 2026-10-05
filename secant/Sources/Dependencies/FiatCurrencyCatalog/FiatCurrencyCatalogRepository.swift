//
//  FiatCurrencyCatalogRepository.swift
//  Zashi
//

import Foundation

actor FiatCurrencyCatalogRepository {
    private enum ValidationError: Error {
        case noSupportedCurrencies
    }

    private let load: @Sendable () async throws -> [CurrencyISO4217]
    private var state = FiatCurrencyCatalogState()
    private var loadTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<FiatCurrencyCatalogState>.Continuation] = [:]

    init(load: @escaping @Sendable () async throws -> [CurrencyISO4217]) {
        self.load = load
    }

    func observe() -> AsyncStream<FiatCurrencyCatalogState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: FiatCurrencyCatalogState.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeObserver(id: id)
            }
        }
        continuation.yield(state)

        return stream
    }

    func ensureLoaded() {
        guard state.currencies.isEmpty, loadTask == nil else { return }
        refresh()
    }

    func refresh() {
        guard loadTask == nil else { return }

        state.isLoading = true
        state.hasError = false
        publish()

        let load = self.load
        loadTask = Task {
            let currencies: [CurrencyISO4217]?
            do {
                let loadedCurrencies = try await load()
                guard !loadedCurrencies.isEmpty else {
                    throw ValidationError.noSupportedCurrencies
                }
                currencies = loadedCurrencies
            } catch {
                currencies = nil
            }

            self.completeLoad(with: currencies)
        }
    }

    private func completeLoad(with currencies: [CurrencyISO4217]?) {
        if let currencies {
            state.currencies = currencies
        }
        state.isLoading = false
        state.hasError = state.currencies.isEmpty
        loadTask = nil
        publish()
    }

    private func publish() {
        for observer in observers.values {
            observer.yield(state)
        }
    }

    private func removeObserver(id: UUID) {
        observers[id] = nil
    }
}
