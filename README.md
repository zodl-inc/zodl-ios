# Zodl iOS Wallet

This is the official home of the Zodl Zcash wallet, a no-frills
Zcash mobile wallet leveraging the [Zcash Swift SDK](https://github.com/zcash/zcash-swift-wallet-sdk).

# Production

The Zodl iOS wallet is publicly available for download in the [AppStore](https://apps.apple.com/us/app/zodl-zcash-wallet/id1672392439).

# Zodl Support

Obtain help for Zodl and connect with our team at [support.zodl.com](https://support.zodl.com/).

# Reporting an issue

If you'd like to report a technical issue or feature request for the iOS
Wallet, please file a GitHub issue [here](https://github.com/zodl-inc/zodl-ios/issues/new/choose).

For feature requests and issues related to the Zodl user interface that are
not iOS-specific, please file a GitHub issue [here](https://github.com/zodl-inc/zodl-project/issues/new/choose).

If you wish to report a security issue, please follow our
[Responsible Disclosure guidelines](https://github.com/zodl-inc/zodl-project/blob/main/responsible_disclosure.md).
See the [Wallet App Threat Model](https://github.com/zodl-inc/zodl-project/blob/main/wallet_threat_model.md)
for more information about the security and privacy limitations of the wallet.

General Zcash questions and/or support requests may also be directed to either:
 * [Zcash Forum](https://forum.zcashcommunity.com/)
 * [Discord Community](https://discord.io/zcash-community)

# Contributing

Contributions are very much welcomed! Please read our [Contributing Guidelines](/CONTRIBUTING.md) 
and [Code of Conduct](/CONDUCT.md). Our backlog has many Issues tagged with the
`good first issue` label. Please fork the repo and make a pull request for us
to review.

Zodl Wallet uses [SwiftLint](https://github.com/realm/SwiftLint) and 
[SwiftGen](https://github.com/SwiftGen/SwiftGen) to conform to our coding
guidelines for source code and generate accessors for assets. Please install
these locally when contributing to the project, they are run automatically when
you build.

## Installation of Swiftgen & Swiftlint on Apple Silicon-based hardware

### Swiftgen

Install it using homebrew
```
$ brew install swiftgen
```
and create a symbolic link
```
ln -s /opt/homebrew/bin/swiftgen /usr/local/bin
```

### Swiftlint

The project is setup to work with `0.50.3` version. We recommend to install it
directly using [the official 0.50.3 package](https://github.com/realm/SwiftLint/releases/download/0.50.3/SwiftLint.pkg).
If you follow this step there is no symbolic link needed.

In case you already have swiftlint 0.50.3 ready on your machine and installed via homebrew, create a symbolic link
```
ln -s /opt/homebrew/bin/swiftlint /usr/local/bin
```

## SDK pin (.sdk-pin)

The `.sdk-pin` file at the repo root records which commit of the Zcash Swift SDK the app currently builds against. Its value is maintained automatically and derives from your Xcode project configuration:

- **Remote SDK reference** — if your project points to the SDK at a remote URL (GitHub), the `.sdk-pin` file remains empty.
- **Local SDK reference** — if your project points to a local SDK checkout (`../zodl-swift-wallet-sdk` sibling directory), the file holds the full 40-character commit SHA of that checkout.

The `Update SDK Pin` build phase runs on every build of the app targets and refreshes the file as needed. When the pin appears modified in `git status`, commit it together with your app changes.

A pin value ending in `-dirty` indicates the app was last built against uncommitted changes in the SDK. CI will reject this state. To fix it: commit and push your SDK work, rebuild the app (the pin refreshes automatically), then commit the updated pin.

When the pinned commit has a tag pointing exactly at it, the pin file gains a second, space-separated field holding that tag (e.g. `<sha> v1.2.3`) purely for human legibility in diffs and merge conflicts — it's informational only, never present on a `-dirty` pin, and CI always reads just the sha.

If `.sdk-pin` conflicts on merge, don't hand-merge it: take either side, run `Scripts/update-sdk-pin.sh` (or just build once), and commit the result — the file is derived state, not something to reconcile by hand.

On CI, a validation gate checks the pin first before proceeding. When you reference a local SDK, a shared `build_ffi` job fetches the SDK at the pinned commit and builds its Rust FFI core once; the result is cached across CI runs and reused by both unit-test and end-to-end-test workflows. If a pin points to a commit reachable only from an unmerged SDK branch, CI emits a warning — repoint the pin to the merged commit before the SDK's PR branch is deleted, or CI's fetch of the pinned commit will start failing outright.

The pin certifies the SDK state you **last built** locally. If you advance the SDK work before pushing, rebuild the app to refresh the pin. CI constructs the FFI from the pinned tree using the SDK's own build script, `Scripts/init-local-ffi.sh`.
