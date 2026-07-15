# frozen_string_literal: true

module Zodl
  # Maps each variant to its scheme/target/archive-config, App Store Connect
  # bundle id, channel, and platform (iOS or macOS). iOS variants are separate
  # ASC apps with independent trains; mac-internal shares iOS internal's bundle
  # id and rides that same app record's macOS platform train; mac-dmg shares
  # the mac-internal target/bundle id too but has no ASC train at all (local
  # notarized DMG only). "internal-testnet" expands to both iOS TestFlight
  # variants. "mac" expands to both macOS variants (which share a
  # target/bundle-id but differ by channel: TestFlight package vs. local
  # notarized DMG).
  module Variants
    ATOMIC = {
      "internal" => {
        scheme: "zodl-internal", target: "zodl-internal",
        configuration: "Release-Testflight",
        app_identifier: "co.electriccoin.secant-testnet",
        channel: :testflight, platform: :ios
      },
      "testnet" => {
        scheme: "zodl-testnet", target: "zodl-testnet",
        configuration: "Release-Testflight",
        app_identifier: "co.ecc.zashi-testnet", channel: :testflight, platform: :ios
      },
      "appstore" => {
        scheme: "zodl-AppStore", target: "zodl-production",
        configuration: "Release-AppStore",
        app_identifier: "co.electriccoin.secant-mainnet", channel: :appstore, platform: :ios
      },
      "mac-internal" => {
        scheme: "zodlmac-internal", target: "zodlmac-internal",
        configuration: "Release-Testflight",
        app_identifier: "co.electriccoin.secant-testnet",
        channel: :testflight, platform: :macos
      },
      "mac-dmg" => {
        scheme: "zodlmac-internal", target: "zodlmac-internal",
        configuration: "Release-AppStore",
        app_identifier: "co.electriccoin.secant-testnet",
        channel: :dmg, platform: :macos
      }
    }.freeze

    COMBINED = {
      "internal-testnet" => %w[internal testnet],
      "mac" => %w[mac-internal mac-dmg]
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
    # name bumps just that target, "ios" every iOS app target, "all" every app
    # target. Targets are versioned independently (macOS does not track iOS),
    # so the caller must always say which scope it means.
    def bump_targets(selector)
      targets = ATOMIC.values
      case selector
      when "all" then targets.map { |cfg| cfg[:target] }.uniq
      when "ios" then targets.select { |cfg| cfg[:platform] == :ios }.map { |cfg| cfg[:target] }.uniq
      else
        known = targets.map { |cfg| cfg[:target] }.uniq
        return [selector] if known.include?(selector)

        raise ArgumentError,
              "unknown bump target #{selector.inspect} — use one of: #{known.join(', ')}, or 'ios' / 'all'"
      end
    end
  end
end
