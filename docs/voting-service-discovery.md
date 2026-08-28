# Voting Service Discovery

How zodl-ios discovers vote servers and PIR endpoints at runtime. The wallet implements draft [ZIP 1244](https://github.com/zcash/zips/pull/1244) "Shielded Voting Wallet API".

## Resolution order

1. **Static config** — the wallet embeds an ordered mirror list for one immutable, hash-pinned document (`URL?checksum=sha256:HEX`, both entries pinning the same SHA-256): the `voting.valargroup.dev/pins/prod/...` gateway copy first, then the byte-identical `raw.githubusercontent.com/valargroup/token-holder-voting-config/main/pins/prod/...` copy. It carries the trusted voting admin keys and the ordered `dynamic_config_urls` mirror list (static config v2; a v1 document's single `dynamic_config_url` is accepted and treated as a one-entry list). Mirrors are tried in order; a transport failure, non-200 response, or hash mismatch moves to the next mirror, while a decode or validation failure after the hash matched is authoritative (the pin guarantees identical bytes everywhere) and fails immediately.
2. **Dynamic config** — fetched from the static config's `dynamic_config_urls` in order, currently the [`voting.valargroup.dev` gateway](https://voting.valargroup.dev/prod/dynamic-voting-config.json) then the GitHub-raw copy. The walk falls through to the next mirror on a transport failure, a 5xx response, or an HTTP 403/407/429/451 — statuses that filtering middleboxes, proxies, and rate limiters answer with. This deliberately widens the publisher README's transport-and-5xx rule: on exactly the filtered networks this fallback exists for, the block arrives as one of those statuses. Any other non-200 (400, 404, 410, …), or a response that fails to decode or validate, is an authoritative answer from the publisher and surfaces immediately. The GitHub-raw copy may lag the gateway by up to ~300 s: GitHub's CDN caches branch paths, ignores request cache headers, and strips query strings from its cache key (so cache-busting tokens do nothing). The mirror is only consulted when the gateway attempt fails, and round entries remain signature-authenticated, so the exposure is bounded staleness — never forgery.

Mirrors widen availability, not trust: whichever origin answers, the static config must match the embedded SHA-256, and every round entry is still authenticated against the pinned `trusted_keys` — a mirror can serve stale rounds but cannot forge one. Config requests use a 15-second per-attempt timeout so a blackholed route fails over quickly. If every static mirror fails, the SHA-256 does not match anywhere, or every dynamic mirror is unreachable, or the dynamic config decodes to an unsupported shape or advertises a version the wallet doesn't speak, the wallet routes to the `.configError` screen (`VotingConfigErrorView`) and voting is blocked for the session.

Implementation lives in [`VotingAPIClientLiveKey.swift`](../secant/Sources/Dependencies/VotingAPIClient/VotingAPIClientLiveKey.swift) (`fetchServiceConfig`) and [`StaticVotingConfig.swift`](../secant/Sources/Dependencies/VotingModels/StaticVotingConfig.swift) (`loadFromNetworkWithFailover`), and [`VotingConfigMirrorWalk.swift`](../secant/Sources/Dependencies/VotingModels/VotingConfigMirrorWalk.swift) (the shared mirror walk and `fetchDynamicConfig`).

## Config format

Per the [Vote Configuration Format ZIP](https://github.com/zcash/zips/pull/1244):

```json
{
  "config_version": 1,
  "vote_servers": [
    {"url": "https://vote-chain-primary.valargroup.org", "label": "primary"},
    {"url": "https://vote-chain-secondary.valargroup.org", "label": "secondary"}
  ],
  "pir_endpoints": [
    {"url": "https://pir.valargroup.org", "label": "PIR primary"}
  ],
  "supported_versions": {
    "pir": ["v0"],
    "vote_protocol": "v0",
    "tally": "v0",
    "vote_server": "v1"
  }
}
```

All fields are required. `JSONDecoder` throws on any missing field, which surfaces as a `.configError` with `VotingConfigError.decodeFailed`. Extra CDN fields are ignored by the wallet unless they are explicitly added to `VotingServiceConfig`.

| Field                | Purpose                                                                                                                                                                     |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config_version`     | Schema version of this document. Currently 1.                                                                                                                               |
| `vote_servers`       | Chain REST + helper API endpoints. The wallet's first entry serves API traffic; all entries are used for distributing share submissions.                                    |
| `pir_endpoints`      | PIR servers for nullifier-exclusion proofs. The first entry is used.                                                                                                        |
| `supported_versions` | What versions of each component the server speaks. See "Version handling" below.                                                                                            |

## Version handling

[`WalletCapabilities`](../secant/Sources/Dependencies/VotingModels/VotingServiceConfig.swift) declares what this wallet build speaks. On each boot, `validate()` rejects the config if:

- `supported_versions.vote_server ∉ WalletCapabilities.voteServer`
- `supported_versions.vote_protocol ∉ WalletCapabilities.voteProtocol`
- `supported_versions.tally ∉ WalletCapabilities.tally`
- `supported_versions.pir ∩ WalletCapabilities.pir == ∅`

Rejection routes to `.configError`. Per ZIP 1244 §"Version Handling" this is a MUST — the wallet is too old to participate in this round and must be updated.

The `WalletCapabilities` values are compiled into the binary because they are a claim about what the binary actually implements: REST path prefixes in Swift, ZKP circuits in the Rust backend, the PIR scheme version the Rust `pir-client` crate speaks. Moving them to a runtime config would let a wallet accept a config its code can't serve. Bumping a version is a breaking change requiring code updates *and* a bump of `WalletCapabilities`.

## Chain-sourced round data

The CDN config does not carry proposals. After each config fetch, the wallet configures the vote/PIR endpoints and then queries the chain-backed REST API:

- `/shielded-vote/v1/rounds`
- `/shielded-vote/v1/rounds/active`
- `/shielded-vote/v1/round/{round_id}`
- `/shielded-vote/v1/tally-results/{round_id}`

`VoteRound.vote_round_id` is the authoritative round id used for UI state,
draft/vote persistence, crypto initialization, and transaction submission.
`VoteRound.proposals` is the authoritative source for proposal IDs, titles,
descriptions, options, forum links, and result labels.
`VoteRound.snapshot_height` and `VoteRound.vote_end_time` are the authoritative
snapshot and deadline values used by the wallet. `VoteRound.proposals_hash`
remains chain state and can be shown/debugged, but the wallet no longer
recomputes it from CDN JSON because the CDN no longer publishes proposal JSON.

## Failure recovery

- **Transient failure** (every config mirror unreachable, vote server temporarily unavailable, or chain API mid-restart): the wallet surfaces the relevant config or round-loading error and the user can retry by re-entering the flow.
- **Permanent failure** (unsupported version or incompatible endpoint set): terminal for the voting session. The user dismisses and re-enters once they've updated the wallet or the publisher has corrected the CDN/chain state.

## Publisher responsibilities

The config publisher (currently [`valargroup/token-holder-voting-config`](https://github.com/valargroup/token-holder-voting-config)) must:

1. Keep `vote_servers` and `pir_endpoints` current so wallets can reach healthy infrastructure.
2. Ensure the configured vote servers expose the chain round and its `VoteRound.proposals` via `/shielded-vote/v1/rounds`, `/shielded-vote/v1/rounds/active`, and `/shielded-vote/v1/round/{round_id}`.
3. Keep `supported_versions.vote_server` aligned with the REST path prefix the deployed server actually serves (the wallet hits `/shielded-vote/v1/` when `vote_server: "v1"`).

When no round is active, `/shielded-vote/v1/rounds/active` returns no active
round and the wallet shows the no-rounds state from chain data.
