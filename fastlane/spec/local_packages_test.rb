require "minitest/autorun"
require "zodl/local_packages"

class ZodlLocalPackagesTest < Minitest::Test
  def test_parses_bare_relative_path
    pbxproj = <<~PBX
      /* Begin XCLocalSwiftPackageReference section */
      \t\t34FC670D2FFD1644004175E0 /* XCLocalSwiftPackageReference "../ZcashLightClientKit" */ = {
      \t\t\tisa = XCLocalSwiftPackageReference;
      \t\t\trelativePath = ../ZcashLightClientKit;
      \t\t};
      /* End XCLocalSwiftPackageReference section */
    PBX
    assert_equal ["../ZcashLightClientKit"], Zodl::LocalPackages.parse(pbxproj)
  end

  def test_parses_quoted_relative_path_and_dedupes
    pbxproj = <<~PBX
      \t\tAAA /* XCLocalSwiftPackageReference "../Some Package" */ = {
      \t\t\tisa = XCLocalSwiftPackageReference;
      \t\t\trelativePath = "../Some Package";
      \t\t};
      \t\tBBB /* XCLocalSwiftPackageReference "../Some Package" */ = {
      \t\t\tisa = XCLocalSwiftPackageReference;
      \t\t\trelativePath = "../Some Package";
      \t\t};
    PBX
    assert_equal ["../Some Package"], Zodl::LocalPackages.parse(pbxproj)
  end

  def test_remote_references_do_not_match
    pbxproj = <<~PBX
      \t\tCCC /* XCRemoteSwiftPackageReference "swift-atomics" */ = {
      \t\t\tisa = XCRemoteSwiftPackageReference;
      \t\t\trepositoryURL = "https://github.com/apple/swift-atomics.git";
      \t\t};
    PBX
    assert_equal [], Zodl::LocalPackages.parse(pbxproj)
  end

  def test_no_references_in_empty_project
    assert_equal [], Zodl::LocalPackages.parse("/* pbxproj without packages */")
  end
end
