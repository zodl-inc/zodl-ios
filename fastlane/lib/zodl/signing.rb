# frozen_string_literal: true

module Zodl
  # Which signing identities each variant needs in the keychain. Pure string
  # matching against `security find-identity -v -p codesigning` output, so the
  # decision is unit-testable; the Fastfile supplies the raw output.
  module Signing
    # Each requirement is a list of acceptable identity-name alternatives
    # (any one satisfies it). The first alternative is the canonical name used
    # in error messages.
    REQUIREMENTS = {
      [:ios, :testflight] => [["Apple Distribution", "iPhone Distribution"]],
      [:ios, :appstore] => [["Apple Distribution", "iPhone Distribution"]],
      [:macos, :testflight] => [["Apple Distribution"], ["Mac Installer Distribution"]],
      [:macos, :dmg] => [["Developer ID Application"]]
    }.freeze

    module_function

    # Returns the canonical names of the requirements not satisfied by
    # `installed`. Empty array means the variant can sign.
    def missing_identities(platform:, channel:, installed:)
      requirements = REQUIREMENTS.fetch([platform, channel]) do
        raise ArgumentError, "no signing requirements defined for #{platform}/#{channel}"
      end
      requirements
        .reject { |alternatives| alternatives.any? { |name| installed.include?(name) } }
        .map(&:first)
    end
  end
end
