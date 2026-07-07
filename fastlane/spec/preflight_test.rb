require "minitest/autorun"
require "zodl/preflight"

class ZodlPreflightTest < Minitest::Test
  def facts(**overrides)
    base = {
      variant: "appstore", requested_version: "3.8.0", requested_build: 3,
      project_version: "3.8.0", branch_version: "3.8.0", latest_build: 2,
      ref_on_origin: true, dirty_tree: false, partner_keys_error: nil,
      xcode_ok: true, signing_identity_ok: true
    }
    Zodl::Preflight::Context.new(**base.merge(overrides))
  end

  def test_clean_context_passes
    report = Zodl::Preflight.check(facts)
    assert report.ok?, report.errors.join("; ")
    assert_empty report.warnings
  end

  def test_version_project_mismatch_blocks
    report = Zodl::Preflight.check(facts(requested_version: "3.7.0", branch_version: nil))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("MARKETING_VERSION") })
  end

  def test_branch_mismatch_blocks
    report = Zodl::Preflight.check(facts(branch_version: "3.9.0"))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("release branch") })
  end

  def test_duplicate_build_blocks
    report = Zodl::Preflight.check(facts(requested_build: 2))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("already exists") })
  end

  def test_unpushed_ref_blocks
    report = Zodl::Preflight.check(facts(ref_on_origin: false))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("origin") })
  end

  def test_missing_partner_keys_blocks
    report = Zodl::Preflight.check(facts(partner_keys_error: "PartnerKeys.plist: missing key 'cbProjectId'"))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("missing key 'cbProjectId'") })
  end

  def test_dirty_tree_is_warning_only
    report = Zodl::Preflight.check(facts(dirty_tree: true))
    assert report.ok?
    assert(report.warnings.any? { |w| w.include?("uncommitted") })
  end

  def test_unknown_variant_short_circuits
    report = Zodl::Preflight.check(facts(variant: "bogus"))
    refute report.ok?
    assert_equal 1, report.errors.length
  end

  def local_pkg(**overrides)
    {
      path: "../ZcashLightClientKit", resolved: "/Users/dev/ZcashLightClientKit",
      exists: true, git: "6bfe97fc", dirty: false
    }.merge(overrides)
  end

  def test_missing_local_package_blocks
    report = Zodl::Preflight.check(facts(local_packages: [local_pkg(exists: false, git: nil, dirty: nil)]))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("../ZcashLightClientKit") && e.include?("not found") })
  end

  def test_local_package_warns_with_git_state
    report = Zodl::Preflight.check(facts(local_packages: [local_pkg]))
    assert report.ok?
    assert(report.warnings.any? { |w| w.include?("6bfe97fc") && w.include?("clean") })
  end

  def test_dirty_local_package_warning_mentions_uncommitted_changes
    report = Zodl::Preflight.check(facts(local_packages: [local_pkg(dirty: true)]))
    assert report.ok?
    assert(report.warnings.any? { |w| w.include?("UNCOMMITTED") })
  end

  def test_non_git_local_package_warns
    report = Zodl::Preflight.check(facts(local_packages: [local_pkg(git: nil, dirty: nil)]))
    assert report.ok?
    assert(report.warnings.any? { |w| w.include?("not a git repository") })
  end

  def test_no_local_packages_is_silent
    report = Zodl::Preflight.check(facts(local_packages: []))
    assert report.ok?
    assert_empty report.warnings
  end
end
