# frozen_string_literal: true

module Zodl
  # Maps each variant to its scheme/target/archive-config, App Store Connect
  # bundle id, and channel. Each variant is a separate target with its own
  # bundle id, so build-number namespaces never overlap. "internal-testnet"
  # expands to both TestFlight variants.
  module Variants
    ATOMIC = {
      "internal" => {
        scheme: "zodl-internal", target: "zodl-internal",
        configuration: "Release-Testflight",
        app_identifier: "co.electriccoin.secant-testnet", channel: :testflight
      },
      "testnet" => {
        scheme: "zodl-testnet", target: "zodl-testnet",
        configuration: "Release-Testflight",
        app_identifier: "co.ecc.zashi-testnet", channel: :testflight
      },
      "appstore" => {
        scheme: "zodl-AppStore", target: "zodl-production",
        configuration: "Release-AppStore",
        app_identifier: "co.electriccoin.secant-mainnet", channel: :appstore
      }
    }.freeze

    COMBINED = { "internal-testnet" => %w[internal testnet] }.freeze

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
  end
end
