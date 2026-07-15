require "minitest/autorun"
require "zodl/pbxproj"

class ZodlPbxprojTest < Minitest::Test
  # Two targets whose versions deliberately differ (the mac app is versioned
  # independently of iOS), plus one target whose own configs disagree.
  FIXTURE = <<~PBX
    		AAAAAAAAAAAAAAAAAAAAAAA1 /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 3.7.2;
    				PRODUCT_BUNDLE_IDENTIFIER = "co.example.ios";
    				PRODUCT_NAME = "$(TARGET_NAME)";
    			};
    			name = Debug;
    		};
    		AAAAAAAAAAAAAAAAAAAAAAA2 /* Release-Testflight */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 3.7.2;
    				PRODUCT_NAME = "$(TARGET_NAME)";
    			};
    			name = "Release-Testflight";
    		};
    		BBBBBBBBBBBBBBBBBBBBBBB1 /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				CURRENT_PROJECT_VERSION = 6;
    				MARKETING_VERSION = 3.7.1;
    				PRODUCT_NAME = "Zodl Testnet";
    				SDKROOT = macosx;
    			};
    			name = Debug;
    		};
    		BBBBBBBBBBBBBBBBBBBBBBB2 /* Release-AppStore */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				CURRENT_PROJECT_VERSION = 6;
    				MARKETING_VERSION = 3.7.1;
    				PRODUCT_NAME = "Zodl Testnet";
    			};
    			name = "Release-AppStore";
    		};
    		CCCCCCCCCCCCCCCCCCCCCCC1 /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 1.0.0;
    				PRODUCT_NAME = One;
    			};
    			name = Debug;
    		};
    		CCCCCCCCCCCCCCCCCCCCCCC2 /* Release */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 2.0.0;
    				PRODUCT_NAME = Two;
    			};
    			name = Release;
    		};
    		DDDDDDDDDDDDDDDDDDDDDDD1 /* Build configuration list for PBXNativeTarget "zodl-internal" */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				AAAAAAAAAAAAAAAAAAAAAAA1 /* Debug */,
    				AAAAAAAAAAAAAAAAAAAAAAA2 /* Release-Testflight */,
    			);
    		};
    		DDDDDDDDDDDDDDDDDDDDDDD2 /* Build configuration list for PBXNativeTarget "zodlmac-internal" */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				BBBBBBBBBBBBBBBBBBBBBBB1 /* Debug */,
    				BBBBBBBBBBBBBBBBBBBBBBB2 /* Release-AppStore */,
    			);
    		};
    		DDDDDDDDDDDDDDDDDDDDDDD3 /* Build configuration list for PBXNativeTarget "disagreeing" */ = {
    			isa = XCConfigurationList;
    			buildConfigurations = (
    				CCCCCCCCCCCCCCCCCCCCCCC1 /* Debug */,
    				CCCCCCCCCCCCCCCCCCCCCCC2 /* Release */,
    			);
    		};
  PBX

  def versions(target)
    Zodl::Pbxproj.marketing_versions(FIXTURE, target: target)
  end

  def test_reads_the_named_targets_version
    assert_equal ["3.7.2"], versions("zodl-internal")
  end

  def test_mac_target_version_is_independent_of_ios
    # The regression that motivated this parser: the mac target carries a
    # different version than iOS, and the check must see the mac value.
    assert_equal ["3.7.1"], versions("zodlmac-internal")
  end

  def test_disagreeing_configs_return_all_values_sorted
    assert_equal ["1.0.0", "2.0.0"], versions("disagreeing")
  end

  def test_unknown_target_returns_empty
    assert_equal [], versions("nope")
  end

  def test_set_setting_rewrites_only_the_named_targets_configs
    updated = Zodl::Pbxproj.set_setting(FIXTURE, target: "zodlmac-internal", key: "MARKETING_VERSION", value: "3.8.0")
    assert_equal ["3.8.0"], Zodl::Pbxproj.marketing_versions(updated, target: "zodlmac-internal")
    # The other targets keep their values.
    assert_equal ["3.7.2"], Zodl::Pbxproj.marketing_versions(updated, target: "zodl-internal")
    assert_equal ["1.0.0", "2.0.0"], Zodl::Pbxproj.marketing_versions(updated, target: "disagreeing")
  end

  def test_set_setting_handles_other_keys
    updated = Zodl::Pbxproj.set_setting(FIXTURE, target: "zodlmac-internal", key: "CURRENT_PROJECT_VERSION", value: "7")
    assert_equal 2, updated.scan("CURRENT_PROJECT_VERSION = 7;").length
    refute_includes updated, "CURRENT_PROJECT_VERSION = 6;"
  end

  def test_set_setting_leaves_configs_without_the_key_untouched
    # The iOS fixture configs carry no CURRENT_PROJECT_VERSION — nothing is
    # added or changed for them.
    updated = Zodl::Pbxproj.set_setting(FIXTURE, target: "zodl-internal", key: "CURRENT_PROJECT_VERSION", value: "9")
    assert_equal FIXTURE, updated
  end

  def test_set_setting_rejects_unknown_target
    assert_raises(ArgumentError) do
      Zodl::Pbxproj.set_setting(FIXTURE, target: "nope", key: "MARKETING_VERSION", value: "1.0.0")
    end
  end

  def test_product_name_strips_quotes_around_names_with_spaces
    assert_equal "Zodl Testnet", Zodl::Pbxproj.product_name(FIXTURE, target: "zodlmac-internal")
  end

  def test_product_name_resolves_target_name_macro
    assert_equal "zodl-internal", Zodl::Pbxproj.product_name(FIXTURE, target: "zodl-internal")
  end

  def test_product_name_raises_when_configs_disagree
    assert_raises(ArgumentError) { Zodl::Pbxproj.product_name(FIXTURE, target: "disagreeing") }
  end

  def test_product_name_nil_for_unknown_target
    assert_nil Zodl::Pbxproj.product_name(FIXTURE, target: "nope")
  end
end
