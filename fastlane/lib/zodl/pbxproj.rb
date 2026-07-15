# frozen_string_literal: true

module Zodl
  # Reads per-target build settings out of a pbxproj's TEXT, so the preflight
  # can check the version of the target a variant actually builds without a
  # checkout (the Fastfile feeds it `git show <sha>:...project.pbxproj`).
  # Targets may carry different MARKETING_VERSIONs — the macOS app is versioned
  # independently of iOS — so a whole-file "first match" is not meaningful.
  module Pbxproj
    module_function

    # The unique MARKETING_VERSION values across `target`'s build
    # configurations, sorted. One element means the target is consistent;
    # several mean its own configs disagree (caller decides how loud to be);
    # empty means the target or setting was not found.
    def marketing_versions(pbxproj, target:)
      list = pbxproj[
        /\/\* Build configuration list for PBXNativeTarget "#{Regexp.escape(target)}" \*\/ = \{.*?buildConfigurations = \((.*?)\);/m, 1
      ]
      return [] unless list

      list.scan(/[A-F0-9]{24}/).filter_map { |config_id|
        # A configuration block runs from its id header to its trailing
        # `name = <configuration>;` line — build settings are UPPER_CASE, so a
        # lowercase `name = ` cannot occur earlier inside buildSettings.
        block = pbxproj[/#{config_id} \/\* [^*]* \*\/ = \{\s*isa = XCBuildConfiguration;.*?name = [^;]+;/m]
        block && block[/MARKETING_VERSION = ([^;]+);/, 1]&.strip
      }.uniq.sort
    end
  end
end
