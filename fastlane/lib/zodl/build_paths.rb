# frozen_string_literal: true

module Zodl
  # Absolute paths for a build performed inside a throwaway worktree.
  #
  # fastlane runs every top-level action wrapped in `Dir.chdir("..")` — it assumes
  # it was invoked from the `fastlane/` folder and steps up to the project root
  # (see fastlane runner.rb: "go up from the fastlane folder, to the project
  # folder"). The release lane instead `Dir.chdir`es into a throwaway worktree
  # beside the repo, so that per-action `..` lands in the worktree's PARENT. Any RELATIVE
  # path handed to an action (project, derived-data, output dir) then resolves
  # there — outside the worktree — and fails (e.g. "Project file not found at
  # '.../T/secant.xcodeproj'"). Anchoring every action path to the absolute
  # worktree root makes them independent of fastlane's cwd.
  module BuildPaths
    PROJECT = "secant.xcodeproj"

    module_function

    # worktree must be an absolute path (the release lane derives it from the
    # absolute repo root).
    def resolve(worktree)
      build = File.join(worktree, "build")
      {
        project: File.join(worktree, PROJECT),
        output_dir: build,
        derived_data: File.join(build, "DerivedData")
      }.freeze
    end
  end
end
