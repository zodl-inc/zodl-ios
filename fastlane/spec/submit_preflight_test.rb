require "minitest/autorun"
require "zodl/submit_preflight"

class ZodlSubmitPreflightTest < Minitest::Test
  def facts(**overrides)
    base = {
      variant: "appstore", requested_version: "3.8.0", requested_build: 5,
      ref_given: false, build_state: :processed, version_state: nil,
      version_string: nil, live_version: "3.7.4", whats_new_errors: []
    }
    Zodl::SubmitPreflight::Context.new(**base.merge(overrides))
  end

  def test_clean_submit_only_context_passes
    report = Zodl::SubmitPreflight.check(facts)
    assert report.ok?, report.errors.join("; ")
    assert_empty report.warnings
  end

  def test_clean_build_path_context_passes
    report = Zodl::SubmitPreflight.check(facts(ref_given: true, build_state: :absent))
    assert report.ok?, report.errors.join("; ")
  end

  def test_non_appstore_variant_blocks
    report = Zodl::SubmitPreflight.check(facts(variant: "internal"))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("only supported for the appstore variant") })
  end

  def test_malformed_version_blocks
    report = Zodl::SubmitPreflight.check(facts(requested_version: "3.8"))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("X.Y.Z") })
  end

  def test_ref_given_with_existing_build_blocks
    report = Zodl::SubmitPreflight.check(facts(ref_given: true, build_state: :processed))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("already exists") })
    assert(report.errors.any? { |e| e.include?("drop --ref") })
  end

  def test_missing_build_without_ref_blocks
    report = Zodl::SubmitPreflight.check(facts(ref_given: false, build_state: :absent))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("not found") })
    assert(report.errors.any? { |e| e.include?("pass --ref") })
  end

  def test_processing_build_blocks
    report = Zodl::SubmitPreflight.check(facts(ref_given: false, build_state: :processing))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("still processing") })
  end

  def test_failed_build_blocks
    report = Zodl::SubmitPreflight.check(facts(ref_given: false, build_state: :failed))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("failed processing") })
  end

  def test_editable_state_with_matching_version_passes
    %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED].each do |state|
      report = Zodl::SubmitPreflight.check(facts(version_state: state, version_string: "3.8.0"))
      assert report.ok?, "#{state}: #{report.errors.join('; ')}"
      assert_empty report.warnings, state
    end
  end

  def test_editable_state_with_different_version_warns_about_rename
    report = Zodl::SubmitPreflight.check(facts(version_state: "PREPARE_FOR_SUBMISSION", version_string: "3.9.0"))
    assert report.ok?, report.errors.join("; ")
    assert(report.warnings.any? { |w| w.include?("renamed to 3.8.0") })
  end

  def test_in_review_state_blocks
    %w[WAITING_FOR_REVIEW IN_REVIEW READY_FOR_REVIEW].each do |state|
      report = Zodl::SubmitPreflight.check(facts(version_state: state, version_string: "3.8.0"))
      refute report.ok?, state
      assert(report.errors.any? { |e| e.include?("already submitted for review") }, state)
      assert(report.errors.any? { |e| e.include?("cancel") }, state)
    end
  end

  def test_pending_developer_release_blocks
    report = Zodl::SubmitPreflight.check(facts(version_state: "PENDING_DEVELOPER_RELEASE", version_string: "3.7.5"))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("awaiting release") })
  end

  def test_unknown_version_state_fails_closed
    report = Zodl::SubmitPreflight.check(facts(version_state: "WAITING_FOR_EXPORT_COMPLIANCE"))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("resolve it in App Store Connect") })
  end

  def test_already_live_version_blocks
    report = Zodl::SubmitPreflight.check(facts(live_version: "3.8.0"))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("already live") })
  end

  def test_whats_new_errors_are_propagated
    report = Zodl::SubmitPreflight.check(facts(whats_new_errors: ["locale es-ES: boom"]))
    refute report.ok?
    assert_includes report.errors, "locale es-ES: boom"
  end

  def test_build_action
    assert_equal :attach, Zodl::SubmitPreflight.build_action(attached: nil, requested: 5)
    assert_equal :keep, Zodl::SubmitPreflight.build_action(attached: 5, requested: 5)
    assert_equal :replace, Zodl::SubmitPreflight.build_action(attached: 4, requested: 5)
    assert_equal :keep, Zodl::SubmitPreflight.build_action(attached: "5", requested: 5)
  end

  def test_promotional_text_plan
    plan = Zodl::SubmitPreflight.promotional_text_plan(
      locales: %w[en-US es-ES de-DE fr-FR ja],
      edit: { "en-US" => "New edit text", "es-ES" => "", "de-DE" => "", "fr-FR" => "   " },
      live: { "en-US" => "Old live text", "es-ES" => "Live only", "de-DE" => "", "fr-FR" => "Live for fr" }
    )

    assert_equal({ action: :keep, text: "New edit text" }, plan["en-US"])
    assert_equal({ action: :copy, text: "Live only" }, plan["es-ES"])
    assert_equal({ action: :none, text: nil }, plan["de-DE"])
    assert_equal({ action: :copy, text: "Live for fr" }, plan["fr-FR"])
    assert_equal({ action: :none, text: nil }, plan["ja"])
  end
end
