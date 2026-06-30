require "minitest/autorun"
require "zodl/version"

class ZodlVersionTest < Minitest::Test
  def test_valid_accepts_x_y_z
    assert Zodl::Version.valid?("3.8.0")
    assert Zodl::Version.valid?("10.0.123")
  end

  def test_valid_rejects_malformed
    refute Zodl::Version.valid?("3.8")
    refute Zodl::Version.valid?("3.8.0-beta")
    refute Zodl::Version.valid?("v3.8.0")
    refute Zodl::Version.valid?(nil)
    refute Zodl::Version.valid?(380)
  end

  def test_from_branch_extracts_release_version
    assert_equal "3.8.0", Zodl::Version.from_branch("release/3.8.0")
  end

  def test_from_branch_returns_nil_for_non_release
    assert_nil Zodl::Version.from_branch("main")
    assert_nil Zodl::Version.from_branch("feature/release/3.8.0")
    assert_nil Zodl::Version.from_branch("release/3.8")
  end
end
