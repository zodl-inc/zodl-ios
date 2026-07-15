require "minitest/autorun"
require "zodl/dmg"

class ZodlDmgTest < Minitest::Test
  def test_filename_carries_the_flavor
    assert_equal "ZODL-internal-3.7.1-7.dmg", Zodl::Dmg.filename(flavor: "internal", version: "3.7.1", build: 7)
    assert_equal "ZODL-testnet-3.8.0-2.dmg", Zodl::Dmg.filename(flavor: "testnet", version: "3.8.0", build: 2)
  end

  def test_create_dmg_command_standard_layout
    cmd = Zodl::Dmg.create_dmg_command(
      app_name: "Zodl.app", source_dir: "/tmp/staging", dmg_path: "/tmp/out.dmg", volname: "Zodl Internal"
    )
    assert_equal "create-dmg", cmd.first
    # Standard drag-to-Applications window: app icon left, /Applications link right.
    assert_includes_run cmd, ["--volname", "Zodl Internal"]
    assert_includes_run cmd, ["--window-pos", "200", "120"]
    assert_includes_run cmd, ["--window-size", "600", "400"]
    assert_includes_run cmd, ["--icon-size", "128"]
    assert_includes_run cmd, ["--icon", "Zodl.app", "150", "190"]
    assert_includes_run cmd, ["--app-drop-link", "450", "190"]
    assert_includes_run cmd, ["--hide-extension", "Zodl.app"]
    refute_includes cmd, "--volicon"
    refute_includes cmd, "--background"
    # Output path then source dir, in that order, at the end.
    assert_equal ["/tmp/out.dmg", "/tmp/staging"], cmd.last(2)
  end

  def test_create_dmg_command_with_background
    cmd = Zodl::Dmg.create_dmg_command(
      app_name: "Zodl.app", source_dir: "/s", dmg_path: "/d.dmg", volname: "Zodl Testnet", background: "/bg.tiff"
    )
    assert_includes_run cmd, ["--background", "/bg.tiff"]
  end

  def test_create_dmg_command_with_volicon
    cmd = Zodl::Dmg.create_dmg_command(
      app_name: "Zodl.app", source_dir: "/s", dmg_path: "/d.dmg", volname: "Zodl Testnet", volicon: "/icon.icns"
    )
    assert_includes_run cmd, ["--volicon", "/icon.icns"]
  end

  def test_create_dmg_command_requires_volname
    assert_raises(ArgumentError) do
      Zodl::Dmg.create_dmg_command(app_name: "A.app", source_dir: "/s", dmg_path: "/d.dmg")
    end
  end

  def test_codesign_command
    cmd = Zodl::Dmg.codesign_command(path: "/d.dmg")
    assert_equal ["codesign", "--sign", "Developer ID Application", "--timestamp", "--force", "/d.dmg"], cmd
  end

  private

  # Asserts `sub` appears as a contiguous run inside `arr`.
  def assert_includes_run(arr, sub)
    found = arr.each_cons(sub.length).any? { |slice| slice == sub }
    assert found, "expected #{arr.inspect} to contain the run #{sub.inspect}"
  end
end
