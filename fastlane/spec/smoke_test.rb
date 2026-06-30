require "minitest/autorun"

class SmokeTest < Minitest::Test
  def test_harness_runs
    assert_equal 4, 2 + 2
  end
end
