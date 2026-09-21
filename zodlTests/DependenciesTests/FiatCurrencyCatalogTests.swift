//
//  FiatCurrencyCatalogTests.swift
//  zodlTests
//

import Testing
@testable import zodl_internal

@Suite struct FiatCurrencyCatalogTests {
    @Test func successfulInitialLoadIsReusedByLaterLoadsAndObservers() async {
        let gate = CatalogLoadGate()
        let repository = FiatCurrencyCatalogRepository(load: { try await gate.fetch() })
        let stream = await repository.observe()
        var states = stream.makeAsyncIterator()

        #expect(await states.next() == FiatCurrencyCatalogState())

        await repository.ensureLoaded()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))

        await gate.waitUntilRequested(1)
        await gate.succeed([.usd, .eur])
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [.usd, .eur], isLoading: false, hasError: false))

        await repository.ensureLoaded()
        #expect(await gate.callCount == 1)

        let reopenedStream = await repository.observe()
        var reopenedStates = reopenedStream.makeAsyncIterator()
        #expect(await reopenedStates.next() == FiatCurrencyCatalogState(currencies: [.usd, .eur], isLoading: false, hasError: false))
        #expect(await gate.callCount == 1)
    }

    @Test func concurrentEnsureAndRefreshCallsShareOneLoad() async {
        let gate = CatalogLoadGate()
        let repository = FiatCurrencyCatalogRepository(load: { try await gate.fetch() })
        let stream = await repository.observe()
        var states = stream.makeAsyncIterator()

        #expect(await states.next() == FiatCurrencyCatalogState())

        await repository.ensureLoaded()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))

        await gate.waitUntilRequested(1)
        await repository.ensureLoaded()
        await repository.refresh()
        #expect(await gate.callCount == 1)

        await gate.succeed([.usd, .eur])
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [.usd, .eur], isLoading: false, hasError: false))
    }

    @Test func emptyInitialResultBecomesAnError() async {
        let gate = CatalogLoadGate()
        let repository = FiatCurrencyCatalogRepository(load: { try await gate.fetch() })
        let stream = await repository.observe()
        var states = stream.makeAsyncIterator()

        #expect(await states.next() == FiatCurrencyCatalogState())
        await repository.ensureLoaded()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))

        await gate.waitUntilRequested(1)
        await gate.succeed([])

        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: false, hasError: true))
        #expect(await gate.callCount == 1)
    }

    @Test func initialFailuresCanBeRetriedExplicitlyAndAfterReopening() async {
        let gate = CatalogLoadGate()
        let repository = FiatCurrencyCatalogRepository(load: { try await gate.fetch() })
        let stream = await repository.observe()
        var states = stream.makeAsyncIterator()

        #expect(await states.next() == FiatCurrencyCatalogState())
        await repository.ensureLoaded()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))
        await gate.waitUntilRequested(1)
        await gate.fail(CatalogLoadError.failed)
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: false, hasError: true))

        await repository.refresh()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))
        await gate.waitUntilRequested(2)
        await gate.fail(CatalogLoadError.failed)
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: false, hasError: true))

        let reopenedStream = await repository.observe()
        var reopenedStates = reopenedStream.makeAsyncIterator()
        #expect(await reopenedStates.next() == FiatCurrencyCatalogState(currencies: [], isLoading: false, hasError: true))

        await repository.ensureLoaded()
        #expect(await reopenedStates.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))
        await gate.waitUntilRequested(3)
        #expect(await gate.callCount == 3)
        await gate.succeed([.usd])
        #expect(await reopenedStates.next() == FiatCurrencyCatalogState(currencies: [.usd], isLoading: false, hasError: false))
    }

    @Test func successfulRefreshReplacesCachedCurrenciesInProviderOrder() async {
        let gate = CatalogLoadGate()
        let repository = FiatCurrencyCatalogRepository(load: { try await gate.fetch() })
        let stream = await repository.observe()
        var states = stream.makeAsyncIterator()

        #expect(await states.next() == FiatCurrencyCatalogState())
        await repository.ensureLoaded()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))
        await gate.waitUntilRequested(1)
        await gate.succeed([.usd, .eur])
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [.usd, .eur], isLoading: false, hasError: false))

        await repository.refresh()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [.usd, .eur], isLoading: true, hasError: false))
        await gate.waitUntilRequested(2)
        await gate.succeed([.jpy, .gbp])

        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [.jpy, .gbp], isLoading: false, hasError: false))
    }

    @Test func failedRefreshRetainsCachedCurrenciesWithoutAnError() async {
        let gate = CatalogLoadGate()
        let repository = FiatCurrencyCatalogRepository(load: { try await gate.fetch() })
        let stream = await repository.observe()
        var states = stream.makeAsyncIterator()

        #expect(await states.next() == FiatCurrencyCatalogState())
        await repository.ensureLoaded()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))
        await gate.waitUntilRequested(1)
        await gate.succeed([.usd, .eur])
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [.usd, .eur], isLoading: false, hasError: false))

        await repository.refresh()
        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [.usd, .eur], isLoading: true, hasError: false))
        await gate.waitUntilRequested(2)
        await gate.fail(CatalogLoadError.failed)

        #expect(await states.next() == FiatCurrencyCatalogState(currencies: [.usd, .eur], isLoading: false, hasError: false))
    }

    @Test func observerCancellationDoesNotCancelThePendingRepositoryLoad() async {
        let gate = CatalogLoadGate()
        let repository = FiatCurrencyCatalogRepository(load: { try await gate.fetch() })
        let observerStarted = SignalledRecords<Void>()
        let observerFinished = SignalledRecords<Void>()
        let observer = Task {
            let stream = await repository.observe()
            var states = stream.makeAsyncIterator()
            _ = await states.next()
            observerStarted.recordCall()
            await repository.ensureLoaded()
            while await states.next() != nil {}
            observerFinished.recordCall()
        }

        await observerStarted.countReached(1)
        await gate.waitUntilRequested(1)
        observer.cancel()
        await observerFinished.countReached(1)
        await observer.value

        let reopenedStream = await repository.observe()
        var reopenedStates = reopenedStream.makeAsyncIterator()
        #expect(await reopenedStates.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))

        await repository.ensureLoaded()
        #expect(await gate.callCount == 1)
        await gate.succeed([.eur, .usd])

        #expect(await reopenedStates.next() == FiatCurrencyCatalogState(currencies: [.eur, .usd], isLoading: false, hasError: false))
        #expect(await gate.callCount == 1)
    }

    @Test func newRepositoryStartsWithoutThePreviousRepositoryCache() async {
        let gate = CatalogLoadGate()
        let firstRepository = FiatCurrencyCatalogRepository(load: { try await gate.fetch() })
        let firstStream = await firstRepository.observe()
        var firstStates = firstStream.makeAsyncIterator()

        #expect(await firstStates.next() == FiatCurrencyCatalogState())
        await firstRepository.ensureLoaded()
        #expect(await firstStates.next() == FiatCurrencyCatalogState(currencies: [], isLoading: true, hasError: false))
        await gate.waitUntilRequested(1)
        await gate.succeed([.usd])
        #expect(await firstStates.next() == FiatCurrencyCatalogState(currencies: [.usd], isLoading: false, hasError: false))

        let secondRepository = FiatCurrencyCatalogRepository(load: { [.eur] })
        let secondStream = await secondRepository.observe()
        var secondStates = secondStream.makeAsyncIterator()
        #expect(await secondStates.next() == FiatCurrencyCatalogState())
    }
}

private enum CatalogLoadError: Error {
    case failed
}

private actor CatalogLoadGate {
    private(set) var callCount = 0
    private var pendingFetch: CheckedContinuation<[CurrencyISO4217], any Error>?
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func fetch() async throws -> [CurrencyISO4217] {
        callCount += 1
        let readyWaiters = requestWaiters.filter { $0.count <= callCount }
        requestWaiters.removeAll { $0.count <= callCount }
        readyWaiters.forEach { $0.continuation.resume() }

        return try await withCheckedThrowingContinuation { continuation in
            #expect(pendingFetch == nil)
            pendingFetch = continuation
        }
    }

    func waitUntilRequested(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count: count, continuation: continuation))
        }
    }

    func succeed(_ currencies: [CurrencyISO4217]) {
        let continuation = pendingFetch
        pendingFetch = nil
        #expect(continuation != nil)
        continuation?.resume(returning: currencies)
    }

    func fail(_ error: any Error) {
        let continuation = pendingFetch
        pendingFetch = nil
        #expect(continuation != nil)
        continuation?.resume(throwing: error)
    }
}
