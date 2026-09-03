# frozen_string_literal: true

module Zodl
  # Marketing-version parsing/validation (X.Y.Z) and release-branch derivation.
  module Version
    SEMVER = /\A\d+\.\d+\.\d+\z/
    # Both branches a release is built from. Scripts/prepare-release.sh cuts
    # release/X.Y.Z from the previous tag and candidate/X.Y.Z from the revision
    # being released, and every build during a release cycle comes from the
    # candidate branch -- so recognising only release/ would drop the
    # branch-against-version check exactly where it is used.
    RELEASE_BRANCH = %r{\A(?:release|candidate)/(\d+\.\d+\.\d+)\z}

    module_function

    def valid?(value)
      value.is_a?(String) && SEMVER.match?(value)
    end

    # "release/3.8.0" or "candidate/3.8.0" -> "3.8.0"; anything else -> nil
    def from_branch(ref)
      match = RELEASE_BRANCH.match(ref.to_s)
      match && match[1]
    end
  end
end
