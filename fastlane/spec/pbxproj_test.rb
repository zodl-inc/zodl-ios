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
    			};
    			name = Debug;
    		};
    		AAAAAAAAAAAAAAAAAAAAAAA2 /* Release-Testflight */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 3.7.2;
    			};
    			name = "Release-Testflight";
    		};
    		BBBBBBBBBBBBBBBBBBBBBBB1 /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 3.7.1;
    				SDKROOT = macosx;
    			};
    			name = Debug;
    		};
    		BBBBBBBBBBBBBBBBBBBBBBB2 /* Release-AppStore */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 3.7.1;
    			};
    			name = "Release-AppStore";
    		};
    		CCCCCCCCCCCCCCCCCCCCCCC1 /* Debug */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 1.0.0;
    			};
    			name = Debug;
    		};
    		CCCCCCCCCCCCCCCCCCCCCCC2 /* Release */ = {
    			isa = XCBuildConfiguration;
    			buildSettings = {
    				MARKETING_VERSION = 2.0.0;
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
end
