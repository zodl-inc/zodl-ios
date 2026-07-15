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
      ids = config_ids(pbxproj, target: target)
      return [] unless ids

      ids.filter_map { |config_id|
        block = config_block(pbxproj, config_id)
        block && block[/MARKETING_VERSION = ([^;]+);/, 1]&.strip
      }.uniq.sort
    end

    # The target's PRODUCT_NAME with pbxproj quoting stripped and a literal
    # $(TARGET_NAME) resolved to the target name — the .app bundle's base name.
    # nil when the target or setting is absent; raises when the target's own
    # configurations disagree (same policy as the version check).
    def product_name(pbxproj, target:)
      ids = config_ids(pbxproj, target: target)
      return nil unless ids

      values = ids.filter_map { |config_id|
        block = config_block(pbxproj, config_id)
        block && block[/PRODUCT_NAME = (.+?);/, 1]&.gsub(/\A"|"\z/, "")
      }.uniq
      if values.size > 1
        raise ArgumentError, "target #{target.inspect} configurations disagree on PRODUCT_NAME: #{values.join(', ')}"
      end

      values.first == "$(TARGET_NAME)" ? target : values.first
    end

    # Returns a copy of `pbxproj` with `key = value;` rewritten in each of
    # `target`'s configuration blocks. Blocks that don't carry the key are left
    # untouched (nothing is inserted). Raises on an unknown target.
    def set_setting(pbxproj, target:, key:, value:)
      ids = config_ids(pbxproj, target: target)
      raise ArgumentError, "unknown target: #{target.inspect}" unless ids

      ids.reduce(pbxproj) do |text, config_id|
        block = config_block(text, config_id)
        next text unless block

        text.sub(block, block.gsub(/#{Regexp.escape(key)} = [^;]+;/, "#{key} = #{value};"))
      end
    end

    # The configuration ids listed by the target's XCConfigurationList, or nil
    # when the target does not exist in this project.
    def config_ids(pbxproj, target:)
      list = pbxproj[
        /\/\* Build configuration list for PBXNativeTarget "#{Regexp.escape(target)}" \*\/ = \{.*?buildConfigurations = \((.*?)\);/m, 1
      ]
      list&.scan(/[A-F0-9]{24}/)
    end

    # A configuration block runs from its id header to its trailing
    # `name = <configuration>;` line — build settings are UPPER_CASE, so a
    # lowercase `name = ` cannot occur earlier inside buildSettings.
    def config_block(pbxproj, config_id)
      pbxproj[/#{config_id} \/\* [^*]* \*\/ = \{\s*isa = XCBuildConfiguration;.*?name = [^;]+;/m]
    end
  end
end
