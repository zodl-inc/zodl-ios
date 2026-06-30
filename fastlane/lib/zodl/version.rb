# frozen_string_literal: true

module Zodl
  # Marketing-version parsing/validation (X.Y.Z) and release-branch derivation.
  module Version
    SEMVER = /\A\d+\.\d+\.\d+\z/
    RELEASE_BRANCH = %r{\Arelease/(\d+\.\d+\.\d+)\z}

    module_function

    def valid?(value)
      value.is_a?(String) && SEMVER.match?(value)
    end

    # "release/3.8.0" -> "3.8.0"; anything else -> nil
    def from_branch(ref)
      match = RELEASE_BRANCH.match(ref.to_s)
      match && match[1]
    end
  end
end
