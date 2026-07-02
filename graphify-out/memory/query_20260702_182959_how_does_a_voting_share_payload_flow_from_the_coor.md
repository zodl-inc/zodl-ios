---
type: "query"
date: "2026-07-02T18:29:59.420290+00:00"
question: "How does a voting share payload flow from the CoordFlow through the models to the API client?"
contributor: "graphify"
outcome: "useful"
source_nodes: ["VotingCoordFlowCoordinator", "delegateSharesWithFallback", "SharePayload", "EncryptedShare", "VotingCryptoClient", "delegateSharePayloads", "sharePostBody", "VotingAPIClient", "VotingMetadata", "submittedVotes"]
---

# Q: How does a voting share payload flow from the CoordFlow through the models to the API client?

## Answer

Expanded from original query via graph vocab: [voting, share, payload, coordinator, delegation, submit, api, client, bundle, signature, commitment]. Flow (all EXTRACTED unless noted): VotingCoordFlowStore reducer -> VotingCoordFlowCoordinator (reduceStartDelegationProof L2548, tryRecoverInflightVote L3418) --calls--> delegateSharesWithFallback(). VotingCryptoClient --references--> SharePayload + EncryptedShare (builds encrypted share). SharePayload (VotingModels.swift L518) --references--> EncryptedShare (L446); SharePayload is the shared DTO. VotingHelpers .delegateSharesWithFallback() (L310) --references--> VotingAPIClient, SharePayload, ShareDelegationResult, Duration (retry/backoff wrapper). VotingAPIClient delegateSharePayloads() (VotingAPIClientLiveKey L381) --references--> SharePayload, ShareDelegationResult; --calls--> sharePostBody() (serializes to HTTP body) + DelegatedShareInfo [INFERRED]; --references--> ShareTargetSelector. Broadcast closures (delegateShares/submitDelegation/submitVoteCommitment) acquire the transaction guard inside the LiveKey; resubmitSharePayload/isBroadcastRetryable is the unguarded idempotent recovery path. Result persists into VotingMetadata.submittedVotes (Models/VotingMetadata L54) / PersistedVotingRecord via VotingHelpers persistSubmittedVotes/storeVotingMetadata and VotingMetadataStorage setSubmittedVotes. Caveats: graph node makeRecoverySharePayload resolves to a TEST file (VotingServiceConfigTests L930); VotingAPIClient struct node is degree-1 because @DependencyClient closures extract as separate nodes; a DFS path through .warn() is a spurious shared-logger bridge, not a real call edge.

## Outcome

- Signal: useful

## Source Nodes

- VotingCoordFlowCoordinator
- delegateSharesWithFallback
- SharePayload
- EncryptedShare
- VotingCryptoClient
- delegateSharePayloads
- sharePostBody
- VotingAPIClient
- VotingMetadata
- submittedVotes