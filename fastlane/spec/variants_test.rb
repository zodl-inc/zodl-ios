require "minitest/autorun"
require "zodl/variants"

class ZodlVariantsTest < Minitest::Test
  def test_valid_accepts_atomic_and_combined
    %w[internal testnet appstore internal-testnet].each { |v| assert Zodl::Variants.valid?(v), v }
  end

  def test_valid_rejects_unknown
    refute Zodl::Variants.valid?("production")
    refute Zodl::Variants.valid?("")
  end

  def test_expand_atomic_is_singleton
    assert_equal ["appstore"], Zodl::Variants.expand("appstore")
  end

  def test_expand_combined
    assert_equal %w[internal testnet], Zodl::Variants.expand("internal-testnet")
  end

  def test_expand_unknown_raises
    assert_raises(ArgumentError) { Zodl::Variants.expand("nope") }
  end

  def test_config_internal_mapping
    cfg = Zodl::Variants.config("internal")
    assert_equal "zodl-internal", cfg[:scheme]
    assert_equal "zodl-internal", cfg[:target]
    assert_equal "Release-Testflight", cfg[:configuration]
    assert_equal "co.electriccoin.secant-testnet", cfg[:app_identifier]
  end

  def test_config_appstore_mapping
    cfg = Zodl::Variants.config("appstore")
    assert_equal "zodl-production", cfg[:target]
    assert_equal "Release-AppStore", cfg[:configuration]
    assert_equal "co.electriccoin.secant-mainnet", cfg[:app_identifier]
  end

  def test_config_rejects_combined
    assert_raises(ArgumentError) { Zodl::Variants.config("internal-testnet") }
  end
end
