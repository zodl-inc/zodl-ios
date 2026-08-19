# Zodl iOS Wallet

This is the official home of the Zodl Zcash wallet, a no-frills
Zcash mobile wallet leveraging the [Zcash Swift SDK](https://github.com/zcash/zcash-swift-wallet-sdk).

# Production

The Zodl IOS wallet is publicly available for download in the [AppStore](https://apps.apple.com/cz/app/zodl-zcash-wallet/id1672392439).

# Zodl Discord

Join the Zodl community on ECC Discord server, report bugs, share ideas, request new features, and help shape Zodl's journey!

https://discord.gg/jQPU7aXe7A

# Reporting an issue

If you'd like to report a technical issue or feature request for the IOS
Wallet, please file a GitHub issue [here](https://github.com/zodl-inc/zodl-ios/issues/new/choose).

For feature requests and issues related to the Zodl user interface that are
not iOS-specific, please file a GitHub issue [here](https://github.com/zodl-inc/zodl-project/issues/new/choose).

If you wish to report a security issue, please follow our
[Responsible Disclosure guidelines](https://github.com/zodl-inc/zodl-project/blob/master/responsible_disclosure.md).
See the [Wallet App Threat Model](https://github.com/zodl-inc/zodl-project/blob/master/wallet_threat_model.md)
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
