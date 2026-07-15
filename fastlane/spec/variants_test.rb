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

  def test_all_variants_declare_platform
    %w[internal testnet appstore].each { |v| assert_equal :ios, Zodl::Variants.config(v)[:platform], v }
    %w[mac-internal mac-internal-dmg mac-testnet mac-testnet-dmg].each { |v| assert_equal :macos, Zodl::Variants.config(v)[:platform], v }
  end

  def test_config_mac_internal_mapping
    cfg = Zodl::Variants.config("mac-internal")
    assert_equal "zodlmac-internal", cfg[:scheme]
    assert_equal "zodlmac-internal", cfg[:target]
    assert_equal "Release-Testflight", cfg[:configuration]
    assert_equal "co.electriccoin.secant-testnet", cfg[:app_identifier]
    assert_equal :testflight, cfg[:channel]
  end

  def test_config_mac_internal_dmg_mapping
    cfg = Zodl::Variants.config("mac-internal-dmg")
    assert_equal "zodlmac-internal", cfg[:scheme]
    assert_equal "Release-AppStore", cfg[:configuration]
    assert_equal "co.electriccoin.secant-testnet", cfg[:app_identifier]
    assert_equal :dmg, cfg[:channel]
  end

  def test_config_mac_testnet_mapping
    cfg = Zodl::Variants.config("mac-testnet")
    assert_equal "zodlmac-testnet", cfg[:scheme]
    assert_equal "zodlmac-testnet", cfg[:target]
    assert_equal "Release-Testflight", cfg[:configuration]
    assert_equal "co.ecc.zashi-testnet", cfg[:app_identifier]
    assert_equal :testflight, cfg[:channel]
  end

  def test_config_mac_testnet_dmg_mapping
    cfg = Zodl::Variants.config("mac-testnet-dmg")
    assert_equal "zodlmac-testnet", cfg[:target]
    assert_equal "Release-AppStore", cfg[:configuration]
    assert_equal "co.ecc.zashi-testnet", cfg[:app_identifier]
    assert_equal :dmg, cfg[:channel]
  end

  def test_mac_variants_declare_flavor
    assert_equal "internal", Zodl::Variants.config("mac-internal")[:flavor]
    assert_equal "internal", Zodl::Variants.config("mac-internal-dmg")[:flavor]
    assert_equal "testnet", Zodl::Variants.config("mac-testnet")[:flavor]
    assert_equal "testnet", Zodl::Variants.config("mac-testnet-dmg")[:flavor]
  end

  def test_mac_dmg_no_longer_exists
    refute Zodl::Variants.valid?("mac-dmg")
    assert_raises(ArgumentError) { Zodl::Variants.config("mac-dmg") }
  end

  def test_expand_mac_combined
    assert_equal %w[mac-internal mac-internal-dmg mac-testnet mac-testnet-dmg], Zodl::Variants.expand("mac")
  end

  def test_valid_accepts_mac_variants
    %w[mac-internal mac-internal-dmg mac-testnet mac-testnet-dmg mac].each { |v| assert Zodl::Variants.valid?(v), v }
  end

  def test_bump_targets_all_covers_every_app_target_once
    assert_equal %w[zodl-internal zodl-testnet zodl-production zodlmac-internal zodlmac-testnet],
                 Zodl::Variants.bump_targets("all")
  end

  def test_bump_targets_ios_covers_only_ios_targets
    assert_equal %w[zodl-internal zodl-testnet zodl-production],
                 Zodl::Variants.bump_targets("ios")
  end

  def test_bump_targets_accepts_an_exact_target_name
    assert_equal ["zodlmac-internal"], Zodl::Variants.bump_targets("zodlmac-internal")
  end

  def test_bump_targets_rejects_unknown_selector_naming_the_options
    error = assert_raises(ArgumentError) { Zodl::Variants.bump_targets("zodl-mac") }
    assert_match(/zodlmac-internal/, error.message)
    assert_match(/ios/, error.message)
    assert_match(/all/, error.message)
    assert_match(/'mac'/, error.message)
  end

  def test_bump_targets_mac_covers_only_mac_targets
    assert_equal %w[zodlmac-internal zodlmac-testnet], Zodl::Variants.bump_targets("mac")
  end
end
