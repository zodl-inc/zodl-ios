require "minitest/autorun"
require "zodl/build_number"

class ZodlBuildNumberTest < Minitest::Test
  def test_next_build_is_ok
    assert Zodl::BuildNumber.validate(requested: 3, latest: 2).ok?
  end

  def test_first_build_with_no_history_is_ok
    r = Zodl::BuildNumber.validate(requested: 1, latest: nil)
    assert r.ok?
    assert_nil r.warning
  end

  def test_duplicate_is_error
    r = Zodl::BuildNumber.validate(requested: 2, latest: 2)
    refute r.ok?
    assert_match(/already exists/, r.error)
  end

  def test_regression_is_error
    r = Zodl::BuildNumber.validate(requested: 1, latest: 5)
    refute r.ok?
    assert_match(/lower than/, r.error)
  end

  def test_gap_is_warning_not_error
    r = Zodl::BuildNumber.validate(requested: 5, latest: 2)
    assert r.ok?
    assert_match(/skips numbers/, r.warning)
  end

  def test_non_integer_is_error
    refute Zodl::BuildNumber.validate(requested: "abc", latest: 2).ok?
  end

  def test_zero_is_error
    refute Zodl::BuildNumber.validate(requested: 0, latest: nil).ok?
  end

  def test_nil_latest_skips_train_comparison_entirely
    r = Zodl::BuildNumber.validate(requested: 7, latest: nil)
    assert r.ok?
    assert_nil r.warning
  end

  def test_nil_latest_still_rejects_zero_and_garbage
    refute Zodl::BuildNumber.validate(requested: 0, latest: nil).ok?
    refute Zodl::BuildNumber.validate(requested: "x", latest: nil).ok?
  end
end
