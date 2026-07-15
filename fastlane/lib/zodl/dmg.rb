# frozen_string_literal: true

module Zodl
  # Builds the shell commands for producing the distributable macOS disk image:
  # a standard drag-to-Applications window (app icon on the left, /Applications
  # drop-link on the right). Pure argv construction — no I/O — so the layout is
  # unit-testable; the Fastfile executes the arrays without a shell.
  module Dmg
    module_function

    def filename(flavor:, version:, build:)
      "ZODL-#{flavor}-#{version}-#{build}.dmg"
    end

    # `source_dir` must contain ONLY the app bundle; create-dmg turns the whole
    # folder into the volume. `volname` is the flavor's product name, supplied by
    # the caller. `volicon` (.icns) and `background` (window-sized image, 600x400pt —
    # the app→Applications arrow is baked into it) are optional; nil skips them.
    def create_dmg_command(app_name:, source_dir:, dmg_path:, volname:, volicon: nil, background: nil)
      command = ["create-dmg", "--volname", volname]
      command += ["--volicon", volicon] if volicon
      command += ["--background", background] if background
      command + [
        "--window-pos", "200", "120",
        "--window-size", "600", "400",
        "--icon-size", "128",
        "--icon", app_name, "150", "190",
        "--app-drop-link", "450", "190",
        "--hide-extension", app_name,
        dmg_path, source_dir
      ]
    end

    # codesign accepts a partial common-name match; "Developer ID Application"
    # uniquely selects the team's Developer ID identity in the keychain.
    def codesign_command(path:, identity: "Developer ID Application")
      ["codesign", "--sign", identity, "--timestamp", "--force", path]
    end
  end
end
