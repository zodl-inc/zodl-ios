@preconcurrency import Combine
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@preconcurrency import ZcashLightClientKit

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct CurrencyConversionLoadingTests {
    enum SDKFailure: Error {
        case failed
    }

    @Test(arguments: [false, true])
    func saveStartsQuoteBeforeSDKFinishes(torOn: Bool) async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let saved = LockIsolated<UserPreferencesStorage.ExchangeRate?>(nil)
            let requested = LockIsolated<[CurrencyISO4217]>([])
            let sdkStarted = SignalledRecords<Bool>()
            let sdkGate = ResumableGate()
            defer { sdkGate.open() }
            var initial = CurrencyConversionSetup.State(
                activeSettingsOption: .optOut,
                currentSettingsOption: .optIn,
                isSettingsView: true,
                selectedCurrency: .eur
            )
            initial.isTorOn = torOn
            let store = TestStore(initialState: initial) { CurrencyConversionSetup() } withDependencies: {
                $0.userStoredPreferences.setExchangeRate = { saved.setValue($0) }
                $0.exchangeRate.refreshExchangeRateUSD = {
                    requested.withValue { $0.append(saved.value?.currency ?? .usd) }
                }
                $0.sdkSynchronizer.exchangeRateEnabled = { enabled in
                    sdkStarted.record(enabled)
                    await sdkGate.wait()
                }
            }

            await store.send(.saveChangesTapped) {
                $0.activeSettingsOption = .optIn
            }
            #expect(requested.value == [.eur])
            await store.receive(.settingsOptionChanged(.optIn))
            await sdkStarted.countReached(1)
            #expect(sdkStarted.values == [true])
            sdkGate.open()
            await store.receive(.torInitSucceeded)
            await store.receive(.backToHomeTapped)
            await store.finish()
            #expect(requested.value == [.eur])
        }
    }

    @Test
    func leavingPendingSaveStillDisplaysQuoteOnHome() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let saved = LockIsolated<UserPreferencesStorage.ExchangeRate?>(nil)
            let sdkStarted = SignalledRecords<Void>()
            let sdkCancelled = SignalledRecords<Void>()
            let sdkFinishedCancelled = SignalledRecords<Bool>()
            let sdkGate = ResumableGate()
            defer { sdkGate.open() }
            let refreshes = LockIsolated(0)
            let rates = CurrentValueSubject<ExchangeRateClient.EchangeRateEvent, Never>(.value(nil, .usd))
            let subscribed = SignalledRecords<Void>()

            let settings = Store(initialState: Settings.State()) {
                Settings()
            } withDependencies: {
                $0.userStoredPreferences.setExchangeRate = { saved.setValue($0) }
                $0.userStoredPreferences.exchangeRate = { saved.value }
                $0.exchangeRate.refreshExchangeRateUSD = { refreshes.withValue { $0 += 1 } }
                $0.sdkSynchronizer.exchangeRateEnabled = { enabled in
                    #expect(enabled)
                    sdkStarted.recordCall()
                    await withTaskCancellationHandler {
                        await sdkGate.wait()
                    } onCancel: {
                        sdkCancelled.recordCall()
                    }
                    sdkFinishedCancelled.record(Task.isCancelled)
                }
            }

            settings.send(.currencyConversionTapped)
            guard let id = settings.state.path.ids.last else {
                Issue.record("Currency conversion settings did not open")
                return
            }
            settings.send(.path(.element(id: id, action: .currencyConversionSetup(.settingsOptionTapped(.optIn)))))
            let saveTask = settings.send(.path(.element(id: id, action: .currencyConversionSetup(.saveChangesTapped))))
            await sdkStarted.countReached(1)
            #expect(saved.value?.automatic == true)
            #expect(refreshes.value == 1)
            #expect(settings.state.path.count == 1)

            settings.send(.path(.element(id: id, action: .currencyConversionSetup(.backToHomeTapped))))
            #expect(settings.state.path.isEmpty)
            await sdkCancelled.countReached(1)
            sdkGate.open()
            await saveTask.finish()
            await sdkFinishedCancelled.countReached(1)
            #expect(sdkFinishedCancelled.values == [true])
            #expect(refreshes.value == 1)

            let balances = Store(initialState: WalletBalances.State(totalBalance: Zatoshi(100_000_000))) {
                WalletBalances()
            } withDependencies: {
                $0.mainQueue = .immediate
                $0.userStoredPreferences.exchangeRate = { saved.value }
                $0.sdkSynchronizer = .noOp
                $0.migrationManager.migrationSnapshotEvents = { _ in Empty().eraseToAnyPublisher() }
                $0.exchangeRate.exchangeRateEventStream = {
                    rates.handleEvents(receiveOutput: { _ in subscribed.recordCall() }).eraseToAnyPublisher()
                }
                $0.exchangeRate.refreshExchangeRateUSD = { refreshes.withValue { $0 += 1 } }
            }
            balances.send(.onAppear)
            await subscribed.countReached(1)
            #expect(balances.state.isExchangeRateFeatureOn)
            rates.send(.value(
                FiatCurrencyResult(date: Date(), rate: NSDecimalNumber(value: 30), state: .success),
                .usd
            ))
            await subscribed.countReached(2)
            #expect(balances.state.currencyConversion?.ratio == 30)
            #expect(!balances.state.currencyValue.isEmpty)
            balances.send(.onDisappear)
            #expect(refreshes.value == 1)
        }
    }

    @Test
    func sdkFailureDoesNotPreventInitialQuote() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let refreshes = LockIsolated(0)
            let store = TestStore(initialState: CurrencyConversionSetup.State(currentSettingsOption: .optIn)) {
                CurrencyConversionSetup()
            } withDependencies: {
                $0.userStoredPreferences.setExchangeRate = { _ in }
                $0.exchangeRate.refreshExchangeRateUSD = { refreshes.withValue { $0 += 1 } }
                $0.sdkSynchronizer.exchangeRateEnabled = { _ in throw SDKFailure.failed }
            }
            await store.send(.saveChangesTapped) { $0.activeSettingsOption = .optIn }
            #expect(refreshes.value == 1)
            await store.receive(.settingsOptionChanged(.optIn))
            await store.receive(.torInitFailed)
            await store.receive(.backToHomeTapped)
            await store.finish()
            #expect(refreshes.value == 1)
        }
    }

    @Test
    func disabledSaveClearsConversionWithoutRequestingQuote() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let saved = LockIsolated<UserPreferencesStorage.ExchangeRate?>(nil)
            let sdkValues = LockIsolated<[Bool]>([])
            let refreshes = LockIsolated(0)
            var initial = CurrencyConversionSetup.State(activeSettingsOption: .optIn, currentSettingsOption: .optOut)
            initial.$currencyConversion.withLock { $0 = CurrencyConversion(.usd, ratio: 30, timestamp: 0) }
            let store = TestStore(initialState: initial) { CurrencyConversionSetup() } withDependencies: {
                $0.userStoredPreferences.setExchangeRate = { saved.setValue($0) }
                $0.exchangeRate.refreshExchangeRateUSD = { refreshes.withValue { $0 += 1 } }
                $0.sdkSynchronizer.exchangeRateEnabled = { enabled in sdkValues.withValue { $0.append(enabled) } }
            }

            await store.send(.saveChangesTapped) { $0.activeSettingsOption = .optOut }
            await store.receive(.settingsOptionChanged(.optOut)) {
                $0.$currencyConversion.withLock { $0 = nil }
            }
            await store.receive(.backToHomeTapped)
            await store.finish()
            #expect(saved.value?.automatic == false)
            #expect(sdkValues.value == [false])
            #expect(refreshes.value == 0)
            await store.send(.torInitSucceeded)
            #expect(refreshes.value == 0)
        }
    }

    @Test
    func educationEnableStartsQuoteBeforeSDKFinishes() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let saved = LockIsolated<UserPreferencesStorage.ExchangeRate?>(nil)
            let sdkStarted = SignalledRecords<Bool>()
            let sdkGate = ResumableGate()
            defer { sdkGate.open() }
            let refreshes = LockIsolated(0)
            let store = TestStore(initialState: CurrencyConversionSetup.State(selectedCurrency: .eur)) {
                CurrencyConversionSetup()
            } withDependencies: {
                $0.userStoredPreferences.setExchangeRate = { saved.setValue($0) }
                $0.exchangeRate.refreshExchangeRateUSD = { refreshes.withValue { $0 += 1 } }
                $0.sdkSynchronizer.exchangeRateEnabled = { enabled in
                    sdkStarted.record(enabled)
                    await sdkGate.wait()
                }
            }

            await store.send(.enableTapped)
            #expect(saved.value?.automatic == true)
            #expect(saved.value?.currency == .eur)
            #expect(refreshes.value == 1)
            await sdkStarted.countReached(1)
            sdkGate.open()
            await store.receive(.torInitSucceeded)
            await store.finish()
            #expect(sdkStarted.values == [true])
            #expect(refreshes.value == 1)
        }
    }

    @Test(arguments: [false, true])
    func saveCompletionRemovesSettingsChildAfterSDKResult(fails: Bool) async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let saved = LockIsolated<UserPreferencesStorage.ExchangeRate?>(nil)
            let sdkStarted = SignalledRecords<Void>()
            let sdkGate = ResumableGate()
            defer { sdkGate.open() }
            let refreshes = LockIsolated(0)
            let settings = Store(initialState: Settings.State()) {
                Settings()
            } withDependencies: {
                $0.userStoredPreferences.setExchangeRate = { saved.setValue($0) }
                $0.userStoredPreferences.exchangeRate = { saved.value }
                $0.exchangeRate.refreshExchangeRateUSD = { refreshes.withValue { $0 += 1 } }
                $0.sdkSynchronizer.exchangeRateEnabled = { enabled in
                    #expect(enabled)
                    sdkStarted.recordCall()
                    await sdkGate.wait()
                    if fails { throw SDKFailure.failed }
                }
            }

            settings.send(.currencyConversionTapped)
            guard let id = settings.state.path.ids.last else {
                Issue.record("Currency conversion settings did not open")
                return
            }
            settings.send(.path(.element(id: id, action: .currencyConversionSetup(.settingsOptionTapped(.optIn)))))
            let saveTask = settings.send(.path(.element(id: id, action: .currencyConversionSetup(.saveChangesTapped))))
            await sdkStarted.countReached(1)
            #expect(refreshes.value == 1)
            #expect(settings.state.path.count == 1)
            sdkGate.open()
            await saveTask.finish()
            #expect(settings.state.path.isEmpty)
            #expect(refreshes.value == 1)
        }
    }

    @Test
    func manualBackRemovesSettingsChild() async {
        await withDependencies {
            $0.defaultInMemoryStorage = InMemoryStorage()
        } operation: {
            let settings = Store(initialState: Settings.State()) { Settings() }
            settings.send(.currencyConversionTapped)
            guard let id = settings.state.path.ids.last else {
                Issue.record("Currency conversion settings did not open")
                return
            }
            settings.send(.path(.element(id: id, action: .currencyConversionSetup(.backToHomeTapped))))
            #expect(settings.state.path.isEmpty)
        }
    }
}
