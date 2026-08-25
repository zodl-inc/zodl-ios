# frozen_string_literal: true

require "json"

module Zodl
  # Maps App Store Connect locales to the repo's whatsNew*.json files, finds the
  # release entry for a version, and renders the App Store "What's New" text.
  #
  # File reading + transformation only, no network: the Fastfile passes in the
  # WhatsNew directory and the locales it fetched from App Store Connect.
  #
  # Rendering must stay byte-identical to the `appstore` command of the
  # /update-whatsnew helper script (whatsnew.py): section title line, one
  # "* "-prefixed line per bullet, sections separated by one blank line.
  module WhatsNew
    Result = Struct.new(:notes, :sources, :errors) do
      def ok?
        errors.empty?
      end
    end

    module_function

    # whatsNew.json for English, whatsNew_<lang>.json for every other language —
    # the same language→file rule the /update-whatsnew skill documents. The
    # language is the part of the locale before the first dash (es-ES → es).
    def basename_for_locale(locale)
      lang = locale.to_s.split("-").first.to_s.downcase
      lang == "en" ? "whatsNew.json" : "whatsNew_#{lang}.json"
    end

    # The release entry for `version` anywhere in the file's releases array —
    # not just the newest entry, so a re-submission after the next version was
    # already prepended still finds its notes.
    #
    # File.read pins the read to UTF-8 regardless of the process's default
    # external encoding: fastlane/CI often runs with no LANG/LC_ALL set, which
    # makes Ruby default to US-ASCII and raises Encoding::InvalidByteSequenceError
    # on the real whatsNew files' em dashes and accents (e.g. "Añadido:") — a
    # crash `resolve`'s `rescue JSON::ParserError` cannot catch.
    def entry_for_version(file, version)
      parsed = JSON.parse(File.read(file, encoding: Encoding::UTF_8))
      # A syntactically valid but structurally wrong file (e.g. a bare JSON
      # array) would otherwise blow up inside #fetch with a raw TypeError that
      # `resolve` can't turn into a useful per-locale message.
      raise TypeError, "top-level JSON value is #{parsed.class}, not an object" unless parsed.is_a?(Hash)

      parsed.fetch("releases", []).find { |entry| entry["version"] == version }
    end

    def render(entry)
      entry.fetch("sections", []).map do |section|
        ([section.fetch("title")] + section.fetch("bulletpoints", []).map { |bp| "* #{bp}" }).join("\n")
      end.join("\n\n")
    end

    # Resolves every locale to its rendered App Store text. Problems (missing
    # file, missing entry, unparseable JSON) are collected per locale so the
    # preflight can show all of them at once instead of one per run.
    def resolve(dir:, locales:, version:)
      result = Result.new({}, {}, [])
      locales.each do |locale|
        basename = basename_for_locale(locale)
        file = File.join(dir, basename)
        unless File.file?(file)
          result.errors << "locale #{locale}: #{basename} not found in #{dir}"
          next
        end
        begin
          entry = entry_for_version(file, version)
        rescue JSON::ParserError => e
          result.errors << "locale #{locale}: #{basename} is not valid JSON (#{e.message})"
          next
        rescue TypeError => e
          result.errors << "locale #{locale}: #{basename} #{e.message}"
          next
        end
        if entry.nil?
          result.errors << "locale #{locale}: #{basename} has no entry for version #{version}"
          next
        end
        result.notes[locale] = render(entry)
        result.sources[locale] = basename
      end
      result
    end
  end
end
