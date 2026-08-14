# frozen_string_literal: true

require "minitest/autorun"
require "zodl/notify"

class ZodlNotifyTest < Minitest::Test
  # These tests drive notification gating through ENV, so snapshot and force a
  # known enabled state. CI sets CI=true, which would otherwise disable
  # notifications and make the delivery assertions fail when run on a runner.
  def setup
    @saved_ci = ENV["CI"]
    @saved_flag = ENV["ZODL_NOTIFY"]
    ENV.delete("CI")
    ENV.delete("ZODL_NOTIFY")
  end

  def teardown
    restore("CI", @saved_ci)
    restore("ZODL_NOTIFY", @saved_flag)
  end

  # --- payload -----------------------------------------------------------

  def test_payload_success_uses_ping_and_testflight_message
    fields = Zodl::Notify.payload(event: :success, variants: ["ios-appstore"], version: "3.8.0", build: 3)
    assert_equal "ZODL release ✅", fields[:title]
    assert_equal "ios-appstore 3.8.0 (3)", fields[:subtitle]
    assert_equal "Uploaded to TestFlight", fields[:message]
    assert_equal "Ping", fields[:sound]
  end

  def test_payload_dry_run_uses_ping_and_preflight_message
    fields = Zodl::Notify.payload(event: :dry_run_ok, variants: ["ios-appstore"], version: "3.8.0", build: 3)
    assert_equal "ZODL dry run ✅", fields[:title]
    assert_equal "Preflight passed", fields[:message]
    assert_equal "Ping", fields[:sound]
  end

  def test_payload_submit_success_uses_ping_and_app_review_message
    fields = Zodl::Notify.payload(event: :submit_success, variants: ["appstore"], version: "3.8.0", build: 5)
    assert_equal "ZODL release ✅", fields[:title]
    assert_equal "appstore 3.8.0 (5)", fields[:subtitle]
    assert_equal "Submitted to App Review", fields[:message]
    assert_equal "Ping", fields[:sound]
  end

  def test_payload_failure_uses_basso_and_first_line_of_reason
    fields = Zodl::Notify.payload(
      event: :failure, variants: ["ios-appstore"], version: "3.8.0", build: 3,
      reason: "Preflight failed for ios-appstore — aborting.\nsecond line ignored"
    )
    assert_equal "ZODL release ❌", fields[:title]
    assert_equal "Preflight failed for ios-appstore — aborting.", fields[:message]
    assert_equal "Basso", fields[:sound]
  end

  def test_payload_failure_without_reason_has_fallback_message
    fields = Zodl::Notify.payload(event: :failure)
    assert_equal "Release failed", fields[:message]
    assert_equal "", fields[:subtitle]
  end

  def test_payload_joins_multiple_variants
    fields = Zodl::Notify.payload(event: :success, variants: ["ios-internal", "ios-testnet"], version: "3.8.0", build: 4)
    assert_equal "ios-internal, ios-testnet 3.8.0 (4)", fields[:subtitle]
  end

  def test_payload_rejects_unknown_event
    assert_raises(ArgumentError) { Zodl::Notify.payload(event: :bogus) }
  end

  def test_success_message_uses_outcomes_when_given
    fields = Zodl::Notify.payload(event: :success, variants: %w[mac-internal mac-internal-dmg], version: "3.8.0", build: 1,
                                  outcomes: ["mac-internal → TestFlight", "mac-internal-dmg → DMG at /tmp/ZODL-internal-3.8.0-1.dmg"])
    assert_equal "mac-internal → TestFlight; mac-internal-dmg → DMG at /tmp/ZODL-internal-3.8.0-1.dmg", fields[:message]
  end

  def test_success_message_defaults_without_outcomes
    fields = Zodl::Notify.payload(event: :success, variants: ["ios-internal"], version: "3.8.0", build: 1)
    assert_equal "Uploaded to TestFlight", fields[:message]
  end

  # --- enabled? ----------------------------------------------------------

  def test_enabled_by_default
    assert Zodl::Notify.enabled?
  end

  def test_disabled_under_ci
    ENV["CI"] = "true"
    refute Zodl::Notify.enabled?
  end

  def test_disabled_when_flag_is_falsey
    ["0", "false", "no", "off", "OFF", " false "].each do |value|
      ENV["ZODL_NOTIFY"] = value
      refute Zodl::Notify.enabled?, "expected disabled for ZODL_NOTIFY=#{value.inspect}"
    end
  end

  def test_enabled_when_flag_is_truthy
    ENV["ZODL_NOTIFY"] = "1"
    assert Zodl::Notify.enabled?
  end

  # --- post (failure-safe, injectable runner) ----------------------------

  def test_post_invokes_runner_with_payload
    captured = nil
    result = Zodl::Notify.post(
      event: :success, variants: ["ios-appstore"], version: "3.8.0", build: 3,
      runner: ->(fields) { captured = fields }
    )
    assert result
    assert_equal "ZODL release ✅", captured[:title]
    assert_equal "Ping", captured[:sound]
  end

  def test_post_submit_success_invokes_runner_with_correct_payload
    captured = nil
    result = Zodl::Notify.post(
      event: :submit_success, variants: ["appstore"], version: "3.8.0", build: 5,
      runner: ->(fields) { captured = fields }
    )
    assert result
    assert_equal "Submitted to App Review", captured[:message]
  end

  def test_post_skips_delivery_when_disabled
    ENV["ZODL_NOTIFY"] = "0"
    called = false
    result = Zodl::Notify.post(event: :success, runner: ->(_fields) { called = true })
    refute result
    refute called
  end

  def test_post_swallows_runner_errors
    result = Zodl::Notify.post(event: :failure, reason: "boom", runner: ->(_fields) { raise "notifier exploded" })
    refute result
  end

  private

  def restore(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
