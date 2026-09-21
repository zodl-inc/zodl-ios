#if VOTING_ENABLED
import ComposableArchitecture
import Foundation
import Testing
@testable import zodl_internal
@testable @preconcurrency import ZcashLightClientKit

extension VotingSharedStateSuites {
    // Drives a TCA coordinator that touches process-global `@Shared` state (e.g.
    // `selectedWalletAccount`) and uses plain `Store`s for the async cases, so the suite is
    // serialized to match XCTest's previous serial execution — and nested under a serialized
    // parent so the parity suite, which writes the same shared values, cannot interleave with it.
    @Suite(.serialized) struct VotingCoordFlowCoordinatorTests: VotingTestSuite {
        // MARK: - Bounded, cancellable poll loading

        /// A cancelled config fetch is the voter leaving the flow, not a service that
        /// is down: the load simply stops, with no error surface behind it.
        @MainActor
        @Test func configCancellationLeavesLoadingWithoutFailureUI() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.fetchServiceConfig = { _ in
                    recorder.record("fetchServiceConfig")
                    throw CancellationError()
                }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.initialize).finish()

            #expect(recorder.events().contains("fetchServiceConfig"), "the fetch under test must have run")
            #expect(store.state.rootScreen == .loading)
            #expect(!store.state.pollsLoadError)
        }

        /// A static config the transport could not fetch is an availability answer, so
        /// it belongs on the retryable polls-list sheet rather than the blocking
        /// config-error screen.
        @MainActor
        @Test func staticConfigTransportFailureShowsRecoverablePollsError() async {
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.fetchServiceConfig = { _ in
                    throw VotingConfigError.staticConfigFetchFailed("offline")
                }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.initialize).finish()

            #expect(store.state.pollsLoadError)
            #expect(store.state.rootScreen == .pollsList)
        }

        /// A 5xx from a dynamic mirror is the same kind of answer: the mirror walk
        /// would try the next one, so the voter gets the retryable sheet.
        @MainActor
        @Test func retryableDynamicConfigFailureShowsRecoverablePollsError() async {
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.fetchServiceConfig = { _ in
                    throw VotingConfigError.dynamicConfigFetchFailed("unavailable", statusCode: 503)
                }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.initialize).finish()

            #expect(store.state.pollsLoadError)
            #expect(store.state.rootScreen == .pollsList)
        }

        /// A plain 4xx is the publisher's own answer, not an availability one, so it
        /// stays on the blocking config-error screen the voter cannot retry past.
        @MainActor
        @Test func authoritativeDynamicConfigFailureKeepsConfigError() async {
            let error = VotingConfigError.dynamicConfigFetchFailed("missing", statusCode: 404)
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.fetchServiceConfig = { _ in throw error }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.initialize).finish()

            #expect(store.state.rootScreen == .configError(error.errorDescription ?? ""))
            #expect(!store.state.pollsLoadError)
        }

        /// Config bytes that arrived and then failed to decode are authoritative too:
        /// retrying the same mirror would decode the same bytes again.
        @MainActor
        @Test func authoritativeConfigValidationFailureKeepsConfigError() async {
            let error = VotingConfigError.decodeFailed("invalid publisher config")
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.fetchServiceConfig = { _ in throw error }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.initialize).finish()

            #expect(store.state.rootScreen == .configError(error.errorDescription ?? ""))
            #expect(!store.state.pollsLoadError)
        }

        /// A cancelled rounds fetch stops the load where it stands; only a real
        /// transport failure raises the recoverable sheet.
        @MainActor
        @Test func roundCancellationLeavesLoadingWithoutFailureUI() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = {
                    recorder.record("fetchAllRounds")
                    throw CancellationError()
                }
                $0.databaseFiles = .noOp
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.serviceConfigLoaded(Self.makeServiceConfig())).finish()

            #expect(recorder.events().contains("fetchAllRounds"), "the fetch under test must have run")
            #expect(store.state.rootScreen == .loading)
            #expect(!store.state.pollsLoadError)
        }

        /// A rounds fetch the transport could not complete is the recoverable
        /// answer, not a cancellation: the voter gets the retryable sheet over the
        /// polls list rather than a loading screen that never resolves.
        @MainActor
        @Test func roundTransportFailureShowsRecoverablePollsError() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = {
                    recorder.record("fetchAllRounds")
                    throw URLError(URLError.Code.timedOut)
                }
                $0.databaseFiles = .noOp
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.serviceConfigLoaded(Self.makeServiceConfig())).finish()

            #expect(recorder.events().contains("fetchAllRounds"), "the fetch under test must have run")
            #expect(store.state.pollsLoadError)
            #expect(store.state.rootScreen == .pollsList)
        }

        /// Try Again on that sheet runs the whole load again -- the config fetch
        /// included -- and puts the loading screen back up while it does, rather
        /// than only clearing the error off a list that is still empty.
        @MainActor
        @Test func retryPollLoadingStartsInitialization() async {
            let recorder = EventRecorder()
            var state = VotingCoordFlow.State()
            state.pollsLoadError = true
            state.rootScreen = .pollsList
            let store = Store(initialState: state) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.fetchServiceConfig = { _ in
                    recorder.record("fetchServiceConfig")
                    throw CancellationError()
                }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.retryLoadRounds).finish()

            #expect(recorder.events().filter { $0 == "fetchServiceConfig" }.count == 1)
            #expect(store.state.rootScreen == .loading)
        }

        /// A freshly loaded service configuration is not just handed to the API
        /// client: it is pushed into every round session already open, so a
        /// session opened before this load and one opened after cannot disagree
        /// about where to reach the helper fleet or the vote-tree nodes.
        /// `sessionInputs` derives the very same two lists from the very same
        /// config, so this asserts against its actual output rather than a value
        /// hand-picked to match it.
        @MainActor
        @Test func serviceConfigLoadedPushesHostConfigurationToOpenSessions() async throws {
            let recorder = EventRecorder()
            let pushedOverrides = LockIsolated<VotingHostOverrides?>(nil)
            let config = Self.makeServiceConfig(
                voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")]
            )
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = {
                    recorder.record("fetchAllRounds")
                    throw CancellationError()
                }
                $0.databaseFiles = .noOp
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingCrypto.updateHostConfiguration = { overrides in
                    recorder.record("updateHostConfiguration")
                    pushedOverrides.withValue { $0 = overrides }
                }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.serviceConfigLoaded(config)).finish()

            let transport = try #require(VotingSessionTransport(serviceConfig: config))
            let expectedInputs = VotingCoordFlow.sessionInputs(
                votingSession: self.votingSession(),
                transport: transport,
                accountUUID: "11111111-1111-1111-1111-111111111111",
                walletDbPath: "/dev/null",
                anchorTreeState: Data()
            )

            #expect(recorder.events().filter { $0 == "updateHostConfiguration" }.count == 1)
            #expect(
                pushedOverrides.value == VotingHostOverrides(
                    helperUrls: expectedInputs.helperUrls,
                    voteTreeNodeUrls: expectedInputs.voteTreeNodeUrls
                )
            )
        }

        /// The endorsement fetch is bounded the same way, and a cancelled one is not
        /// a failed poll load either.
        @MainActor
        @Test func endorsementCancellationLeavesLoadingWithoutFailureUI() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.fetchZodlEndorsedRoundIds = {
                    recorder.record("fetchZodlEndorsedRoundIds")
                    throw CancellationError()
                }
                $0.votingCrypto.pendingShareRounds = { [] }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.allRoundsLoaded([])).finish()

            #expect(recorder.events().contains("fetchZodlEndorsedRoundIds"), "the fetch under test must have run")
            #expect(store.state.rootScreen == .loading)
            #expect(!store.state.pollsLoadError)
        }

        /// The same fetch failing on the transport is not a cancellation, and it
        /// is the half of poll discovery the default source cannot do without:
        /// the voter gets the retryable sheet rather than an empty list.
        @MainActor
        @Test func endorsementTransportFailureShowsRecoverablePollsError() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.fetchZodlEndorsedRoundIds = {
                    recorder.record("fetchZodlEndorsedRoundIds")
                    throw URLError(URLError.Code.cannotConnectToHost)
                }
                $0.votingCrypto.pendingShareRounds = { [] }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            await store.send(.allRoundsLoaded([])).finish()

            #expect(recorder.events().contains("fetchZodlEndorsedRoundIds"), "the fetch under test must have run")
            #expect(store.state.pollsLoadError)
            #expect(store.state.rootScreen == .pollsList)
        }

        /// A failed default-source endorsement request is part of poll discovery, so
        /// while the loading screen is up it surfaces the same recoverable sheet a
        /// failed rounds list does -- not a silent drop onto an empty list.
        @MainActor
        @Test func endorsementFailureWhileLoadingShowsRecoverablePollsError() async {
            var state = VotingCoordFlow.State()
            state.rootScreen = .loading
            let store = Store(initialState: state) { VotingCoordFlow() }

            await store.send(.zodlEndorsementsFailed).finish()

            #expect(store.state.pollsLoadError)
            #expect(store.state.rootScreen == .pollsList)
        }

        /// An endorsement failure that arrives after the list is already on screen
        /// leaves it alone: the rounds the voter can see did load.
        @MainActor
        @Test func endorsementFailurePreservesAnAlreadyVisiblePollsList() async {
            var state = VotingCoordFlow.State()
            state.rootScreen = .pollsList
            let store = Store(initialState: state) { VotingCoordFlow() }

            await store.send(.zodlEndorsementsFailed).finish()

            #expect(!store.state.pollsLoadError)
            #expect(store.state.rootScreen == .pollsList)
        }

        @Test func batchSubmissionCompletedAcceptsPartialBallotWhenDraftsAreDrained() {
            let metadata = VotingMetadataBox()
            var state = VotingCoordFlow.State()
            state.roundCache[roundId] = roundSession(
                votingWeight: 50_000_000,
                votes: [
                    1: .option(0),
                    3: .option(1)
                ]
            )

            withDependencies {
                $0.votingMetadata = votingMetadataClient(metadata)
            } operation: {
                _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                    &state,
                    roundId: roundId,
                    successCount: 2,
                    failCount: 0
                )
            }

            let session = tryUnwrap(state.roundCache[roundId])
            #expect(session.batchSubmissionStatus == .completed(successCount: 2))
            #expect(session.voteRecord?.votingWeight == 50_000_000)
            #expect(session.voteRecord?.proposalCount == 2)
            #expect(state.voteRecords[roundId]?.proposalCount == 2)
            #expect(metadata.records[roundId]?.proposalCount == 2)
            // Nothing was left out of this round, so the record says so twice
            // over: the whole eligible weight voted, and every bundle it had was
            // submitted.
            #expect(session.voteRecord?.eligibleVotingWeight == session.voteRecord?.votingWeight)
            #expect(session.voteRecord?.totalBundleCount == session.voteRecord?.submittedBundleCount)
        }

        /// A software wallet's bundle setup can be trimmed by the crate too, so
        /// the completed-round record must carry the same trim figures a
        /// Keystone wallet's does, not just log and drop them.
        @Test func batchSubmissionCompletedPersistsTrimMetadataForSoftwareWallet() {
            let metadata = VotingMetadataBox()
            var session = roundSession(
                votingWeight: 50_000_000,
                votes: [1: .option(0)]
            )
            session.eligibleVotingWeight = 50_400_000
            session.bundleCount = 2
            session.eligibleBundleCount = 5
            var state = VotingCoordFlow.State()
            state.roundCache[roundId] = session

            withDependencies {
                $0.votingMetadata = votingMetadataClient(metadata)
            } operation: {
                _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                    &state,
                    roundId: roundId,
                    successCount: 1,
                    failCount: 0
                )
            }

            let record = tryUnwrap(metadata.records[roundId])
            #expect(record.votingWeight == 50_000_000)
            #expect(record.eligibleVotingWeight == 50_400_000)
            #expect(record.submittedBundleCount == 2)
            #expect(record.totalBundleCount == 5)
        }

        @Test func batchSubmissionCompletedFailsWhenDraftsRemain() {
            var state = VotingCoordFlow.State()
            state.roundCache[roundId] = roundSession(
                drafts: [2: .option(1)],
                votes: [1: .option(0)]
            )

            _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                &state,
                roundId: roundId,
                successCount: 1,
                failCount: 0
            )

            let session = tryUnwrap(state.roundCache[roundId])
            #expect(
                session.batchSubmissionStatus == .submissionFailed(
                    error: String(localizable: .coinVoteSubmissionGenericBatchFailure),
                    submittedCount: 1,
                    totalCount: 2
                )
            )
            #expect(session.voteRecord == nil)
        }

        @Test func batchSubmissionCompletedFailsWhenVoteErrorsExist() {
            var session = roundSession(votes: [1: .option(0)])
            session.batchVoteErrors = [2: "server unavailable"]
            var state = VotingCoordFlow.State()
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                &state,
                roundId: roundId,
                successCount: 1,
                failCount: 0
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(
                updated.batchSubmissionStatus == .submissionFailed(
                    error: "server unavailable",
                    submittedCount: 1,
                    totalCount: 1
                )
            )
            #expect(updated.voteRecord == nil)
        }

        @Test func intermediateKeystoneSignatureAdvancesToNextBundle() {
            var session = roundSession()
            session.bundleCount = 2
            session.keystoneBundlesToSign = [0, 1]
            session.currentKeystoneBundleIndex = 0
            session.keystoneSigningStatus = .parsingSignature
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceKeystoneBundleSignatureStored(&state, roundId: roundId, bundleIndex: 0)

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.keystoneSignedBundles == Set([0]))
            #expect(updated.nextKeystoneBundleToSign == 1)
            #expect(updated.keystoneSigningStatus == .idle)
            #expect(updated.pendingKeystoneRequest == nil)
            #expect(isDelegationSigningTop(state))
        }

        @Test func finalKeystoneSignatureMovesToFinalizingAuthorization() {
            var session = roundSession()
            session.bundleCount = 2
            session.keystoneBundlesToSign = [0, 1]
            session.keystoneSignedBundles = [0]
            session.currentKeystoneBundleIndex = 1
            session.keystoneSigningStatus = .parsingSignature
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceKeystoneBundleSignatureStored(&state, roundId: roundId, bundleIndex: 1)

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.keystoneSignedBundles == Set([0, 1]))
            #expect(updated.nextKeystoneBundleToSign == nil)
            #expect(updated.keystoneSigningStatus == .finalizingAuthorization)
            #expect(updated.pendingKeystoneRequest == nil)
            #expect(!isDelegationSigningTop(state))
        }

        /// The kept bundles are worth what the crate said they were worth on their
        /// own signing requests — the only figures this side has for them.
        @Test func skippingRemainingKeystoneBundlesKeepsOnlySignedWeight() {
            var session = roundSession(votingWeight: 100_000_000)
            session.eligibleVotingWeight = 100_000_000
            session.bundleCount = 2
            session.keystoneSignedBundles = [0]
            session.keystoneBundleWeights = [0: 87_500_000, 1: 12_500_000]
            session.keystoneBundlesToSign = [1]
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceSkipRemainingKeystoneBundles(&state, roundId: roundId)

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.bundleCount == 1)
            #expect(updated.votingWeight == 87_500_000)
            #expect(updated.eligibleBundleCount == 2)
            #expect(updated.eligibleVotingWeight == 100_000_000)
            #expect(updated.keystoneBundlesToSign.isEmpty)
            #expect(updated.keystoneSigningStatus == .finalizingAuthorization)
            #expect(!isDelegationSigningTop(state))
        }

        /// Signed bundles that do not start at the first one are no prefix, and the
        /// crate keeps a prefix: there is nothing "use signed bundles only" can do
        /// with them, so it does nothing rather than skipping across the gap.
        @Test func skippingRemainingKeystoneBundlesIgnoresASparseSignedSet() {
            var session = roundSession(votingWeight: 150_000_000)
            session.bundleCount = 3
            session.keystoneSignedBundles = [2]
            session.keystoneBundleWeights = [2: 50_000_000]
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().reduceSkipRemainingKeystoneBundles(&state, roundId: roundId)

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.bundleCount == 3)
            #expect(updated.votingWeight == 150_000_000)
            #expect(updated.keystoneSignedBundles == Set([2]))
        }

        /// Re-entering a round resumes the loop on what the crate already holds
        /// rather than asking the device to sign those bundles again.
        @Test func restoredKeystoneSignaturesResumeAtFirstUnsignedBundle() throws {
            var session = roundSession()
            session.bundleCount = 3
            session.roundPlan = try plan(delegationBundlesNeedingSigning: [1, 2])
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .keystoneSignaturesRestored(roundId: roundId, bundleIndices: [0, 1])
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.keystoneSignedBundles == Set([0, 1]))
            #expect(updated.keystoneBundlesToSign == [2])
            #expect(updated.currentKeystoneBundleIndex == 2)
        }

        /// The same read landing after a run has already named the bundles it wants
        /// signed: it is a snapshot taken when the session opened, so it adds what
        /// the crate held and leaves the run's list alone. Replacing that list —
        /// with a plan that names no signing work, as a plan refreshed mid-loop
        /// does — stranded the loop on the bundle it was showing.
        @Test func restoredKeystoneSignaturesNeverReplaceARunsWorkList() throws {
            var session = roundSession()
            session.bundleCount = 2
            session.roundPlan = try plan()
            session.keystoneBundlesToSign = [1]
            session.currentKeystoneBundleIndex = 1
            session.keystoneSigningStatus = .awaitingSignature
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .keystoneSignaturesRestored(roundId: roundId, bundleIndices: [0])
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            #expect(updated.keystoneBundlesToSign == [1])
            #expect(updated.keystoneSignedBundles == Set([0]))
            #expect(updated.currentKeystoneBundleIndex == 1)
        }

        /// What the skip alert and the signing screen say a voter is giving up is
        /// measured against the bundles this round actually delegates. A trimmed
        /// round's eligible weight also carries the value the crate's privacy trim
        /// left out, and that value was never on any bundle the device could sign,
        /// so counting it would tell the voter they are forfeiting money the round
        /// never asked them for.
        @Test func keystoneWeightSplitMeasuresPendingAgainstTheKeptBundlesOnly() {
            var session = roundSession(votingWeight: 100_000_000)
            // The trim left 50_000_000 out of the delegation entirely: two kept
            // bundles worth 100_000_000, three dropped ones worth 50_000_000.
            session.eligibleVotingWeight = 150_000_000
            session.bundleCount = 2
            session.eligibleBundleCount = 5
            session.keystoneSignedBundles = [0]
            session.keystoneBundleWeights = [0: 60_000_000, 1: 40_000_000]

            let split = VotingCoordFlow.keystoneWeightSplit(session)

            #expect(split.signed == 60_000_000)
            #expect(split.pending == 40_000_000)
        }

        /// The untrimmed round is the one the split was written for, and it must
        /// read exactly as it always did: the eligible pair equals the live pair,
        /// so there is no dropped value to leave out.
        @Test func keystoneWeightSplitIsUnchangedForAnUntrimmedRound() {
            var session = roundSession(votingWeight: 100_000_000)
            session.eligibleVotingWeight = 100_000_000
            session.bundleCount = 2
            session.eligibleBundleCount = 2
            session.keystoneSignedBundles = [0]
            session.keystoneBundleWeights = [0: 60_000_000, 1: 40_000_000]

            let split = VotingCoordFlow.keystoneWeightSplit(session)

            #expect(split.signed == 60_000_000)
            #expect(split.pending == 40_000_000)
        }

        @Test func delegationRejectedResetsKeystoneLoopButPreservesVotes() {
            var session = roundSession(
                drafts: [2: .option(1)],
                votes: [1: .option(0)]
            )
            session.bundleCount = 2
            session.keystoneBundlesToSign = [1]
            session.keystoneSignedBundles = [0]
            session.currentKeystoneBundleIndex = 1
            session.keystoneSigningStatus = .awaitingSignature
            session.batchSubmissionStatus = .authorizing
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.pendingBatchSubmission = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .delegationRejected(roundId: roundId)
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            // The stored signature survives: leaving the screen does not undo what
            // the device has already signed.
            #expect(updated.keystoneSignedBundles == Set([0]))
            #expect(updated.keystoneBundlesToSign.isEmpty)
            #expect(updated.currentKeystoneBundleIndex == 1)
            #expect(updated.pendingKeystoneRequest == nil)
            #expect(updated.keystoneSigningStatus == .idle)
            #expect(updated.batchSubmissionStatus == .idle)
            #expect(updated.draftVotes == [2: .option(1)])
            #expect(updated.votes == [1: .option(0)])
            #expect(!state.pendingBatchSubmission)
            #expect(!isDelegationSigningTop(state))
        }

        /// A run in flight still owns `batchSubmissionStatus`: its own
        /// `.finished` handling is what will resolve it next, so a rejection
        /// racing it must not also write to the field -- two writers on one
        /// status is exactly what would reopen the CTA out from under a
        /// submission that is still going.
        @Test func rejectingWhileARunIsLiveChangesNothing() {
            var session = roundSession(
                drafts: [2: .option(1)],
                votes: [1: .option(0)]
            )
            session.bundleCount = 2
            session.keystoneBundlesToSign = [1]
            session.keystoneSignedBundles = [0]
            session.currentKeystoneBundleIndex = 1
            session.keystoneSigningStatus = .awaitingSignature
            session.batchSubmissionStatus = .submitting(currentIndex: 0, totalCount: 2, currentProposalId: 7)
            session.isSubmittingVote = true
            var state = VotingCoordFlow.State()
            state.isKeystoneUser = true
            state.pendingBatchSubmission = true
            state.path.append(.delegationSigning(DelegationSigning.State(roundId: roundId)))
            state.roundCache[roundId] = session

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .delegationRejected(roundId: roundId)
            )

            let updated = tryUnwrap(state.roundCache[roundId])
            // The duplicate-submission guard: a live run keeps the status it set.
            #expect(updated.batchSubmissionStatus == .submitting(currentIndex: 0, totalCount: 2, currentProposalId: 7))
            // The signing loop itself is still stood down and the screen is
            // still popped -- only the submission status is left alone.
            #expect(updated.keystoneSignedBundles == Set([0]))
            #expect(updated.keystoneBundlesToSign.isEmpty)
            #expect(updated.keystoneSigningStatus == .idle)
            #expect(!state.pendingBatchSubmission)
            #expect(!isDelegationSigningTop(state))
        }

        private let roundId = "round-1"

        private func roundSession(
            roundId: String? = nil,
            votingWeight: UInt64 = 0,
            drafts: [UInt32: VoteChoice] = [:],
            votes: [UInt32: VoteChoice] = [:]
        ) -> RoundSession {
            var session = RoundSession(roundId: roundId ?? self.roundId)
            session.votingWeight = votingWeight
            session.draftVotes = drafts
            session.votes = votes
            return session
        }

        private func isDelegationSigningTop(_ state: VotingCoordFlow.State) -> Bool {
            guard case .delegationSigning = state.path.last else {
                return false
            }
            return true
        }

        // MARK: - Round session flow (software wallets)

        /// Entering an active round opens exactly one session, and a plan that says
        /// the round has no bundle rows yet gets them persisted before the voter
        /// reaches the ballot.
        @MainActor
        @Test func openingARoundOpensASessionAndSetsUpBundlesWhenNeeded() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    // The first plan is the one the round is opened on -- a round
                    // with no bundle rows, which is what a first entry finds; the
                    // second is the refresh `.bundlesSetUp` asks for once the rows
                    // exist.
                    let call = recorder.recordAndCount("sessionPlan")
                    return call == 1
                        ? try self.freshRoundPlan()
                        : try self.plan(openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    return try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000)
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            #expect(recorder.events().filter { $0 == "openRoundSession" }.count == 1)
            #expect(recorder.events().filter { $0 == "setupBundles" }.count == 1)
            #expect(store.state.roundCache[self.activeRoundId]?.bundleCount == 1)
            #expect(store.state.roundCache[self.activeRoundId]?.votingWeight == 50_000_000)
        }

        /// The crate's privacy trim leaves bundles out of the delegation; the
        /// eligible pair must carry the full figure (kept + dropped) so the
        /// Confirm screen's "not included" row and the completed-round record
        /// have something to show.
        @MainActor
        @Test func aTrimmedBundleSetupRecordsWhatWasLeftOutForTheConfirmScreen() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    // Two bundle phases, agreeing with `bundleLayout`'s kept
                    // `bundleCount: 2` below -- `reduceRoundSessionOpened` derives
                    // its own `bundleCount` from `plan.delegationStatuses.count`,
                    // and a mismatch there would clobber the figure this test
                    // means to check.
                    return try self.plan(
                        needsBundleSetup: call == 1,
                        openProposals: [1, 2],
                        bundlePhases: ["prepared", "prepared"]
                    )
                }
                $0.votingCrypto.setupBundles = { _ in
                    try self.bundleLayout(
                        bundleCount: 2,
                        eligibleWeight: 50_000_000,
                        privacyTrimDroppedBundles: 3,
                        privacyTrimDroppedValueZatoshi: 400_000
                    )
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            let session = store.state.roundCache[self.activeRoundId]
            #expect(session?.bundleCount == 2)
            #expect(session?.votingWeight == 50_000_000)
            #expect(session?.eligibleBundleCount == 5)
            #expect(session?.eligibleVotingWeight == 50_400_000)
        }

        /// Without a privacy trim, the eligible pair stays equal to the live
        /// pair -- the "not included" row's trigger (`eligibleBundleCount >
        /// bundleCount`) never fires for an untrimmed setup.
        @MainActor
        @Test func anUntrimmedBundleSetupLeavesTheEligiblePairEqualToTheLivePair() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    // See the trimmed test above: keep this agreeing with
                    // `bundleLayout`'s `bundleCount: 2`.
                    return try self.plan(
                        needsBundleSetup: call == 1,
                        openProposals: [1, 2],
                        bundlePhases: ["prepared", "prepared"]
                    )
                }
                $0.votingCrypto.setupBundles = { _ in
                    try self.bundleLayout(bundleCount: 2, eligibleWeight: 50_000_000)
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            let session = store.state.roundCache[self.activeRoundId]
            #expect(session?.bundleCount == 2)
            #expect(session?.votingWeight == 50_000_000)
            #expect(session?.eligibleBundleCount == session?.bundleCount)
            #expect(session?.eligibleVotingWeight == session?.votingWeight)
        }

        /// Bundle setup runs once, when a round is first entered. Leaving the
        /// flow, saving a config source, switching accounts and restarting the app
        /// all evict `roundCache`, and with it the trim figures -- which the
        /// read-only eligibility report cannot give back, because it names no
        /// dropped-bundle count and the count is what the Confirm screen's "not
        /// included" row and the completed-round record compare against. Asking
        /// the crate to re-derive the layout of a round whose rows already exist
        /// is what restores them.
        @MainActor
        @Test func reEnteringATrimmedRoundRestoresWhatTheTrimLeftOut() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                // No bundle setup needed: the rows are already there from the
                // entry whose cache entry has since been evicted. Two bundle
                // phases, agreeing with the kept `bundleCount: 2` below.
                $0.votingCrypto.sessionPlan = { _ in
                    recorder.record("sessionPlan")
                    return try self.plan(openProposals: [1, 2], bundlePhases: ["prepared", "prepared"])
                }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    return try self.bundleLayout(
                        bundleCount: 2,
                        eligibleWeight: 50_000_000,
                        privacyTrimDroppedBundles: 3,
                        privacyTrimDroppedValueZatoshi: 400_000
                    )
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            let session = store.state.roundCache[self.activeRoundId]
            #expect(recorder.events().filter { $0 == "setupBundles" }.count == 1)
            // One plan read: the restore applies the layout and stops. Re-planning
            // here would open the round a second time, which is what keeps the
            // restore a different action from the first setup.
            #expect(recorder.events().filter { $0 == "sessionPlan" }.count == 1)
            // The live pair stays what this round delegates...
            #expect(session?.bundleCount == 2)
            #expect(session?.votingWeight == 50_000_000)
            // ...and the eligible pair carries kept plus dropped again.
            #expect(session?.eligibleBundleCount == 5)
            #expect(session?.eligibleVotingWeight == 50_400_000)
        }

        /// The point of restoring the pair: a round finished after a re-entry
        /// leaves the same receipt as one finished in the entry that set its
        /// bundles up. Without the restore the record says nothing was left out.
        @MainActor
        @Test func aRoundRestoredFromATrimmedPrefixPersistsTheTrimFigures() async {
            let recorder = EventRecorder()
            let metadata = VotingMetadataBox()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    try self.plan(openProposals: [1, 2], bundlePhases: ["prepared", "prepared"])
                }
                $0.votingCrypto.setupBundles = { _ in
                    try self.bundleLayout(
                        bundleCount: 2,
                        eligibleWeight: 50_000_000,
                        privacyTrimDroppedBundles: 3,
                        privacyTrimDroppedValueZatoshi: 400_000
                    )
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            // The round completes from the session this re-entry restored, not
            // from one built by hand: what the record carries is whatever the
            // restore actually left behind.
            var restored = tryUnwrap(store.state.roundCache[self.activeRoundId])
            restored.votes = [1: .option(0)]
            var state = VotingCoordFlow.State()
            state.roundCache[activeRoundId] = restored

            withDependencies {
                $0.votingMetadata = self.votingMetadataClient(metadata)
            } operation: {
                _ = VotingCoordFlow().reduceBatchSubmissionCompleted(
                    &state,
                    roundId: self.activeRoundId,
                    successCount: 1,
                    failCount: 0
                )
            }

            let record = tryUnwrap(metadata.records[self.activeRoundId])
            #expect(record.votingWeight == 50_000_000)
            #expect(record.eligibleVotingWeight == 50_400_000)
            #expect(record.submittedBundleCount == 2)
            #expect(record.totalBundleCount == 5)
        }

        /// A round an older build left mid-submission is display-only, and
        /// `setupBundles` writes. Re-entry must not reach it for such a round --
        /// its weight comes from the read-only report, as it always did.
        @MainActor
        @Test func reEnteringAFlaggedRoundNeverAsksTheCrateToSetUpBundles() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    try self.plan(openProposals: [1, 2], legacyInFlight: true)
                }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    return try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000)
                }
                $0.votingCrypto.eligibility = { _ in
                    recorder.record("eligibility")
                    return try self.eligibilityReport()
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.legacyRoundSheetRoundId == self.activeRoundId }

            #expect(recorder.events().filter { $0 == "setupBundles" }.isEmpty)
            #expect(recorder.events().contains("eligibility"))
            #expect(store.state.roundCache[self.activeRoundId]?.votingWeight == 50_000_000)
        }

        /// The restore is best-effort: a crate that refuses to re-derive the
        /// layout -- a prefix it can no longer reproduce, say -- must not keep the
        /// voter out of a round they can still read. The round opens on the
        /// read-only report exactly as it did before the restore existed.
        @MainActor
        @Test func aRefusedLayoutRestoreStillOpensTheRoundOnTheEligibilityReport() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    throw VotingError(kind: .other, message: "the persisted prefix cannot be reproduced")
                }
                $0.votingCrypto.eligibility = { _ in
                    recorder.record("eligibility")
                    return try self.eligibilityReport()
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            #expect(recorder.events().contains("setupBundles"))
            #expect(recorder.events().contains("eligibility"))
            #expect(store.state.roundCache[self.activeRoundId]?.votingWeight == 50_000_000)
            #expect(store.state.roundCache[self.activeRoundId]?.bundleCount == 1)
        }

        /// The trim is not the only thing that leaves bundles out: "use signed
        /// bundles only" deletes the unsigned trailing ones, and the crate reports
        /// those separately. A re-entry restores that difference the same way.
        @MainActor
        @Test func reEnteringARoundWithASkippedSuffixRestoresWhatWasSkipped() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    try self.plan(openProposals: [1, 2], bundlePhases: ["prepared", "prepared"])
                }
                $0.votingCrypto.setupBundles = { _ in
                    try self.bundleLayout(
                        bundleCount: 2,
                        eligibleWeight: 50_000_000,
                        skippedSuffixBundles: 1,
                        skippedSuffixValueZatoshi: 250_000
                    )
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            let session = store.state.roundCache[self.activeRoundId]
            #expect(session?.bundleCount == 2)
            #expect(session?.votingWeight == 50_000_000)
            #expect(session?.eligibleBundleCount == 3)
            #expect(session?.eligibleVotingWeight == 50_250_000)
        }

        /// The first entry into a round is the one that lays its bundles out, and
        /// the plan that entry reads says so only by holding no delegation
        /// statuses: a round nobody has decided on yet owes a draft, not bundle
        /// setup. The round must go through first setup -- which is what applies
        /// the layout, asks for the refreshed plan, and opens the round on it, so
        /// the ballot-time precompute has bundles to warm for.
        @MainActor
        @Test func aFirstEntryLaysTheRoundOutAndOpensOnThePlanThatFollows() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    // Call 1 is what a round with no rows answers; call 2 is the
                    // refreshed plan first setup asks for once they exist, and
                    // only that one owes delegation work.
                    let call = recorder.recordAndCount("sessionPlan")
                    return call == 1
                        ? try self.freshRoundPlan()
                        : try self.plan(openProposals: [1, 2], delegationBundlesNeedingWork: [0])
                }
                $0.votingCrypto.eligibility = { _ in
                    recorder.record("eligibility")
                    return try self.eligibilityReport()
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("precomputeDelegationProof") }

            let events = recorder.events()
            #expect(events.filter { $0 == "setupBundles" }.count == 1)
            #expect(events.filter { $0 == "sessionPlan" }.count == 2)
            // The read-only report is the re-entry fallback and has no business
            // here: this round's layout is being created, not re-derived.
            #expect(events.contains("eligibility") == false)
            #expect(self.isProposalListTop(store.state))
            #expect(store.state.roundCache[self.activeRoundId]?.bundleCount == 1)
            #expect(store.state.roundCache[self.activeRoundId]?.votingWeight == 50_000_000)
        }

        /// One attempt per entry. A plan that still reports no bundle rows after a
        /// setup answered is a disagreement with the sidecar, and the round is
        /// failed with it rather than set up again forever.
        @MainActor
        @Test func aSetupThatLeavesTheRoundWithoutBundlesFailsInsteadOfLooping() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    recorder.record("sessionPlan")
                    return try self.freshRoundPlan()
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore {
                if case .error = store.state.rootScreen { return true }
                return false
            }

            #expect(recorder.events().filter { $0 == "setupBundles" }.count == 1)
            #expect(store.state.path.isEmpty)
            #expect(store.state.checkingEligibilityRoundId == nil)
        }

        /// A wallet the crate refuses to bundle for is not an error screen: it is
        /// the polls list with the insufficient-balance sheet, so the voter can pick
        /// another round. The refusal comes back from the round's first setup, so
        /// it has to be the typed one the sheet reads -- not a layout restore's
        /// swallowed failure.
        @MainActor
        @Test func ineligibleWalletShowsIneligibleScreen() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.freshRoundPlan() }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    throw VotingError(kind: .noSpendableNotes, message: "wallet holds no spendable notes")
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.ineligibleSheet != nil }

            #expect(store.state.path.isEmpty)
            #expect(store.state.checkingEligibilityRoundId == nil)
            #expect(store.state.ineligibleSheet?.snapshotHeight == 123)
            #expect(store.state.ineligibleSheet?.reason == .noSpendableNotes)
        }

        /// A wallet that held notes but not enough of them is a different statement
        /// about the voter's own money, and the crate hands back no figure for
        /// either -- so the sheet says why this wallet is out rather than quoting a
        /// balance of zero it never had.
        @MainActor
        @Test func aWalletBelowTheDivisorIsNotToldItHeldNothing() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.freshRoundPlan() }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    throw VotingError(kind: .insufficientEligibility, message: "every bundle is below the divisor")
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.ineligibleSheet != nil }

            #expect(store.state.ineligibleSheet?.reason == .belowMinimum)
            #expect(store.state.ineligibleSheet?.minimumZatoshi == ballotDivisor)
        }

        /// A round an older build dispatched a delegation or vote for, and never saw
        /// confirmed, is not this flow's to drive: the 5.x chain lifecycle owns only
        /// submissions it reserved itself, and re-running the round would re-dispatch
        /// the same transaction with no promised outcome. The round is shown and
        /// never driven — no bundle setup, no precompute, no run — and the session
        /// opened to read the plan is given back immediately.
        @MainActor
        @Test func aRoundAnOlderBuildLeftMidSubmissionIsShownButNeverDriven() async {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                // `needsBundleSetup: true` and a bundle needing delegation work make
                // the "never fires" assertions below discriminate: without the gate
                // this plan would drive both `setupBundles` and (once a refreshed,
                // non-`needsBundleSetup` plan comes back from `reduceBundlesSetUp`)
                // `precomputeDelegationProof`. `call == 1` mirrors that refresh; the
                // gate returns before the session is ever read a second time, so a
                // gated run only ever sees `call == 1`.
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(
                        needsBundleSetup: call == 1,
                        openProposals: [1, 2],
                        delegationBundlesNeedingWork: [0],
                        legacyInFlight: true
                    )
                }
                $0.votingCrypto.setupBundles = { _ in
                    recorder.record("setupBundles")
                    return try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000)
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            // `closeRoundSession` is part of the same wait, not a follow-up assertion:
            // it fires from a `.run` effect `.legacyInFlightRound`'s handler returns
            // alongside the synchronous state change, and nothing else orders that
            // effect's completion against the state becoming visible here.
            await waitForStore {
                store.state.legacyRoundSheetRoundId == self.activeRoundId
                    && recorder.events().contains("closeRoundSession")
            }

            #expect(recorder.events().contains("setupBundles") == false)
            #expect(recorder.events().contains("runRound") == false)
            #expect(recorder.events().contains("precomputeDelegationProof") == false)
            #expect(recorder.events().contains("closeRoundSession"))
            #expect(store.state.pendingPipelineRoundId == nil)
            // The session opened only to read the plan is given back completely:
            // the round must not linger on the open list, or every share-tracking
            // route would go on reading a session the registry has already closed.
            #expect(store.state.openRoundSessionIds.contains(self.activeRoundId) == false)
        }

        /// "Got it" on the legacy-round sheet only clears the sheet: the round stays
        /// display-only, and nothing about that reopens or re-evaluates it.
        @Test func dismissLegacyRoundSheetClearsTheSheet() {
            var state = sessionFlowState()
            state.legacyRoundSheetRoundId = activeRoundId

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .dismissLegacyRoundSheet
            )

            #expect(state.legacyRoundSheetRoundId == nil)
        }

        /// The gate deregisters the round the same moment it closes its session, so
        /// the next pending-share sweep -- which opens a tracking-only session and
        /// never asks for a plan, so it never reaches the gate -- can still resume
        /// confirming shares an older build already delivered for this round.
        @MainActor
        @Test func aFlaggedRoundStillGetsItsSharesTrackedOnTheNextPendingShareSweep() async throws {
            let recorder = EventRecorder()
            let nothingToTrack = try shareTrackingReport(kind: "nothing_to_track")
            var initialState = sessionFlowState()
            initialState.walletId = Self.pendingWalletId
            initialState.serviceConfig = Self.makeServiceConfig(
                voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")],
                rounds: [self.activeRoundId: Self.roundEntry()]
            )
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    recorder.record("sessionPlan")
                    return try self.plan(needsBundleSetup: false, openProposals: [1, 2], legacyInFlight: true)
                }
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(nothingToTrack))
                        continuation.finish()
                    }
                }
            }

            // The voter opens the round; its plan is legacy-in-flight, so the gate
            // fires and gives the session back.
            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.legacyRoundSheetRoundId == self.activeRoundId }
            #expect(store.state.openRoundSessionIds.contains(self.activeRoundId) == false)

            // The sidecar still names this round as owing helper-share work --
            // exactly what the next pending-share sweep (normally driven by
            // `.initialize`) reads and acts on.
            let pending = try pendingShareRound(walletId: Self.pendingWalletId, roundId: activeRoundId)
            store.send(.pendingShareRoundsLoaded([pending]))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            // A stubbed `trackShares` succeeds no matter what it is called on, so on
            // its own `.contains("trackShares")` would not tell a fresh tracking
            // session apart from `reducePendingShareRoundsLoaded`'s "already open"
            // short-circuit quietly firing on the stale entry the bug leaves behind
            // (that branch also ends by sending `.pollShareStatus`, which also calls
            // `trackShares`). Two `openRoundSession` calls is what proves a real
            // second open happened: one for the entry the gate closed, one for this
            // sweep's fresh tracking-only session.
            #expect(recorder.events().filter { $0 == "openRoundSession" }.count == 2)
            #expect(recorder.events().contains("trackShares"))
            #expect(recorder.events().contains("setupBundles") == false)
            #expect(recorder.events().contains("precomputeDelegationProof") == false)
            #expect(recorder.events().contains("runRound") == false)
        }

        /// The gate closes the session the round was entered on, and the round's
        /// own re-arm timer was cancelled by that entry, so nothing would reopen a
        /// tracking-only session until the voter left the flow and came back.
        /// Every re-tap did it again. The gate now asks for the sweep itself, and
        /// the session it reopens never asks for a plan, so it cannot come back
        /// through the gate: one sheet, one close, tracking alive again.
        @MainActor
        @Test func aFlaggedRoundReopensItsTrackingSessionWithoutASecondSheet() async throws {
            let recorder = EventRecorder()
            let nothingToTrack = try shareTrackingReport(kind: "nothing_to_track")
            var initialState = sessionFlowState()
            initialState.walletId = Self.pendingWalletId
            // A second round the sidecar also says owes helper work, listed and
            // configured exactly like the tapped one, so the only thing that can
            // keep it out of this tap's sweep is the tap deciding it is not its
            // business.
            initialState.allRounds.append(
                RoundListItem(
                    roundNumber: 2,
                    session: votingSession(proposalCount: 2, voteEndsIn: 60, roundIdByte: 0xBB)
                )
            )
            initialState.serviceConfig = Self.makeServiceConfig(
                voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")],
                rounds: [self.activeRoundId: Self.roundEntry(), self.otherRoundId: Self.roundEntry()]
            )
            let pending = try pendingShareRound(walletId: Self.pendingWalletId, roundId: activeRoundId)
            let otherPending = try pendingShareRound(walletId: Self.pendingWalletId, roundId: otherRoundId)
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    recorder.record("sessionPlan")
                    return try self.plan(needsBundleSetup: false, openProposals: [1, 2], legacyInFlight: true)
                }
                // The sidecar still names this round as owing helper-share work,
                // which is what the sweep the gate asks for reads.
                $0.votingCrypto.pendingShareRounds = {
                    recorder.record("pendingShareRounds")
                    return [pending, otherPending]
                }
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(nothingToTrack))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            // The sweep was asked for by the gate itself, after the close: the
            // session it reopens must not be one the close is about to take away.
            let events = recorder.events()
            #expect(events.drop { $0 != "closeRoundSession" }.contains("pendingShareRounds"))
            // Two opens: the entry the gate closed, and the tracking-only session
            // the sweep put back. A round left on the open list would short-
            // circuit the sweep instead of reopening anything. A third open
            // would be the other round, which this tap must leave alone: a
            // tracking-only session binds no hotkey, and the next tap on that
            // round would take the cache-hit path onto a session that cannot
            // sign.
            #expect(events.filter { $0 == "openRoundSession" }.count == 2)
            #expect(store.state.openRoundSessionIds == [self.activeRoundId])
            // The reopened session is tracking-only: no plan is read on it, so it
            // never reaches the gate, and nothing loops. One sheet, one close.
            #expect(events.filter { $0 == "sessionPlan" }.count == 1)
            #expect(events.filter { $0 == "closeRoundSession" }.count == 1)
            #expect(store.state.legacyRoundSheetRoundId == self.activeRoundId)
            #expect(events.contains("setupBundles") == false)
            #expect(events.contains("runRound") == false)
            #expect(events.contains("precomputeDelegationProof") == false)
        }

        /// Defence in depth: if the proposal list were ever reached for a flagged
        /// round (it shouldn't be -- the round-entry gate keeps it off that path),
        /// tapping Submit must not write a ballot or ask for authentication. It
        /// routes the voter back through the same sheet the gate shows, rather than
        /// leaving the Confirm CTA spinning with no way forward.
        @MainActor
        @Test func submittingAFlaggedRoundIsRoutedToTheSheetInsteadOfWritingABallot() async {
            let recorder = EventRecorder()
            var initialState = sessionFlowState(drafts: [1: .option(0), 2: .option(1)])
            initialState.roundCache[activeRoundId]?.isLegacyInFlight = true
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.setBallotIntents = { _, intents in
                    recorder.record("setBallotIntents")
                    return try self.recordedBallotPlan(intents)
                }
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return true
                }
            }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            // See the display-only test above: `closeRoundSession` belongs in the
            // wait, not asserted right after it, since it comes from a `.run` effect
            // with nothing ordering it against the state change becoming visible.
            await waitForStore {
                store.state.legacyRoundSheetRoundId == self.activeRoundId
                    && recorder.events().contains("closeRoundSession")
            }

            #expect(recorder.events().contains("setBallotIntents") == false)
            #expect(recorder.events().contains("authenticate") == false)
        }

        /// The latch is what makes the round undriveable for the life of its
        /// cached session, so it has to hold at the starters themselves and not
        /// only at the entry that sets it. A successful authentication is the
        /// last thing before a run: with the latch up, it must leave the round
        /// exactly where it was rather than put it into "a run is driving it".
        @Test func authenticationSucceededNeverStartsARunOnAFlaggedRound() {
            var state = sessionFlowState(drafts: [1: .option(0)])
            state.checkingEligibilityRoundId = nil
            state.roundCache[activeRoundId]?.isLegacyInFlight = true
            state.roundCache[activeRoundId]?.batchSubmissionStatus = .requested

            _ = VotingCoordFlow().reduceAuthenticationSucceeded(&state, roundId: activeRoundId)

            let session = tryUnwrap(state.roundCache[activeRoundId])
            #expect(session.batchSubmissionStatus == .requested)
            #expect(!session.isSubmittingVote)
        }

        /// The same latch at the other starter. The precompute is triggered by
        /// the voter simply reaching the ballot, so it is the one that would run
        /// without any deliberate act -- and proving a delegation for a round
        /// nothing may dispatch is work that can only ever be thrown away.
        @Test func precomputeNeverWarmsAProofForAFlaggedRound() throws {
            var state = sessionFlowState()
            state.checkingEligibilityRoundId = nil
            state.roundCache[activeRoundId]?.isLegacyInFlight = true
            state.roundCache[activeRoundId]?.roundPlan = try plan(delegationBundlesNeedingWork: [0])

            _ = VotingCoordFlow().reduceMaybeStartDelegationPrecompute(&state, roundId: activeRoundId)

            let session = tryUnwrap(state.roundCache[activeRoundId])
            #expect(session.delegationPrecomputeStatus == .notStarted)
            #expect(!session.isDelegationPrecomputeInFlight)
        }

        /// The precompute runs once for the bundle that owes delegation work, and
        /// Confirm does not run it again: the run reuses the proof the crate has
        /// already persisted, so the only proving the voter waits for is the one
        /// done while they were still reading the ballot.
        @MainActor
        @Test func precomputeRunsOncePerBundleAndConfirmReusesIt() async throws {
            let recorder = EventRecorder()
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(
                        needsBundleSetup: call == 1,
                        openProposals: [1, 2],
                        delegationBundlesNeedingWork: [0]
                    )
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.precomputeDelegationProof = { _, bundleIndex in
                    recorder.record("precompute:\(bundleIndex)")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingDelegationProofEvent.finished(VotingDelegationProofStatus.generated))
                        continuation.finish()
                    }
                }
                $0.votingCrypto.setBallotIntents = { _, intents in
                    try self.recordedBallotPlan(intents, delegationBundlesNeedingWork: [0])
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    recorder.record(
                        signer == VotingDelegationSigner.software(seed: Self.walletSeed)
                            ? "runRound.software"
                            : "runRound.otherSigner"
                    )
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.precomputeStatus[0] == .generated }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            #expect(recorder.events().filter { $0.hasPrefix("precompute:") } == ["precompute:0"])
            #expect(recorder.events().filter { $0.hasPrefix("runRound") } == ["runRound.software"])
            #expect(store.state.roundCache[self.activeRoundId]?.votes == [1: .option(0), 2: .option(1)])
            #expect(store.state.roundCache[self.activeRoundId]?.draftVotes.isEmpty == true)
        }

        /// A ballot the voter left partly blank is still a complete ballot to the
        /// crate: the skipped proposals are recorded as decisions, not omitted, or
        /// the round would never plan a cast.
        @MainActor
        @Test func confirmWritesBallotIntentsIncludingSkips() async throws {
            let recorder = EventRecorder()
            let intents = LockIsolated<[VotingBallotIntent]>([])
            let report = try runReport(kind: "no_work_left", completedProposals: 1, totalProposals: 2)
            // Proposal 1 carries options 0 and 1, so choice 2 is the synthetic
            // Abstain the ballot UI offers rather than a real option.
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(2), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, recorded in
                    intents.withValue { $0 = recorded }
                    return try self.recordedBallotPlan(recorded)
                }
                $0.votingCrypto.runRound = { _, _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { intents.value.count == 2 }

            #expect(
                intents.value.sorted { $0.proposalId < $1.proposalId } == [
                    VotingBallotIntent(proposalId: 1, decision: VotingBallotDecision.skipped),
                    VotingBallotIntent(proposalId: 2, decision: VotingBallotDecision.choice(1))
                ]
            )
        }

        /// The ordinary ballot: one proposal voted on, one left blank. Recording
        /// it casts nothing, so the plan that comes back still calls the round
        /// undecided — and Confirm must read that as "nothing has been cast yet",
        /// which is what it means, rather than as a refusal. The voter is asked
        /// to authenticate once and the round is driven once.
        @MainActor
        @Test func aFreshBallotWithAChoiceAndASkipAuthenticatesOnceAndStartsOneRun() async throws {
            let recorder = EventRecorder()
            // Proposal 2 carries options 0 and 1, so choice 2 is the synthetic
            // Abstain the ballot UI offers: proposal 1 is a real choice and
            // proposal 2 is recorded as a skip.
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 1,
                totalProposals: 2,
                completedChoices: [(1, 0)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(2)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return true
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    recorder.record(
                        signer == VotingDelegationSigner.software(seed: Self.walletSeed)
                            ? "runRound.software"
                            : "runRound.otherSigner"
                    )
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            // Either terminal state ends the wait, so a Confirm that refuses the
            // ballot fails here immediately instead of timing out.
            await waitForStore {
                let status = store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus
                return status == .completed(successCount: 2) || status?.isFailureState == true
            }

            #expect(store.state.roundCache[activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2))
            #expect(recorder.events().filter { $0 == "authenticate" } == ["authenticate"])
            #expect(recorder.events().filter { $0.hasPrefix("runRound") } == ["runRound.software"])
            #expect(store.state.roundCache[activeRoundId]?.votes == [1: .option(0), 2: .option(2)])
        }

        /// The same ballot on a wallet whose key lives on the device. The gate is
        /// the plan's, not the signer's, so it has to let this one through too —
        /// and a Keystone round asks for neither a biometric prompt nor the seed,
        /// because it has no seed to read.
        @MainActor
        @Test func aFreshKeystoneBallotStartsItsRunWithoutASeedSigner() async throws {
            let recorder = EventRecorder()
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 1,
                totalProposals: 2,
                completedChoices: [(1, 0)]
            )
            let store = Store(
                initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(2)], isKeystone: true)
            ) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 1)
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return true
                }
                $0.mnemonic.toSeed = { _ in
                    recorder.record("toSeed")
                    return Self.walletSeed
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    recorder.record(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                let status = store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus
                return status == .completed(successCount: 2) || status?.isFailureState == true
            }

            #expect(store.state.roundCache[activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2))
            #expect(recorder.events().filter { $0.hasPrefix("runRound") } == ["runRound.keystoneStored"])
            #expect(!recorder.events().contains("authenticate"))
            #expect(!recorder.events().contains("toSeed"))
        }

        /// A proposal the planner still lists as open is a rostered proposal with
        /// no terminal decision against it, which is the one thing that really
        /// does make a ballot incomplete. Nothing here can complete it, so the
        /// round is refused rather than driven.
        @MainActor
        @Test func aBallotThePlannerStillCallsOpenNeverStartsARun() async throws {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(openProposals: [2]) }
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return true
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            guard
                case let .submissionFailed(_, submittedCount, totalCount) =
                    tryUnwrap(store.state.roundCache[activeRoundId]).batchSubmissionStatus
            else {
                Issue.record("expected a submission failure")
                return
            }
            #expect(submittedCount == 0)
            #expect(totalCount == 2)
            #expect(!recorder.events().contains { $0.hasPrefix("runRound") })
            #expect(!recorder.events().contains("authenticate"))
        }

        /// The other half of what the planner withholds a cast for: an intent it
        /// holds for a proposal outside the authenticated roster. The host has to
        /// clear that intent before anything can be cast, so a run would only
        /// stop on the same thing.
        @MainActor
        @Test func aBallotWithUnrosteredIntentsNeverStartsARun() async throws {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, _ in try self.plan(unrosteredIntents: [9]) }
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return true
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            #expect(!recorder.events().contains { $0.hasPrefix("runRound") })
            #expect(!recorder.events().contains("authenticate"))
        }

        /// The ballot is written before the prompt on purpose, so a voter who
        /// dismisses Face ID has a recorded ballot and no run. The CTA goes back
        /// to where it was rather than staying disabled.
        @MainActor
        @Test func aDeclinedAuthenticationStartsNoRun() async throws {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, intents in
                    recorder.record("setBallotIntents")
                    return try self.recordedBallotPlan(intents)
                }
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return false
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            let confirm = store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("authenticate") }
            await confirm.finish()

            #expect(recorder.events().filter { $0 == "setBallotIntents" } == ["setBallotIntents"])
            #expect(!recorder.events().contains { $0.hasPrefix("runRound") })
            let session = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(session.batchSubmissionStatus == .idle)
            #expect(!session.isSubmittingVote)
        }

        /// Confirm is one tap however many times it is tapped. The second tap
        /// arrives while the first is still writing the ballot, and it must add
        /// nothing: no second write, no second prompt, no second run — a second
        /// run would cancel the first one mid-flight.
        @MainActor
        @Test func aSecondConfirmWhileTheFirstIsPendingWritesNoSecondBallot() async throws {
            let recorder = EventRecorder()
            let gate = TestGate()
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.setBallotIntents = { _, intents in
                    recorder.record("setBallotIntents")
                    // Parked where the first Confirm is still writing, so the
                    // second one lands against a `.requested` round.
                    await gate.wait()
                    return try self.recordedBallotPlan(intents)
                }
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return true
                }
                $0.votingCrypto.runRound = { _, _, _ in
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("setBallotIntents") }
            #expect(store.state.roundCache[activeRoundId]?.batchSubmissionStatus == .requested)

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await gate.open()
            await waitForStore {
                let status = store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus
                return status == .completed(successCount: 2) || status?.isFailureState == true
            }

            #expect(store.state.roundCache[activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2))
            #expect(recorder.events().filter { $0 == "setBallotIntents" } == ["setBallotIntents"])
            #expect(recorder.events().filter { $0 == "authenticate" } == ["authenticate"])
            #expect(recorder.events().filter { $0 == "runRound" } == ["runRound"])
        }

        /// A submission the chain refused is terminal: the voter is told what the
        /// chain said, with the ballot counts, and not offered a silent success.
        @MainActor
        @Test func runReportChainTerminalShowsFailure() async throws {
            let recorder = EventRecorder()
            let report = try runReport(
                kind: "chain_terminal",
                completedProposals: 0,
                totalProposals: 2,
                chainOutcomeKind: "rejected",
                diagnostic: "consensus rejected the transaction"
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.runRound = { _, _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            guard
                case let .submissionFailed(error, submittedCount, totalCount) =
                    tryUnwrap(store.state.roundCache[activeRoundId]).batchSubmissionStatus
            else {
                Issue.record("expected a submission failure")
                return
            }
            #expect(error.contains("rejected"))
            #expect(submittedCount == 0)
            #expect(totalCount == 2)
        }

        /// A session that has been replaced has a new epoch, and the events still
        /// arriving from the old one describe a round state that no longer exists —
        /// so they are dropped rather than written back over newer state.
        @Test func staleEpochEventsAreIgnored() throws {
            var session = RoundSession(roundId: activeRoundId)
            session.sessionEpoch = 5
            session.bundleCount = 1
            var state = VotingCoordFlow.State()
            state.roundCache[activeRoundId] = session
            let before = state.roundCache
            let report = try runReport(kind: "no_work_left", completedProposals: 2, totalProposals: 2)

            _ = VotingCoordFlow().reduceRoundRunEvent(
                &state,
                roundId: activeRoundId,
                epoch: 4,
                event: VotingRoundRunEvent.finished(report)
            )

            #expect(state.roundCache == before)
        }

        /// A run that exhausts its own pass budget is retried, but not forever: the
        /// fourth exhausted run is a failure the voter is told about instead of a
        /// loop they cannot see.
        @MainActor
        @Test func retryLaterReRunsAtMostThreeTimes() async throws {
            let recorder = EventRecorder()
            let report = try runReport(kind: "pass_budget_exhausted", completedProposals: 0, totalProposals: 2)
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.runRound = { _, _, _ in
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            #expect(recorder.events().filter { $0 == "runRound" }.count == 4)
            #expect(store.state.roundCache[self.activeRoundId]?.runRetryCount == 3)
        }

        /// The automatic re-run is the continuation of a Confirm the voter has
        /// already authenticated, so it must not raise a second biometric sheet. An
        /// unexplained Face ID prompt seconds after a contention the voter never
        /// saw reads as an attack rather than as the app trying again.
        @MainActor
        @Test func anAutomaticRerunDoesNotAskForLocalAuthenticationAgain() async throws {
            let recorder = EventRecorder()
            let report = try runReport(kind: "pass_budget_exhausted", completedProposals: 0, totalProposals: 2)
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.localAuthentication.authenticate = {
                    recorder.record("authenticate")
                    return true
                }
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.runRound = { _, _, _ in
                    recorder.record("runRound")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus.isFailureState == true }

            // Four runs — the voter's tap and its three automatic retries — and
            // exactly one prompt, the one the voter answered.
            #expect(recorder.events().filter { $0 == "runRound" }.count == 4)
            #expect(recorder.events().filter { $0 == "authenticate" } == ["authenticate"])
        }

        /// The Confirm screen reserves the bar's first 30 % for the delegation
        /// proof, the longest thing a software wallet waits on. Nothing writes that
        /// reservation on its own, so it is folded out of the run's own progress —
        /// a bar frozen at zero while the crate proves is what this covers.
        @Test func theConfirmBarFollowsTheRunsProvingProgress() throws {
            var session = RoundSession(roundId: activeRoundId)
            session.sessionEpoch = 1
            var state = VotingCoordFlow.State()
            state.roundCache[activeRoundId] = session

            _ = VotingCoordFlow().reduceRoundRunEvent(
                &state,
                roundId: activeRoundId,
                epoch: 1,
                event: VotingRoundRunEvent.event(try driveEvent("""
                {
                    "kind": "step_progress",
                    "progress": {
                        "kind": "delegation",
                        "bundle_index": 0,
                        "delegation_progress": "proof_progress",
                        "proof_progress": 0.25
                    }
                }
                """))
            )

            #expect(tryUnwrap(state.roundCache[activeRoundId]).delegationProofStatus == .generating(progress: 0.25))

            _ = VotingCoordFlow().reduceRoundRunEvent(
                &state,
                roundId: activeRoundId,
                epoch: 1,
                event: VotingRoundRunEvent.event(
                    try driveEvent(#"{"kind": "step_progress", "progress": {"kind": "chain_outcome"}}"#)
                )
            )

            // Past proving is a finished proof: the reservation stays filled rather
            // than dropping back when the run moves on.
            #expect(tryUnwrap(state.roundCache[activeRoundId]).delegationProofStatus == .complete)
        }

        /// A proposal the voter deliberately skipped is decided, not pending: it
        /// carries no choice in the plan's completed display, so draining the
        /// ballot from the display alone would leave its draft behind and rewrite a
        /// finished round into a submission failure.
        @MainActor
        @Test func skippedDraftsAreDrainedOnCompletion() async throws {
            let recorder = EventRecorder()
            // Proposal 1 is drafted as the synthetic Abstain, so the run records it
            // as skipped and the display comes back naming only proposal 2.
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 1,
                totalProposals: 2,
                completedChoices: [(2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(2), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.runRound = { _, _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            let session = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(session.draftVotes.isEmpty)
            // The skipped proposal keeps the choice the voter drafted — the
            // synthetic Abstain — because that is what the review screens read.
            #expect(session.votes == [1: .option(2), 2: .option(1)])
            #expect(session.voteRecord?.proposalCount == 2)
        }

        /// A run that ends with only helper-share delivery left has cast the whole
        /// ballot, and its report may carry no plan at all — so the drafts have to
        /// come from the intents the host wrote rather than from a display.
        @MainActor
        @Test func aRunLeavingOnlyShareWorkStillDrainsTheBallot() async throws {
            let recorder = EventRecorder()
            let report = try runReport(kind: "background_share_work_only", completedProposals: 2, totalProposals: 2)
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in
                    let call = recorder.recordAndCount("sessionPlan")
                    return try self.plan(needsBundleSetup: call == 1, openProposals: [1, 2])
                }
                $0.votingCrypto.setupBundles = { _ in try self.bundleLayout(bundleCount: 1, eligibleWeight: 50_000_000) }
                $0.votingCrypto.runRound = { _, _, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(report))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            let session = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(session.roundPlan != nil)
            #expect(session.draftVotes.isEmpty)
            #expect(session.votes == [1: .option(0), 2: .option(1)])
        }

        // MARK: - Round session flow (Keystone wallets)

        /// A Keystone round is signed bundle by bundle against the crate: the run
        /// stops asking for signatures, each bundle's redacted PCZT comes from
        /// `keystoneSigningRequests`, the signed PCZT goes straight back through
        /// `storeKeystoneSignatures`, and the same round is then re-run reading the
        /// stored rows.
        @MainActor
        @Test func keystoneRoundCollectsSignaturesThenReruns() async throws {
            let recorder = EventRecorder()
            let signingReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            let completedReport = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.storeKeystoneSignatures = { _, signed in
                    recorder.record("storeKeystoneSignatures:\(Self.indexList(signed.map(\.bundleIndex)))")
                    return try self.keystoneBatchResult(inserted: UInt32(signed.count))
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    let call = recorder.recordAndCount(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(call == 1 ? signingReport : completedReport))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await scanKeystoneSignature(store, bundleIndex: 0)
            await scanKeystoneSignature(store, bundleIndex: 1)
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            #expect(
                recorder.events().filter { $0.hasPrefix("keystoneSigningRequests") }
                    == ["keystoneSigningRequests:0", "keystoneSigningRequests:1"]
            )
            #expect(
                recorder.events().filter { $0.hasPrefix("storeKeystoneSignatures") }
                    == ["storeKeystoneSignatures:0", "storeKeystoneSignatures:1"]
            )
            #expect(
                recorder.events().filter { $0.hasPrefix("runRound") }
                    == ["runRound.keystoneStored", "runRound.keystoneStored"]
            )
            #expect(store.state.roundCache[activeRoundId]?.votes == [1: .option(0), 2: .option(1)])
        }

        /// A signature the crate refuses — the device signed something other than
        /// the bundle on screen — stops the loop on the rejection sheet the flow
        /// already has, carrying the crate's own reason, and stores nothing.
        @MainActor
        @Test func keystoneConflictShowsRejectionSheet() async throws {
            let recorder = EventRecorder()
            let signingReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.storeKeystoneSignatures = { _, _ in
                    recorder.record("storeKeystoneSignatures")
                    throw VotingError(kind: .keystoneSignatureConflict, message: Self.keystoneConflictMessage)
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    recorder.record(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(signingReport))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await scanKeystoneSignature(store, bundleIndex: 0)
            await waitForStore { store.state.keystoneSignatureRejectionSheet != nil }

            #expect(store.state.keystoneSignatureRejectionSheet?.message == Self.keystoneConflictMessage)
            // Nothing was stored, so the bundle on screen is still the one the
            // device owes: the loop neither advances nor re-runs the round.
            #expect(store.state.roundCache[activeRoundId]?.keystoneSignedBundles.isEmpty == true)
            #expect(store.state.roundCache[activeRoundId]?.pendingKeystoneRequest?.bundleIndex == 0)
            #expect(recorder.events().filter { $0.hasPrefix("keystoneSigningRequests") } == ["keystoneSigningRequests:0"])
            #expect(recorder.events().filter { $0.hasPrefix("runRound") }.count == 1)
        }

        /// Giving up on the unsigned tail keeps only the bundles the device signed:
        /// the crate deletes the rest, and the round is re-run on what is left.
        @MainActor
        @Test func keystoneSkipRemainingDeletesBundlesAndReruns() async throws {
            let recorder = EventRecorder()
            let signingReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            let completedReport = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.storeKeystoneSignatures = { _, signed in
                    recorder.record("storeKeystoneSignatures:\(Self.indexList(signed.map(\.bundleIndex)))")
                    return try self.keystoneBatchResult(inserted: UInt32(signed.count))
                }
                $0.votingCrypto.deleteSkippedBundles = { _, keepCount in
                    recorder.record("deleteSkippedBundles:\(keepCount)")
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    let call = recorder.recordAndCount(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.finished(call == 1 ? signingReport : completedReport))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await scanKeystoneSignature(store, bundleIndex: 0)
            // The voter gives up on the second bundle once its QR is the one up.
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.pendingKeystoneRequest?.bundleIndex == 1
            }
            store.send(.skipRemainingKeystoneBundlesConfirmed(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            #expect(recorder.events().contains("deleteSkippedBundles:1"))
            #expect(recorder.events().filter { $0.hasPrefix("storeKeystoneSignatures") } == ["storeKeystoneSignatures:0"])
            #expect(
                recorder.events().filter { $0.hasPrefix("runRound") }
                    == ["runRound.keystoneStored", "runRound.keystoneStored"]
            )
            #expect(store.state.roundCache[activeRoundId]?.bundleCount == 1)
        }

        // MARK: - Leaving Keystone signing mid-loop

        /// Leaving the signing screen -- Back, before any bundle is signed --
        /// must give Confirm back a usable CTA. The run narrates a positive
        /// tally before it stops to ask for signatures, which moves
        /// `batchSubmissionStatus` to `.submitting`; the rejection has to roll
        /// that back too, not only `.authorizing`, or the bar freezes and the
        /// button never re-enables.
        @MainActor
        @Test func backingOutOfTheSigningScreenLeavesConfirmUsable() async throws {
            let recorder = EventRecorder()
            let progressEvent = try planRefreshedEvent(completedProposals: 0, totalProposals: 2)
            let signingReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            let completedReport = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.storeKeystoneSignatures = { _, signed in
                    recorder.record("storeKeystoneSignatures:\(Self.indexList(signed.map(\.bundleIndex)))")
                    return try self.keystoneBatchResult(inserted: UInt32(signed.count))
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    let call = recorder.recordAndCount(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        if call == 1 {
                            continuation.yield(VotingRoundRunEvent.event(progressEvent))
                        }
                        continuation.yield(VotingRoundRunEvent.finished(call == 1 ? signingReport : completedReport))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.pendingKeystoneRequest?.bundleIndex == 0
            }

            store.send(.delegationRejected(roundId: activeRoundId))

            let updated = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(updated.batchSubmissionStatus == .idle)
            #expect(!updated.isSubmittingVote)
            #expect(updated.draftVotes == [1: .option(0), 2: .option(1)])
            #expect(updated.votes == [:])
            #expect(!isDelegationSigningTop(store.state))

            // A second Confirm starts a new run.
            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                recorder.events().filter { $0.hasPrefix("runRound") }.count == 2
            }
        }

        /// The same recovery when the signing screen itself never got a QR to
        /// show: `keystoneSigningRequests` failing routes to the rejection
        /// sheet's own "Go Back", which sends the identical action.
        @MainActor
        @Test func aFailedSigningRequestThenGoBackLeavesConfirmUsable() async throws {
            let recorder = EventRecorder()
            let progressEvent = try planRefreshedEvent(completedProposals: 0, totalProposals: 2)
            let signingReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.keystoneSigningRequests = { _, bundleIndices in
                    recorder.record("keystoneSigningRequests:\(Self.indexList(bundleIndices))")
                    throw VotingError(kind: .busy, message: "device unreachable")
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    recorder.record(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingRoundRunEvent.event(progressEvent))
                        continuation.yield(VotingRoundRunEvent.finished(signingReport))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                guard case .failed = store.state.roundCache[self.activeRoundId]?.keystoneSigningStatus else {
                    return false
                }
                return true
            }

            store.send(.delegationRejected(roundId: activeRoundId))

            let updated = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(updated.batchSubmissionStatus == .idle)
            #expect(!updated.isSubmittingVote)
            #expect(updated.draftVotes == [1: .option(0), 2: .option(1)])
            #expect(updated.votes == [:])
            #expect(!isDelegationSigningTop(store.state))

            // A second Confirm starts a new run.
            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                recorder.events().filter { $0.hasPrefix("runRound") }.count == 2
            }
        }

        /// Backing out after one bundle is already stored keeps exactly the
        /// bookkeeping `resetKeystoneSigningLoop` says it keeps: the crate's own
        /// stored signature, so a resumed loop does not ask the device to sign
        /// bundle 0 again.
        @MainActor
        @Test func cancellingAfterOneStoredSignatureKeepsItAndTheDrafts() async throws {
            let recorder = EventRecorder()
            let progressEvent = try planRefreshedEvent(completedProposals: 0, totalProposals: 2)
            let firstSigningReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            // A re-run's own report only ever names what the crate still lacks a
            // signature for.
            let secondSigningReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [1]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.storeKeystoneSignatures = { _, signed in
                    recorder.record("storeKeystoneSignatures:\(Self.indexList(signed.map(\.bundleIndex)))")
                    return try self.keystoneBatchResult(inserted: UInt32(signed.count))
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    let call = recorder.recordAndCount(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        if call == 1 {
                            continuation.yield(VotingRoundRunEvent.event(progressEvent))
                            continuation.yield(VotingRoundRunEvent.finished(firstSigningReport))
                        } else {
                            continuation.yield(VotingRoundRunEvent.finished(secondSigningReport))
                        }
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await scanKeystoneSignature(store, bundleIndex: 0)
            // Bundle 1's QR is up next; back out before scanning it.
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.pendingKeystoneRequest?.bundleIndex == 1
            }

            store.send(.delegationRejected(roundId: activeRoundId))

            let updated = tryUnwrap(store.state.roundCache[activeRoundId])
            // Exactly what `resetKeystoneSigningLoop` preserves: the stored
            // signature and its bookkeeping survive so a resumed loop starts
            // from it.
            #expect(updated.keystoneSignedBundles == Set([0]))
            #expect(updated.keystoneBundlesToSign.isEmpty)
            #expect(updated.currentKeystoneBundleIndex == updated.resolvedKeystonePrefixCount)
            #expect(updated.pendingKeystoneRequest == nil)
            #expect(updated.keystoneSigningStatus == .idle)
            #expect(updated.batchSubmissionStatus == .idle)
            #expect(updated.draftVotes == [1: .option(0), 2: .option(1)])
            #expect(!isDelegationSigningTop(store.state))

            // Retrying Confirm asks only for the bundle still unsigned: bundle 1
            // is asked for again (its first request was abandoned along with
            // the screen the voter backed out of), but bundle 0 -- already
            // stored -- is never asked for a second time.
            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.pendingKeystoneRequest?.bundleIndex == 1
            }

            #expect(
                recorder.events().filter { $0.hasPrefix("keystoneSigningRequests") }
                    == ["keystoneSigningRequests:0", "keystoneSigningRequests:1", "keystoneSigningRequests:1"]
            )
        }

        /// Signing every bundle resumes the round exactly once: the two
        /// senders of `.keystoneAllBundlesSigned` are mutually exclusive, and a
        /// stale repeat of the action after the round has already finished on
        /// it must not drive another run.
        @MainActor
        @Test func aCompletedSigningResumesExactlyOneRun() async throws {
            let recorder = EventRecorder()
            let progressEvent = try planRefreshedEvent(completedProposals: 0, totalProposals: 2)
            let signingReport = try runReport(
                kind: "needs_delegation_signatures",
                completedProposals: 0,
                totalProposals: 2,
                bundles: [0, 1]
            )
            let completedReport = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)], isKeystone: true)) {
                VotingCoordFlow()
            } withDependencies: {
                self.keystoneDependencies(&$0, recorder: recorder, bundleCount: 2)
                $0.votingCrypto.storeKeystoneSignatures = { _, signed in
                    recorder.record("storeKeystoneSignatures:\(Self.indexList(signed.map(\.bundleIndex)))")
                    return try self.keystoneBatchResult(inserted: UInt32(signed.count))
                }
                $0.votingCrypto.runRound = { _, signer, _ in
                    let call = recorder.recordAndCount(Self.runRoundEvent(signer))
                    return AsyncThrowingStream { continuation in
                        if call == 1 {
                            continuation.yield(VotingRoundRunEvent.event(progressEvent))
                        }
                        continuation.yield(VotingRoundRunEvent.finished(call == 1 ? signingReport : completedReport))
                        continuation.finish()
                    }
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.submitAllDraftsTapped(roundId: activeRoundId))
            await scanKeystoneSignature(store, bundleIndex: 0)
            await scanKeystoneSignature(store, bundleIndex: 1)
            await waitForStore {
                store.state.roundCache[self.activeRoundId]?.batchSubmissionStatus == .completed(successCount: 2)
            }

            // Exactly one further run beyond the one that asked for signatures:
            // the two sends of `.keystoneAllBundlesSigned` in the production
            // code (`reduceStartDelegationProof`'s "nothing left to ask for"
            // branch and `reduceKeystoneBundleSignatureStored`'s "that was the
            // last one" branch) are mutually exclusive, so signing every bundle
            // drives this exactly once.
            #expect(
                recorder.events().filter { $0.hasPrefix("runRound") }
                    == ["runRound.keystoneStored", "runRound.keystoneStored"]
            )
        }

        // MARK: - Lifecycle fencing

        /// Switching wallet accounts fences every open session before the flow
        /// forgets the round: the epoch moves first, then the run is cancelled,
        /// then the session is closed. An event from the session the switch
        /// replaced describes a wallet the flow has left, so it writes nothing.
        @MainActor
        @Test func accountSwitchCancelsAndClosesSessionsAndIgnoresLateEvents() async throws {
            let recorder = EventRecorder()
            let metadata = VotingMetadataBox()
            let report = try runReport(
                kind: "no_work_left",
                completedProposals: 2,
                totalProposals: 2,
                completedChoices: [(1, 0), (2, 1)]
            )
            let store = Store(initialState: sessionFlowState(drafts: [1: .option(0), 2: .option(1)])) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingMetadata = self.votingMetadataClient(metadata)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.setOperationEpoch = { roundId, epoch in
                    recorder.record("setOperationEpoch:\(roundId):\(epoch)")
                }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
                // The switch re-initializes for the account it lands on. This test is
                // about the sessions it leaves behind, so that fetch is refused rather
                // than stubbed into a second round load.
                $0.votingAPI.fetchServiceConfig = { _ in throw TestError.votingDatabaseReadFailed }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            let openedEpoch = try #require(store.state.roundCache[activeRoundId]?.sessionEpoch)

            store.send(.walletAccountChanged(keystoneWalletAccount()))
            await waitForStore { recorder.events().contains("closeRoundSession:\(self.activeRoundId)") }

            #expect(
                recorder.events().filter { Self.isSessionLifecycleEvent($0) } == [
                    "setOperationEpoch:\(activeRoundId):\(openedEpoch + 1)",
                    "cancelRoundSession:\(activeRoundId)",
                    "closeRoundSession:\(activeRoundId)"
                ]
            )
            #expect(store.state.roundCache[activeRoundId] == nil)

            // The run that was driving the round when the account changed still has
            // its stream open, and what it reports belongs to the previous wallet.
            // Awaited to completion, so the decision and the metadata write this event
            // would have handed on have run by the time it is judged.
            await store.send(.roundRunEvent(roundId: activeRoundId, epoch: openedEpoch, event: .finished(report))).finish()

            #expect(store.state.roundCache[activeRoundId] == nil, "a late event must not resurrect the round")
            #expect(store.state.voteRecords.isEmpty)
            #expect(metadata.records.isEmpty)
        }

        /// A voter who chose Tor is never announced over a plain connection: an
        /// open the Tor route cannot serve fails the entry with Tor's own message,
        /// and nothing reopens the round on `.direct`.
        @MainActor
        @Test func torRouteUnavailableDoesNotFallBackToDirect() async {
            let recorder = EventRecorder()
            var initialState = sessionFlowState()
            initialState.$swapAPIAccess.withLock { $0 = .protected }
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.openRoundSession = { _, _, route, _ in
                    recorder.record("openRoundSession:\(route)")
                    guard route == VotingTransportRoute.tor else { return }
                    throw ZcashError.torClientUnavailable
                }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore {
                store.state.rootScreen == .error(String(localizable: .migrationFailureTorFirstRunBody))
            }

            #expect(recorder.events().filter { $0.hasPrefix("openRoundSession") } == ["openRoundSession:tor"])
            #expect(store.state.path.isEmpty)
            #expect(store.state.roundCache[activeRoundId]?.roundPlan == nil)
        }

        /// A session's transport is fixed when it is opened, so a wallet that turns Tor
        /// on mid-round has to lose the sessions it has: they are fenced and closed, and
        /// the next entry into the round opens on the route the wallet asks for now. The
        /// wallet re-announcing the route it already had is not that, and does nothing.
        @MainActor
        @Test func routeChangeClosesOpenSessionsAndReopensOnTheNewRoute() async throws {
            let recorder = EventRecorder()
            var initialState = sessionFlowState()
            let swapAPIAccess = initialState.$swapAPIAccess
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.openRoundSession = { _, _, route, epoch in
                    recorder.record("openRoundSession:\(route):\(epoch)")
                }
                $0.votingCrypto.setOperationEpoch = { roundId, epoch in
                    recorder.record("setOperationEpoch:\(roundId):\(epoch)")
                }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            #expect(store.state.roundCache[activeRoundId]?.sessionEpoch == 1)

            // Announced again with the value it already had — which the shared value also
            // does to every new subscriber — and then really changed. Both reach the same
            // subscriber in this order, so the single triple below is what says the first
            // one did nothing.
            swapAPIAccess.withLock { $0 = .direct }
            swapAPIAccess.withLock { $0 = .protected }
            await waitForStore { recorder.events().contains("closeRoundSession:\(self.activeRoundId)") }

            #expect(
                recorder.events().filter { Self.isSessionLifecycleEvent($0) } == [
                    "setOperationEpoch:\(activeRoundId):2",
                    "cancelRoundSession:\(activeRoundId)",
                    "closeRoundSession:\(activeRoundId)"
                ]
            )

            // Re-entering the round is the "next use" that opens on the new route.
            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("openRoundSession:tor:3") }

            #expect(
                recorder.events().filter { $0.hasPrefix("openRoundSession") }
                    == ["openRoundSession:direct:1", "openRoundSession:tor:3"]
            )
            #expect(store.state.roundCache[activeRoundId]?.sessionEpoch == 3)
        }

        /// A fence keeps the round's cache and takes its session away, so a warm
        /// cache is no longer proof there is anything to act on. Tapping the round
        /// again is the voter's only recovery — the flow is still open, so nothing
        /// clears the cache — and it has to open a session rather than walk past
        /// the open into a Confirm the SDK answers `notOpen`.
        @MainActor
        @Test func tappingAFencedRoundOpensASessionAgain() async throws {
            let recorder = EventRecorder()
            let initialState = sessionFlowState()
            let swapAPIAccess = initialState.$swapAPIAccess
            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.roundPlan = { _, _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.openRoundSession = { _, _, route, epoch in
                    recorder.record("openRoundSession:\(route):\(epoch)")
                }
                $0.votingCrypto.setOperationEpoch = { _, _ in }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            #expect(store.state.openRoundSessionIds == [activeRoundId])

            // With the session open the cache hit is a real one, and re-tapping
            // opens nothing — which is the whole point of the fast path.
            store.send(.roundTapped(activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }
            #expect(recorder.events().filter { $0.hasPrefix("openRoundSession") } == ["openRoundSession:direct:1"])

            // The fence. `roundCache` is deliberately kept, so the round goes on
            // carrying a bound hotkey and its bundles.
            swapAPIAccess.withLock { $0 = .protected }
            await waitForStore { store.state.openRoundSessionIds.isEmpty }
            let fenced = tryUnwrap(store.state.roundCache[activeRoundId])
            #expect(fenced.hotkeyAddress != nil)
            #expect(fenced.bundleCount > 0)

            store.send(.roundTapped(activeRoundId))
            await waitForStore { recorder.events().contains("openRoundSession:tor:3") }

            #expect(store.state.openRoundSessionIds == [activeRoundId])
        }

        /// A wallet reset deletes `voting.sqlite3` while this flow's effects may still be
        /// in flight, and nothing cancels them for it: Root composes the voting flow under
        /// a case-filtered scope, so no presentation reducer runs on that path, and
        /// cancellation would not reach a `.run` already suspended inside a call anyway. A
        /// config load parked in its fetch must therefore refuse to reopen the database the
        /// reset has just closed and deleted — and must be free to open it again after.
        @MainActor
        @Test func aWalletTeardownStopsAConfigLoadFromReopeningTheSidecar() async throws {
            let recorder = EventRecorder()
            let gate = TestGate()
            let documents = try Self.temporaryDocumentsDirectory()
            defer { try? FileManager.default.removeItem(at: documents) }
            let sidecar = documents.appendingPathComponent(VotingCoordFlow.votingSidecarFileName)
            try Data([0x01]).write(to: sidecar)

            let teardownGate = VotingTeardown()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                self.teardownDependencies(&$0, gate: teardownGate)
                $0.databaseFiles.documentsDirectory = { documents }
                $0.votingAPI.configureURLs = { _ in
                    // The first load parks where a real one waits on the network, so the
                    // reset lands while it is in flight.
                    if recorder.recordAndCount("configureURLs") == 1 {
                        await gate.wait()
                    }
                }
                $0.votingAPI.fetchAllRounds = { [] }
                $0.votingAPI.fetchZodlEndorsedRoundIds = { [] }
                $0.votingAPI.startHealthProbeSweep = { }
                $0.votingCrypto.openDatabase = { path, _ in
                    recorder.record("openDatabase")
                    // What the real one does, and the whole problem: the file is back.
                    try? Data([0x02]).write(to: URL(fileURLWithPath: path))
                }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingCrypto.pendingShareRounds = { [] }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { recorder.events().contains("configureURLs") }
            #expect(store.state.hasConfiguredProving, "the load under test must have started")

            // Root's side of a reset: the drain, then the delete, with the window that
            // refuses an open in between held for the whole of it.
            var userStoredPreferences = UserPreferencesStorageClient()
            userStoredPreferences.removeAll = { }
            await withDependencies {
                // The same gate the store's effects ask, which is what the app has: the live
                // client holds one, and everything that opens or tears down goes through it.
                self.teardownDependencies(&$0, gate: teardownGate)
                $0.databaseFiles.documentsDirectory = { documents }
            } operation: {
                await Root.clearDeviceScopedWalletState(
                    userDefaults: .noOp,
                    flexaHandler: .noOp,
                    userStoredPreferences: userStoredPreferences,
                    readTransactionsStorage: .noOp,
                    closeVotingDatabase: { recorder.record("closeVotingDatabase") }
                )
            }

            #expect(recorder.events().contains("closeVotingDatabase"))
            #expect(!FileManager.default.fileExists(atPath: sidecar.path))

            // The parked load wakes up with the wallet already gone.
            await gate.open()
            await waitForStore { !store.state.hasConfiguredProving }

            #expect(!recorder.events().contains("openDatabase"), "the reset's delete must be the last word")
            #expect(
                !FileManager.default.fileExists(atPath: sidecar.path),
                "nothing may recreate the sidecar behind the reset"
            )

            // The refusal belongs to the teardown, not to the process: the next load opens.
            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { recorder.events().contains("openDatabase") }
            #expect(FileManager.default.fileExists(atPath: sidecar.path))
        }

        /// Older builds kept a copy of the voting database and an escrow of the
        /// delegation secrets in Documents, and the released notes promised both
        /// are removed when the wallet is reset. Nothing writes them any more, but
        /// what those builds wrote is still on disk -- a wallet's database copies,
        /// blinding factors and transaction hashes -- and this reset is the only
        /// thing that removes it, so it still has to.
        @MainActor
        @Test func aWalletResetRemovesWhatOlderBuildsPreservedForRecovery() async throws {
            let documents = try Self.temporaryDocumentsDirectory()
            defer { try? FileManager.default.removeItem(at: documents) }
            let preserved = documents.appendingPathComponent("voting_recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)
            // The whole preserved set, sidecars and capture marker included: it is
            // the directory that goes, not one file inside it.
            try Data([0x01]).write(to: preserved.appendingPathComponent("voting.sqlite3"))
            try Data([0x02]).write(to: preserved.appendingPathComponent("voting.sqlite3-wal"))
            try Data([0x03]).write(to: preserved.appendingPathComponent("captured-20260101-000000.txt"))
            let escrow = documents.appendingPathComponent("voting-delegation-escrow.json")
            try Data(#"{"version":1,"entries":[]}"#.utf8).write(to: escrow)

            await Self.runDeviceScopedWalletClear(documents: documents, gate: VotingTeardown())

            #expect(!FileManager.default.fileExists(atPath: preserved.path))
            #expect(!FileManager.default.fileExists(atPath: escrow.path))

            // A wallet that never ran one of those builds has neither, and a reset
            // must not fail because there was nothing to remove.
            await Self.runDeviceScopedWalletClear(documents: documents, gate: VotingTeardown())

            #expect(!FileManager.default.fileExists(atPath: preserved.path))
            #expect(!FileManager.default.fileExists(atPath: escrow.path))
        }

        /// Root's own side of a wallet reset, pointed at a Documents directory of
        /// this test's own. `closeVotingDatabase` is a no-op here: what is under
        /// test is what the clear deletes, not the drain that precedes it.
        private static func runDeviceScopedWalletClear(documents: URL, gate: VotingTeardown) async {
            var userStoredPreferences = UserPreferencesStorageClient()
            userStoredPreferences.removeAll = { }
            await withDependencies {
                $0.votingCrypto.beginWalletTeardown = { gate.begin() }
                $0.votingCrypto.endWalletTeardown = { gate.end() }
                $0.databaseFiles.documentsDirectory = { documents }
            } operation: {
                await Root.clearDeviceScopedWalletState(
                    userDefaults: .noOp,
                    flexaHandler: .noOp,
                    userStoredPreferences: userStoredPreferences,
                    readTransactionsStorage: .noOp,
                    closeVotingDatabase: { }
                )
            }
        }

        /// A teardown that reaches a flow which is still alive does not wait to be refused:
        /// the flow gives back the sessions it is holding, so the reset's own close has
        /// nothing left to wait on and no event from them can write back afterwards.
        @MainActor
        @Test func votingTeardownFencesTheSessionsTheFlowStillHolds() async throws {
            let recorder = EventRecorder()
            let store = Store(initialState: sessionFlowState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.setOperationEpoch = { roundId, epoch in
                    recorder.record("setOperationEpoch:\(roundId):\(epoch)")
                }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.closeRoundSession = { roundId in recorder.record("closeRoundSession:\(roundId)") }
            }

            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            await waitForStore { self.isProposalListTop(store.state) }

            store.send(.votingTeardownBegan)
            await waitForStore { recorder.events().contains("closeRoundSession:\(self.activeRoundId)") }

            #expect(
                recorder.events().filter { Self.isSessionLifecycleEvent($0) } == [
                    "setOperationEpoch:\(activeRoundId):2",
                    "cancelRoundSession:\(activeRoundId)",
                    "closeRoundSession:\(activeRoundId)"
                ]
            )
            #expect(store.state.roundCache[activeRoundId]?.sessionEpoch == 2)
        }

        // MARK: - Keystone round fixtures

        // MARK: - Round session fixtures

        // MARK: - Share tracking

        /// A helper that is still failing is re-armed on a bounded backoff rather
        /// than abandoned: 15 s after the first pass that stopped short, 30 s after
        /// the second, and the pass that confirms every share ends the ladder and
        /// resets it.
        @MainActor
        @Test func shareTrackingReArmsWithBackoffUntilConfirmed() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let failing = try shareTrackingReport(kind: "failing", messages: ["helper unreachable"])
            let confirmed = try shareTrackingReport(kind: "all_confirmed")
            let passStarted = try shareTrackingEvent(kind: "pass_started", pass: 1)
            let store = Store(initialState: shareTrackingState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.trackShares = { _, _ in
                    let call = recorder.recordAndCount("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.event(passStarted))
                        continuation.yield(VotingShareTrackingRunEvent.finished(call < 3 ? failing : confirmed))
                        continuation.finish()
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            #expect(recorder.events().filter { $0 == "trackShares" }.count == 3)
            #expect(sleeps.value == [Swift.Duration.seconds(15), Swift.Duration.seconds(30)])
            #expect(store.state.roundCache[self.activeRoundId]?.shareTrackingAttempt == 0)
        }

        /// Foreground passes run on a budget, and spending it is what hands the
        /// round back. A live pass is never cancelled to make room for a run —
        /// cancelling one ends the session under it, permanently — so an unbudgeted
        /// pass would hold the round for about an hour and the SDK would refuse the
        /// voter's next Confirm as `sessionBusy`. The budget turns that into a
        /// `passBudgetExhausted` quiescence and this flow's own 15 s ladder.
        @MainActor
        @Test func foregroundTrackingPassesRunOnABudgetAndReArmWhenItIsSpent() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let budgets = LockIsolated<[UInt32?]>([])
            let exhausted = try shareTrackingReport(kind: "pass_budget_exhausted")
            let confirmed = try shareTrackingReport(kind: "all_confirmed")
            let store = Store(initialState: shareTrackingState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.trackShares = { _, policy in
                    let call = recorder.recordAndCount("trackShares")
                    budgets.withValue { $0.append(policy.maxPasses) }
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(call == 1 ? exhausted : confirmed))
                        continuation.finish()
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            #expect(budgets.value.count == 2)
            #expect(budgets.value.allSatisfy { $0 == VotingCoordFlow.shareTrackingForegroundPasses })
            #expect(sleeps.value == [Swift.Duration.seconds(15)])
        }

        /// A round whose share delivery was interrupted resumes without the voter
        /// opening it: the sidecar names the rounds that still owe helper work, and
        /// the ones this wallet's authenticated config still carries get a session
        /// and a tracking pass as the flow initializes.
        @MainActor
        @Test func initializeResumesPendingShareRounds() async throws {
            let recorder = EventRecorder()
            let pending = try pendingShareRound(walletId: Self.pendingWalletId, roundId: activeRoundId)
            let nothingToTrack = try shareTrackingReport(kind: "nothing_to_track")
            var initialState = VotingCoordFlow.State()
            initialState.walletId = Self.pendingWalletId
            initialState.$selectedWalletAccount.withLock { $0 = self.zashiWalletAccount() }
            initialState.$swapAPIAccess.withLock { $0 = .direct }

            let store = Store(initialState: initialState) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingAPI.fetchServiceConfig = { _ in
                    Self.makeServiceConfig(
                        voteServers: [VotingServiceConfig.ServiceEndpoint(url: "https://vote.example.com", label: "vote")],
                        rounds: [self.activeRoundId: Self.roundEntry()]
                    )
                }
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = { [self.votingSession(proposalCount: 2, voteEndsIn: 3_600)] }
                $0.votingAPI.fetchZodlEndorsedRoundIds = { [self.activeRoundId] }
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingCrypto.pendingShareRounds = { [pending] }
                $0.votingCrypto.trackShares = { roundId, _ in
                    recorder.record("trackShares:\(roundId)")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(nothingToTrack))
                        continuation.finish()
                    }
                }
            }

            store.send(.initialize)
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .confirmed }

            #expect(recorder.events().filter { $0 == "openRoundSession" }.count == 1)
            #expect(recorder.events().contains("trackShares:\(activeRoundId)"))
            #expect(store.state.openRoundSessionIds == [activeRoundId])
        }

        /// Another pass already holds the round. Nothing to do and nothing to
        /// re-arm: the pass that holds it is the one that will report.
        @MainActor
        @Test func alreadyDrivingIsNoOp() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let alreadyDriving = try shareTrackingReport(kind: "already_driving")
            let store = Store(initialState: shareTrackingState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(alreadyDriving))
                        continuation.finish()
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.isTrackingShares == false }

            #expect(recorder.events().filter { $0 == "trackShares" } == ["trackShares"])
            #expect(store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .idle)
            #expect(store.state.roundCache[self.activeRoundId]?.shareTrackingAttempt == 0)
            #expect(sleeps.value.isEmpty)
        }

        /// Re-entering a round resets the flag that says a pass is running, because
        /// the pass belonged to the session the entry is replacing. That must not
        /// let a second `.pollShareStatus` start another pass onto the session being
        /// opened: the entry's own plan is what says whether the round still owes
        /// share work, and the pass the entry left alone is still consuming — so
        /// cancelling nothing is also the point, since cancelling a pass finishes
        /// the round's session under it.
        @MainActor
        @Test func aPollDuringARoundReEntryStartsNoSecondPass() async throws {
            let recorder = EventRecorder()
            let gate = TestGate()
            let confirmed = try shareTrackingReport(kind: "all_confirmed")
            let store = Store(initialState: shareTrackingState()) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.votingCrypto.sessionPlan = { _ in try self.plan(openProposals: [1, 2]) }
                $0.votingCrypto.cancelRoundSession = { roundId in recorder.record("cancelRoundSession:\(roundId)") }
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        let task = Task {
                            await gate.wait()
                            continuation.yield(VotingShareTrackingRunEvent.finished(confirmed))
                            continuation.finish()
                            recorder.record("trackShares.finished")
                        }
                        continuation.onTermination = { reason in
                            if case .cancelled = reason {
                                recorder.record("cancelRoundSession:consumerWentAway")
                            }
                            task.cancel()
                        }
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { recorder.events().contains("trackShares") }
            #expect(store.state.roundCache[self.activeRoundId]?.isTrackingShares == true)

            // Both sends land before the entry's own open can answer, so the second
            // poll sees exactly the state the re-entry left: not tracking, and a
            // session being opened.
            store.send(.startActiveRoundPipeline(roundId: activeRoundId))
            #expect(store.state.roundCache[self.activeRoundId]?.isTrackingShares == false)

            // The reducer answers synchronously, so this is the whole question: a
            // poll that had started a pass would have put the flag back on here.
            store.send(.pollShareStatus(roundId: activeRoundId))
            #expect(
                store.state.roundCache[self.activeRoundId]?.isTrackingShares == false,
                "a poll landing while the round's session is being reopened must start no pass"
            )

            await gate.open()
            await waitForStore { recorder.events().contains("trackShares.finished") }

            #expect(recorder.events().filter { $0 == "trackShares" } == ["trackShares"])
            #expect(!recorder.events().contains { $0.hasPrefix("cancelRoundSession") })
        }

        /// A vote that closes ends the round's share tracking: the pass is cancelled,
        /// and because a cancelled effect delivers no terminal action, the flags it
        /// would have cleared are cleared here. Left alone, the round keeps a pass
        /// that no longer exists and a delivery that never finishes.
        @Test func aRoundThatStopsVotingEndsItsShareTracking() {
            for status in [SessionStatus.tallying, SessionStatus.finalized] {
                var session = RoundSession(roundId: activeRoundId)
                session.isTrackingShares = true
                session.shareTrackingStatus = .tracking(pass: 2)
                session.shareTrackingAttempt = 3
                session.voteRecord = Voting.VoteRecord(
                    votedAt: Date(),
                    votingWeight: 50_000_000,
                    proposalCount: 2
                )
                var state = VotingCoordFlow.State()
                state.roundCache[activeRoundId] = session
                state.openRoundSessionIds = [activeRoundId]
                state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession(proposalCount: 2))]
                state.path.append(.proposalList(ProposalList.State(roundId: activeRoundId)))

                _ = VotingCoordFlow().coordinatorReduce().reduce(
                    into: &state,
                    action: .roundStatusUpdated(roundId: activeRoundId, status: status)
                )

                let updated = tryUnwrap(state.roundCache[activeRoundId])
                #expect(updated.isTrackingShares == false)
                #expect(updated.shareTrackingStatus == .ended)
                #expect(updated.shareTrackingAttempt == 0)
                // Cancelling the pass finishes the SDK session anyway, so the round
                // is closed here rather than left registered, holding the sidecar
                // and its transport for a vote that is over.
                #expect(state.openRoundSessionIds.isEmpty)
            }
        }

        /// A round whose shares were confirmed before the vote closed keeps that
        /// answer: `.ended` would say they never landed.
        @Test func aClosedVoteKeepsConfirmedSharesConfirmed() {
            var session = RoundSession(roundId: activeRoundId)
            session.isTrackingShares = true
            session.shareTrackingStatus = .confirmed
            var state = VotingCoordFlow.State()
            state.roundCache[activeRoundId] = session
            state.openRoundSessionIds = [activeRoundId]
            state.allRounds = [RoundListItem(roundNumber: 1, session: votingSession(proposalCount: 2))]
            state.path.append(.proposalList(ProposalList.State(roundId: activeRoundId)))

            _ = VotingCoordFlow().coordinatorReduce().reduce(
                into: &state,
                action: .roundStatusUpdated(roundId: activeRoundId, status: .tallying)
            )

            let updated = tryUnwrap(state.roundCache[activeRoundId])
            #expect(updated.isTrackingShares == false)
            #expect(updated.shareTrackingStatus == .confirmed)
        }

        /// The re-arm is bounded by the round's own vote end. A backoff that would
        /// wake up after the vote has closed is not scheduled at all, and the round
        /// is `.ended` rather than left waiting for a pass that never comes.
        @MainActor
        @Test func shareTrackingStopsWhenTheBackoffWouldLandPastVoteEnd() async throws {
            let recorder = EventRecorder()
            let sleeps = LockIsolated<[Swift.Duration]>([])
            let failing = try shareTrackingReport(kind: "failing", messages: ["helper unreachable"])
            // The first backoff is 15 s; this round closes inside it.
            let store = Store(initialState: shareTrackingState(voteEndsIn: 5)) {
                VotingCoordFlow()
            } withDependencies: {
                self.sessionDependencies(&$0, recorder: recorder)
                $0.continuousClock = RecordingImmediateClock(sleeps: sleeps)
                $0.votingCrypto.trackShares = { _, _ in
                    recorder.record("trackShares")
                    return AsyncThrowingStream { continuation in
                        continuation.yield(VotingShareTrackingRunEvent.finished(failing))
                        continuation.finish()
                    }
                }
            }

            store.send(.pollShareStatus(roundId: activeRoundId))
            await waitForStore { store.state.roundCache[self.activeRoundId]?.shareTrackingStatus == .ended }

            #expect(recorder.events().filter { $0 == "trackShares" } == ["trackShares"])
            #expect(sleeps.value.isEmpty)
        }

        // MARK: - MOB-1810 health sweep hooks

        @MainActor
        @Test func votingInitializeDoesNotStartHealthSweep() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = { [] }
                $0.votingAPI.fetchZodlEndorsedRoundIds = { [] }
                $0.votingAPI.startHealthProbeSweep = { recorder.record("sweep") }
                $0.databaseFiles = .noOp
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.configureProving = { _ in }
                $0.votingCrypto.warmProvingCaches = { }
                $0.votingCrypto.pendingShareRounds = { [] }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { store.state.rootScreen == .noRounds }

            #expect(recorder.events().isEmpty)
        }

        // MARK: - Process-wide proving

        /// The proving policy is fixed before anything can start the crate's pool:
        /// warming the caches is what starts it, and the pool keeps whichever policy
        /// started it, so a policy asked for afterwards is refused.
        @MainActor
        @Test func serviceConfigFixesTheProvingPolicyBeforeWarmingTheCaches() async {
            let recorder = EventRecorder()
            let store = Store(initialState: VotingCoordFlow.State()) {
                VotingCoordFlow()
            } withDependencies: {
                $0.votingAPI.configureURLs = { _ in }
                $0.votingAPI.fetchAllRounds = {
                    recorder.record("fetchAllRounds")
                    return []
                }
                $0.votingAPI.fetchZodlEndorsedRoundIds = { [] }
                $0.votingAPI.startHealthProbeSweep = { }
                $0.databaseFiles = .noOp
                $0.votingCrypto.openDatabase = { _, _ in }
                $0.votingCrypto.setWalletId = { _ in }
                $0.votingCrypto.pendingShareRounds = { [] }
                $0.votingCrypto.configureProving = { policy in
                    let workers = policy.cpuWorkerCount.map(String.init) ?? "crate"
                    recorder.record("configureProving:\(workers):\(policy.maxActiveHeavyJobs)")
                }
                $0.votingCrypto.warmProvingCaches = { recorder.record("warmProvingCaches") }
                $0.votingMetadata = self.votingMetadataClient(VotingMetadataBox())
            }

            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { recorder.events().contains("warmProvingCaches") }

            #expect(
                recorder.events().filter { $0 != "fetchAllRounds" }
                    == ["configureProving:crate:1", "warmProvingCaches"]
            )

            // Once per process, both of them: a second config load -- a chain switch,
            // say -- must not ask the crate for a policy its running pool would refuse.
            store.send(.serviceConfigLoaded(Self.makeServiceConfig()))
            await waitForStore { recorder.events().filter { $0 == "fetchAllRounds" }.count == 2 }

            #expect(recorder.events().filter { $0.hasPrefix("configureProving") }.count == 1)
            #expect(recorder.events().filter { $0 == "warmProvingCaches" }.count == 1)
        }
    }
}

private actor RecoveryOrderRecorder {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func recordAndCount(_ event: String) -> Int {
        recordedEvents.append(event)
        return recordedEvents.filter { $0 == event }.count
    }

    func events() -> [String] {
        recordedEvents
    }
}

private enum TestError: LocalizedError {
    case unexpectedSpendAuthExtraction
    case proofFailed
    case shareRecordWriteFailed
    case delegationSetupMissing
    case delegationProofMissing
    case votingDatabaseReadFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedSpendAuthExtraction:
            return "unexpected SpendAuth extraction"
        case .proofFailed:
            return "proof failed"
        case .shareRecordWriteFailed:
            return "simulated local share-record write failure"
        case .delegationSetupMissing:
            return "simulated missing persisted delegation setup"
        case .delegationProofMissing:
            return "simulated missing persisted delegation proof"
        case .votingDatabaseReadFailed:
            return "simulated voting database read failure"
        }
    }
}
#endif
