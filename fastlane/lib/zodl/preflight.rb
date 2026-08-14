# frozen_string_literal: true

require "zodl/version"
require "zodl/variants"
require "zodl/build_number"

module Zodl
  # Pure reconciliation of declared intent against gathered facts. No I/O — the
  # Fastfile gathers facts and passes them in as `ctx`, so this is fully testable.
  # Checks version/build consistency, release branch readiness, signing identities,
  # SDK checkout/FFI slice availability, dirty working tree / SDK state, and local
  # Swift package reproducibility.
  class Preflight
    # The facts the Fastfile gathers and hands to `check`. A plain Struct so the
    # tooling depends on no extra gems (avoids ostruct, which newer Ruby is
    # phasing out of the standard library).
    Context = Struct.new(
      :variant, :requested_version, :requested_build, :project_version,
      :branch_version, :latest_build, :ref_on_origin, :dirty_tree,
      :partner_keys_error, :xcode_ok, :signing_identity_ok, :missing_signing_identities,
      :sdk_checkout_ok, :ffi_slice_ok, :sdk_dirty, :local_packages,
      keyword_init: true
    )

    Report = Struct.new(:errors, :warnings) do
      def ok?
        errors.empty?
      end
    end

    def self.check(ctx)
      errors = []
      warnings = []

      return Report.new(["unknown variant '#{ctx.variant}'"], warnings) unless Zodl::Variants.valid?(ctx.variant)

      errors << "version '#{ctx.requested_version}' is not in X.Y.Z form" unless Zodl::Version.valid?(ctx.requested_version)

      if ctx.branch_version && ctx.requested_version != ctx.branch_version
        errors << "version #{ctx.requested_version} does not match release branch version #{ctx.branch_version}"
      end

      if ctx.project_version && ctx.requested_version != ctx.project_version
        errors << "version #{ctx.requested_version} does not match project MARKETING_VERSION #{ctx.project_version}"
      end

      bn = Zodl::BuildNumber.validate(requested: ctx.requested_build, latest: ctx.latest_build)
      errors << bn.error if bn.error
      warnings << bn.warning if bn.warning

      errors << "ref is not on origin — push it before releasing" unless ctx.ref_on_origin
      errors << ctx.partner_keys_error if ctx.partner_keys_error
      errors << "Xcode version does not match .xcode-version" unless ctx.xcode_ok
      errors << "no distribution signing identity found in the keychain" unless ctx.signing_identity_ok.nil? || ctx.signing_identity_ok

      Array(ctx.missing_signing_identities).each do |name|
        errors << "missing signing identity in keychain: '#{name}'"
      end

      unless ctx.sdk_checkout_ok
        errors << "local SDK checkout not found at ../ZcashLightClientKit (this branch builds against it)"
      end

      if ctx.sdk_checkout_ok && !ctx.ffi_slice_ok
        errors << "local libzcashlc.xcframework is missing the slice/architectures this variant needs — " \
                  "run Scripts/rebuild-local-ffi.sh in the SDK checkout (use 'macos --universal' for mac builds)"
      end

      warnings << "ZcashLightClientKit checkout has uncommitted changes — the build will use them" if ctx.sdk_dirty

      warnings << "working tree has uncommitted changes — they are NOT included in this build" if ctx.dirty_tree

      # Local Swift packages (XCLocalSwiftPackageReference) are consumed live from
      # their on-disk checkout — HEAD plus any uncommitted changes — so a build
      # using them cannot be reproduced from this repo alone. A missing directory
      # is a certain build failure; a present one is shipped knowingly.
      (ctx.local_packages || []).each do |pkg|
        unless pkg[:exists]
          errors << "local Swift package #{pkg[:path]} not found at #{pkg[:resolved]}"
          next
        end

        state =
          if pkg[:git].nil?
            "not a git repository"
          elsif pkg[:dirty]
            "#{pkg[:git]} + UNCOMMITTED changes"
          else
            "#{pkg[:git]}, clean"
          end
        warnings << "build uses local Swift package #{pkg[:path]} (#{state}) — not reproducible from this repo alone"
      end

      Report.new(errors, warnings)
    end
  end
end
