require "minitest/autorun"
require "zodl/signing"

class ZodlSigningTest < Minitest::Test
  APPLE_DIST = '1) ABC123 "Apple Distribution: Electric Coin Co. (RLPRR8CPQG)"'
  IPHONE_DIST = '1) ABC123 "iPhone Distribution: Electric Coin Co. (RLPRR8CPQG)"'
  MAC_INSTALLER = '2) DEF456 "Mac Installer Distribution: Electric Coin Co. (RLPRR8CPQG)"'
  DEV_ID = '3) FED789 "Developer ID Application: Electric Coin Co. (RLPRR8CPQG)"'

  def missing(platform, channel, installed)
    Zodl::Signing.missing_identities(platform: platform, channel: channel, installed: installed)
  end

  def test_ios_satisfied_by_apple_distribution
    assert_empty missing(:ios, :testflight, APPLE_DIST)
    assert_empty missing(:ios, :appstore, APPLE_DIST)
  end

  def test_ios_satisfied_by_legacy_iphone_distribution
    assert_empty missing(:ios, :testflight, IPHONE_DIST)
  end

  def test_ios_missing_everything
    assert_equal ["Apple Distribution"], missing(:ios, :testflight, "")
  end

  def test_mac_testflight_needs_both
    assert_equal ["Apple Distribution", "Mac Installer Distribution"], missing(:macos, :testflight, "")
    assert_equal ["Mac Installer Distribution"], missing(:macos, :testflight, APPLE_DIST)
    assert_empty missing(:macos, :testflight, APPLE_DIST + "\n" + MAC_INSTALLER)
  end

  def test_mac_dmg_needs_developer_id
    assert_equal ["Developer ID Application"], missing(:macos, :dmg, APPLE_DIST)
    assert_empty missing(:macos, :dmg, DEV_ID)
  end

  def test_unknown_combination_raises
    assert_raises(ArgumentError) { missing(:macos, :appstore, "") }
  end
end
