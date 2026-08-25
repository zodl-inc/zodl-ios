# frozen_string_literal: true

require "zodl/version"

module Zodl
  # Pure reconciliation for an App Review submission. No I/O — the Fastfile
  # gathers facts from App Store Connect and passes them in, mirroring
  # Zodl::Preflight. Encodes the convergence rules for a version that may have
  # been created (and partially prepared) by hand in App Store Connect.
  class SubmitPreflight
    # States in which App Store Connect lets us edit metadata and (re)submit.
    EDITABLE_STATES = %w[
      PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY
    ].freeze
    # Already in the review pipeline — submitting again must be resolved by a
    # human in App Store Connect (cancel or wait), never automatically.
    IN_REVIEW_STATES = %w[WAITING_FOR_REVIEW IN_REVIEW READY_FOR_REVIEW].freeze
    # Approved but not yet released; ASC allows only one version in flight, so
    # the pending version blocks preparing the next one.
    PENDING_RELEASE_STATES = %w[PENDING_DEVELOPER_RELEASE PENDING_APPLE_RELEASE].freeze

    Context = Struct.new(
      :variant,            # must be "appstore"
      :requested_version,  # "X.Y.Z"
      :requested_build,    # Integer
      :ref_given,          # true on the build-and-submit path
      :build_state,        # :absent | :processing | :processed | :failed
      :version_state,      # appStoreState of the one in-flight version, or nil
      :version_string,     # version string of that in-flight version, or nil
      :live_version,       # version string of the live version, or nil
      :whats_new_errors,   # Zodl::WhatsNew::Result#errors
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

      errors << "--submit-review is only supported for the appstore variant (got '#{ctx.variant}')" unless ctx.variant == "appstore"
      errors << "version '#{ctx.requested_version}' is not in X.Y.Z form" unless Zodl::Version.valid?(ctx.requested_version)

      check_build(ctx, errors)
      check_version_state(ctx, errors, warnings)
      errors.concat(ctx.whats_new_errors || [])

      Report.new(errors, warnings)
    end

    # How the requested build relates to the in-flight version's attached build:
    #   :attach — nothing attached yet, :keep — the right build is already
    #   attached, :replace — a different build is attached and gets swapped out.
    def self.build_action(attached:, requested:)
      return :attach if attached.nil?

      attached.to_i == requested.to_i ? :keep : :replace
    end

    # Per-locale promotional-text convergence: keep a manually entered text,
    # fill an empty one from the live version, note when there is nothing to
    # copy from. Returns {locale => {action: :keep|:copy|:none, text: ...}}.
    def self.promotional_text_plan(locales:, edit:, live:)
      locales.to_h do |locale|
        edit_text = presence((edit || {})[locale])
        live_text = presence((live || {})[locale])
        if edit_text
          [locale, { action: :keep, text: edit_text }]
        elsif live_text
          [locale, { action: :copy, text: live_text }]
        else
          [locale, { action: :none, text: nil }]
        end
      end
    end

    class << self
      private

      def presence(text)
        value = text.to_s.strip
        value.empty? ? nil : value
      end

      def check_build(ctx, errors)
        if ctx.ref_given
          unless ctx.build_state == :absent
            errors << "build #{ctx.requested_build} already exists on App Store Connect — drop --ref to submit the existing build, or pick a new --build to rebuild"
          end
          return
        end

        case ctx.build_state
        when :processed then nil
        when :absent
          errors << "build #{ctx.requested_build} for #{ctx.requested_version} not found on App Store Connect — pass --ref to build and upload it first"
        when :processing
          errors << "build #{ctx.requested_build} is still processing on App Store Connect — retry in a few minutes"
        when :failed
          errors << "build #{ctx.requested_build} failed processing on App Store Connect — upload a new build with a new --build number"
        else
          errors << "unknown build state #{ctx.build_state.inspect} for build #{ctx.requested_build}"
        end
      end

      def check_version_state(ctx, errors, warnings)
        if ctx.live_version && ctx.live_version == ctx.requested_version
          errors << "version #{ctx.requested_version} is already live on the App Store"
          return
        end

        state = ctx.version_state
        return if state.nil? # no in-flight version — deliver will create one

        if EDITABLE_STATES.include?(state)
          if ctx.version_string && ctx.version_string != ctx.requested_version
            warnings << "App Store Connect has version #{ctx.version_string} in #{state} — it will be renamed to #{ctx.requested_version}"
          end
        elsif IN_REVIEW_STATES.include?(state)
          errors << "version #{ctx.version_string} is already submitted for review (#{state}) — cancel the submission in App Store Connect first"
        elsif PENDING_RELEASE_STATES.include?(state)
          errors << "version #{ctx.version_string} is approved and awaiting release (#{state}) — release it in App Store Connect first"
        else
          errors << "version #{ctx.version_string} is in state #{state} — resolve it in App Store Connect first"
        end
      end
    end
  end
end
