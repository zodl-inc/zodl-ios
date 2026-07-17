# frozen_string_literal: true

module Zodl
  # Maps each variant to its scheme/target/archive-config, App Store Connect
  # bundle id, channel, platform (iOS or macOS), and flavor (mac only). iOS
  # variants are separate ASC apps with independent trains. macOS comes in two
  # flavors (internal=mainnet ASC app, testnet=separate ASC app), each with two
  # channels (testflight package, local notarized dmg). flavor: names the
  # artifact family. "ios-internal-testnet" expands to both iOS TestFlight variants.
  module Variants
    ATOMIC = {
      "ios-internal" => {
        scheme: "zodl-internal", target: "zodl-internal",
        configuration: "Release-Testflight",
        app_identifier: "co.electriccoin.secant-testnet",
        channel: :testflight, platform: :ios
      },
      "ios-testnet" => {
        scheme: "zodl-testnet", target: "zodl-testnet",
        configuration: "Release-Testflight",
        app_identifier: "co.ecc.zashi-testnet", channel: :testflight, platform: :ios
      },
      "ios-appstore" => {
        scheme: "zodl-AppStore", target: "zodl-production",
        configuration: "Release-AppStore",
        app_identifier: "co.electriccoin.secant-mainnet", channel: :appstore, platform: :ios
      },
      "mac-internal" => {
        scheme: "zodlmac-internal", target: "zodlmac-internal",
        configuration: "Release-Testflight",
        app_identifier: "co.electriccoin.secant-testnet",
        channel: :testflight, platform: :macos, flavor: "internal"
      },
      "mac-internal-dmg" => {
        scheme: "zodlmac-internal", target: "zodlmac-internal",
        configuration: "Release-AppStore",
        app_identifier: "co.electriccoin.secant-testnet",
        channel: :dmg, platform: :macos, flavor: "internal"
      },
      "mac-testnet" => {
        scheme: "zodlmac-testnet", target: "zodlmac-testnet",
        configuration: "Release-Testflight",
        app_identifier: "co.ecc.zashi-testnet",
        channel: :testflight, platform: :macos, flavor: "testnet"
      },
      "mac-testnet-dmg" => {
        scheme: "zodlmac-testnet", target: "zodlmac-testnet",
        configuration: "Release-AppStore",
        app_identifier: "co.ecc.zashi-testnet",
        channel: :dmg, platform: :macos, flavor: "testnet"
      }
    }.freeze

    COMBINED = {
      "ios-internal-testnet" => %w[ios-internal ios-testnet]
    }.freeze

    module_function

    def valid?(name)
      ATOMIC.key?(name) || COMBINED.key?(name)
    end

    def expand(name)
      return COMBINED[name].dup if COMBINED.key?(name)
      return [name] if ATOMIC.key?(name)

      raise ArgumentError, "unknown variant: #{name.inspect}"
    end

    def config(atomic_name)
      ATOMIC.fetch(atomic_name) { raise ArgumentError, "not an atomic variant: #{atomic_name.inspect}" }
    end

    # Resolves a bump --target selector to Xcode target names: an exact target
    # name bumps just that target, "ios" every iOS app target, "mac" every macOS
    # app target, "all" every app target. Targets are versioned independently
    # (macOS does not track iOS), so the caller must always say which scope it
    # means.
    def bump_targets(selector)
      targets = ATOMIC.values
      case selector
      when "all" then targets.map { |cfg| cfg[:target] }.uniq
      when "ios" then targets.select { |cfg| cfg[:platform] == :ios }.map { |cfg| cfg[:target] }.uniq
      when "mac" then targets.select { |cfg| cfg[:platform] == :macos }.map { |cfg| cfg[:target] }.uniq
      else
        known = targets.map { |cfg| cfg[:target] }.uniq
        return [selector] if known.include?(selector)

        raise ArgumentError,
              "unknown bump target #{selector.inspect} — use one of: #{known.join(', ')}, or 'ios' / 'mac' / 'all'"
      end
    end
  end
end
