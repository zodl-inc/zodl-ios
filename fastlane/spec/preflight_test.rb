require "minitest/autorun"
require "zodl/preflight"

class ZodlPreflightTest < Minitest::Test
  def facts(**overrides)
    base = {
      variant: "ios-appstore", requested_version: "3.8.0", requested_build: 3,
      project_version: "3.8.0", branch_version: "3.8.0", latest_build: 2,
      ref_on_origin: true, dirty_tree: false, partner_keys_error: nil,
      xcode_ok: true, signing_identity_ok: true, missing_signing_identities: [],
      sdk_checkout_ok: true, ffi_slice_ok: true, sdk_dirty: false
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

  def test_missing_identities_block_one_error_each
    report = Zodl::Preflight.check(facts(missing_signing_identities: ["Apple Distribution", "Mac Installer Distribution"]))
    refute report.ok?
    assert_equal 2, report.errors.count { |e| e.include?("missing signing identity") }
    assert(report.errors.any? { |e| e.include?("Mac Installer Distribution") })
  end

  def test_missing_sdk_checkout_blocks
    report = Zodl::Preflight.check(facts(sdk_checkout_ok: false, ffi_slice_ok: false))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("ZcashLightClientKit") })
    # No separate FFI complaint when the whole checkout is absent.
    refute(report.errors.any? { |e| e.include?("libzcashlc") })
  end

  def test_bad_ffi_slice_blocks_with_rebuild_hint
    report = Zodl::Preflight.check(facts(ffi_slice_ok: false))
    refute report.ok?
    assert(report.errors.any? { |e| e.include?("rebuild-local-ffi") })
  end

  def test_dirty_sdk_is_warning_only
    report = Zodl::Preflight.check(facts(sdk_dirty: true))
    assert report.ok?
    assert(report.warnings.any? { |w| w.include?("ZcashLightClientKit") })
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
