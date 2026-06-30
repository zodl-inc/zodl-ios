require "minitest/autorun"
require "tmpdir"
require "zodl/build_paths"

class ZodlBuildPathsTest < Minitest::Test
  def test_all_paths_are_absolute
    Dir.mktmpdir do |worktree|
      Zodl::BuildPaths.resolve(worktree).each do |key, path|
        assert File.absolute_path?(path), "#{key} (#{path}) must be absolute"
      end
    end
  end

  def test_paths_are_anchored_inside_the_worktree
    Dir.mktmpdir do |worktree|
      paths = Zodl::BuildPaths.resolve(worktree)
      assert_equal File.join(worktree, "secant.xcodeproj"), paths[:project]
      assert_equal File.join(worktree, "build"), paths[:output_dir]
      assert_equal File.join(worktree, "build", "DerivedData"), paths[:derived_data]
    end
  end

  # Reproduces the original failure. fastlane wraps every top-level action in
  # `Dir.chdir("..")` (runner.rb: "go up from the fastlane folder, to the project
  # folder"). The release lane runs inside a worktree under $TMPDIR, so that `..`
  # lands in the worktree's PARENT. A RELATIVE project path resolves there and is
  # not found (the "Project file not found" crash); the absolute path BuildPaths
  # returns resolves regardless of fastlane's cwd.
  def test_project_path_survives_fastlanes_per_action_chdir_up
    Dir.mktmpdir do |parent|
      worktree = File.join(parent, "zodl-release-deadbeef")
      Dir.mkdir(worktree)
      Dir.mkdir(File.join(worktree, "secant.xcodeproj")) # stand-in project inside the worktree
      project = Zodl::BuildPaths.resolve(worktree)[:project]

      Dir.chdir(worktree) do
        Dir.chdir("..") do # exactly what fastlane's runner does around each action
          refute File.exist?(File.expand_path("secant.xcodeproj")),
                 "a bare relative project path must NOT resolve from the worktree's parent — this was the bug"
          assert File.exist?(File.expand_path(project)),
                 "the absolute project path must resolve regardless of fastlane's chdir"
        end
      end
    end
  end
end
