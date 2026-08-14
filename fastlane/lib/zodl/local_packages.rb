# frozen_string_literal: true

module Zodl
  # Extracts local Swift package references (XCLocalSwiftPackageReference) from
  # pbxproj text. Xcode stores each reference's relativePath relative to the
  # .xcodeproj's directory — the repo root for this project — and writes the
  # value quoted or bare depending on the characters in it.
  module LocalPackages
    module_function

    def parse(pbxproj)
      pbxproj.scan(/isa = XCLocalSwiftPackageReference;\s*relativePath = "?([^";\n]+?)"?;/).flatten.uniq
    end
  end
end
