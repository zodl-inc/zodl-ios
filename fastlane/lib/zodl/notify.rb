# frozen_string_literal: true

require "open3"

module Zodl
  # Posts a macOS desktop notification (banner + sound) when a release finishes.
  #
  # Delivery uses the built-in `osascript` / AppleScript `display notification`
  # command — a first-party macOS facility — so there is no third-party notifier
  # binary to fall out of date (`terminal-notifier`, the usual gem for this, has
  # had no release since 2016).
  #
  # Every entry point is failure-safe by contract: posting a notification must
  # never change the release lane's outcome, so a missing or broken notifier and
  # any delivery error are swallowed. Notifications are skipped under CI and when
  # `ZODL_NOTIFY` is set to a falsey value.
  module Notify
    SUCCESS_SOUND = "Ping"
    FAILURE_SOUND = "Basso"
    DISABLED_VALUES = ["0", "false", "no", "off"].freeze

    module_function

    # Builds the notification fields for `event`. Pure (no I/O), so the wording
    # and sound selection are unit-testable.
    #
    #   event    :success | :submit_success | :dry_run_ok | :failure
    #   reason   failure detail (only its first line is shown); used by :failure
    #   outcomes per-variant result strings shown on success
    #
    # Returns { title:, subtitle:, message:, sound: }.
    def payload(event:, variants: [], version: nil, build: nil, reason: nil, outcomes: [])
      subtitle = describe(variants, version, build)
      case event
      when :success
        message = outcomes.empty? ? "Uploaded to TestFlight" : outcomes.join("; ")
        { title: "ZODL release ✅", subtitle: subtitle, message: message, sound: SUCCESS_SOUND }
      when :submit_success
        { title: "ZODL release ✅", subtitle: subtitle, message: "Submitted to App Review", sound: SUCCESS_SOUND }
      when :dry_run_ok
        { title: "ZODL dry run ✅", subtitle: subtitle, message: "Preflight passed", sound: SUCCESS_SOUND }
      when :failure
        { title: "ZODL release ❌", subtitle: subtitle, message: first_line(reason) || "Release failed", sound: FAILURE_SOUND }
      else
        raise ArgumentError, "unknown notification event: #{event.inspect}"
      end
    end

    # Posts a notification for `event`. Failure-safe: returns false (never raises)
    # when notifications are disabled or delivery fails, and true when a
    # notification was handed to the notifier. `runner` is injectable so tests can
    # capture the payload without showing a real banner.
    def post(event:, variants: [], version: nil, build: nil, reason: nil, outcomes: [], runner: nil)
      return false unless enabled?

      fields = payload(event: event, variants: variants, version: version, build: build, reason: reason, outcomes: outcomes)
      (runner || method(:deliver)).call(fields)
      true
    rescue StandardError
      false
    end

    # Notifications make sense only on an interactive Mac. Skip them under CI and
    # when explicitly disabled via ZODL_NOTIFY.
    def enabled?
      return false if present?(ENV["CI"])

      !DISABLED_VALUES.include?(ENV["ZODL_NOTIFY"].to_s.strip.downcase)
    end

    # --- internals ---------------------------------------------------------

    def describe(variants, version, build)
      names = Array(variants).join(", ")
      ver = [version, build && "(#{build})"].compact.join(" ")
      [names, ver].reject { |part| part.to_s.empty? }.join(" ")
    end

    def first_line(text)
      line = text.to_s.lines.first.to_s.strip
      line.empty? ? nil : line
    end

    def present?(value)
      !value.to_s.strip.empty?
    end

    # Hands the notification to macOS via osascript. Open3 in array form (no
    # shell) keeps osascript's own output out of the lane log and avoids any
    # shell interpolation; the values are escaped as AppleScript string literals.
    def deliver(fields)
      script = +"display notification #{quote(fields[:message])} with title #{quote(fields[:title])}"
      script << " subtitle #{quote(fields[:subtitle])}" if present?(fields[:subtitle])
      script << " sound name #{quote(fields[:sound])}" if present?(fields[:sound])
      Open3.capture3("/usr/bin/osascript", "-e", script)
    end

    # An AppleScript string literal: double-quoted, with \ and " backslash-escaped.
    def quote(value)
      %("#{value.to_s.gsub(/[\\"]/) { |char| "\\#{char}" }}")
    end
  end
end
