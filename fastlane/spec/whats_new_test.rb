# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "zodl/whats_new"

class ZodlWhatsNewTest < Minitest::Test
  def test_basename_for_locale
    assert_equal "whatsNew.json", Zodl::WhatsNew.basename_for_locale("en-US")
    assert_equal "whatsNew.json", Zodl::WhatsNew.basename_for_locale("en-GB")
    assert_equal "whatsNew_es.json", Zodl::WhatsNew.basename_for_locale("es-ES")
    assert_equal "whatsNew_es.json", Zodl::WhatsNew.basename_for_locale("es-MX")
    assert_equal "whatsNew_pt.json", Zodl::WhatsNew.basename_for_locale("pt-BR")
    assert_equal "whatsNew_zh.json", Zodl::WhatsNew.basename_for_locale("zh-Hans")
  end

  # Three entries, requested version in the middle — proves the lookup is by
  # `version` field, not by array position.
  def releases_fixture
    {
      "releases" => [
        { "version" => "3.8.0", "date" => "25-07-2026", "timestamp" => 1, "sections" => [] },
        { "version" => "3.7.4", "date" => "22-07-2026", "timestamp" => 2, "sections" => [] },
        { "version" => "3.7.3", "date" => "11-07-2026", "timestamp" => 3, "sections" => [] }
      ]
    }
  end

  def test_entry_for_version_finds_entry_that_is_not_first
    Dir.mktmpdir do |dir|
      file = File.join(dir, "whatsNew.json")
      File.write(file, JSON.generate(releases_fixture))

      entry = Zodl::WhatsNew.entry_for_version(file, "3.7.4")

      refute_nil entry
      assert_equal "3.7.4", entry["version"]
    end
  end

  def test_entry_for_version_returns_nil_for_missing_version
    Dir.mktmpdir do |dir|
      file = File.join(dir, "whatsNew.json")
      File.write(file, JSON.generate(releases_fixture))

      assert_nil Zodl::WhatsNew.entry_for_version(file, "9.9.9")
    end
  end

  # A syntactically valid file whose top level isn't a JSON object (e.g. a bare
  # array) used to blow up inside Hash#fetch/Array#fetch with a raw TypeError.
  # entry_for_version now validates the top-level shape itself and raises a
  # TypeError with a message resolve can turn into a normal collected error.
  def test_entry_for_version_raises_for_non_object_json
    Dir.mktmpdir do |dir|
      file = File.join(dir, "whatsNew.json")
      File.write(file, JSON.generate(["not", "an", "object"]))

      error = assert_raises(TypeError) { Zodl::WhatsNew.entry_for_version(file, "3.8.0") }
      assert_includes error.message, "not an object"
    end
  end

  def test_render_exact_output_for_two_sections
    entry = {
      "sections" => [
        { "title" => "Added:", "bulletpoints" => ["First.", "Second."] },
        { "title" => "Fixed:", "bulletpoints" => ["Third."] }
      ]
    }

    assert_equal "Added:\n* First.\n* Second.\n\nFixed:\n* Third.", Zodl::WhatsNew.render(entry)
  end

  def write_whats_new(dir, basename, version:, sections:)
    payload = { "releases" => [{ "version" => version, "date" => "01-01-2026", "timestamp" => 1, "sections" => sections }] }
    File.write(File.join(dir, basename), JSON.generate(payload))
  end

  def test_resolve_happy_path
    Dir.mktmpdir do |dir|
      sections = [{ "title" => "Added:", "bulletpoints" => ["Thing."] }]
      write_whats_new(dir, "whatsNew.json", version: "3.8.0", sections: sections)
      write_whats_new(dir, "whatsNew_es.json", version: "3.8.0", sections: sections)

      result = Zodl::WhatsNew.resolve(dir: dir, locales: ["en-US", "es-ES"], version: "3.8.0")

      assert result.ok?, result.errors.join("; ")
      assert_equal "Added:\n* Thing.", result.notes["en-US"]
      assert_equal "Added:\n* Thing.", result.notes["es-ES"]
      assert_equal "whatsNew.json", result.sources["en-US"]
      assert_equal "whatsNew_es.json", result.sources["es-ES"]
    end
  end

  def test_resolve_collects_every_error
    Dir.mktmpdir do |dir|
      # en-US: whatsNew.json is simply absent from the directory.
      # es-ES: file present, but has no entry for the requested version.
      write_whats_new(dir, "whatsNew_es.json", version: "1.0.0", sections: [{ "title" => "Added:", "bulletpoints" => ["Thing."] }])
      # pt-BR: file present, but is not valid JSON.
      File.write(File.join(dir, "whatsNew_pt.json"), "{ not json")

      result = Zodl::WhatsNew.resolve(dir: dir, locales: ["en-US", "es-ES", "pt-BR"], version: "3.8.0")

      refute result.ok?
      assert_equal 3, result.errors.length
      assert(result.errors.any? { |e| e.include?("whatsNew.json") && e.include?("en-US") })
      assert(result.errors.any? { |e| e.include?("has no entry for version") })
      assert(result.errors.any? { |e| e.include?("not valid JSON") })
    end
  end

  # Integration-level counterpart to test_entry_for_version_raises_for_non_object_json:
  # resolve's own doc comment promises every problem is collected, not raised.
  def test_resolve_collects_error_for_non_object_json
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "whatsNew.json"), JSON.generate(["not", "an", "object"]))

      result = Zodl::WhatsNew.resolve(dir: dir, locales: ["en-US"], version: "3.8.0")

      refute result.ok?
      assert(result.errors.any? { |e| e.include?("whatsNew.json") && e.include?("not an object") })
    end
  end

  # Real whatsNew files contain non-ASCII (em dashes, accents, "Añadido:"). A
  # shell with no LANG/LC_ALL set — routine for fastlane/CI — makes Ruby's
  # Encoding.default_external US-ASCII, and File.read without an explicit
  # encoding used to make entry_for_version raise Encoding::InvalidByteSequenceError,
  # which escaped resolve's `rescue JSON::ParserError` as an uncaught crash.
  #
  # Reproduced via a CHILD ruby process with LANG/LC_ALL/LC_CTYPE removed,
  # rather than mutating this process's global Encoding.default_external —
  # that would leak into every other test in this file.
  def test_resolve_reads_non_ascii_content_without_a_utf8_process_locale
    Dir.mktmpdir do |dir|
      sections = [{ "title" => "Añadido:", "bulletpoints" => ["Cosa nueva — con guión largo."] }]
      write_whats_new(dir, "whatsNew_es.json", version: "3.8.0", sections: sections)

      lib_dir = File.expand_path("../lib", __dir__)
      # Single-quoted heredoc: its #{...} belong to the CHILD script and must
      # stay literal here, evaluated only once the child requires this source.
      child_script = <<~'RUBY_SCRIPT'
        require "zodl/whats_new"
        begin
          result = Zodl::WhatsNew.resolve(dir: ARGV[0], locales: ["es-ES"], version: "3.8.0")
          if result.ok?
            print "OK:#{result.notes["es-ES"]}"
          else
            print "ERR:#{result.errors.join("|")}"
          end
        rescue => e
          print "CRASH:#{e.class}:#{e.message}"
        end
      RUBY_SCRIPT
      no_locale_env = { "LANG" => nil, "LC_ALL" => nil, "LC_CTYPE" => nil }
      out = IO.popen(no_locale_env, ["ruby", "-I#{lib_dir}", "-e", child_script, dir],
                      external_encoding: Encoding::UTF_8, &:read)

      assert_equal "OK:Añadido:\n* Cosa nueva — con guión largo.", out
    end
  end

  def test_render_matches_python_renderer
    script = File.expand_path("../../.claude/skills/update-whatsnew/scripts/whatsnew.py", __dir__)
    skip "python3 not available" unless system("python3 -c 1 >/dev/null 2>&1")
    entry = {
      "version" => "9.9.9", "date" => "01-01-2026", "timestamp" => 1,
      "sections" => [
        { "title" => "Added:", "bulletpoints" => ["One with 'quotes' and accents áé.", "Two."] },
        { "title" => "Fixed:", "bulletpoints" => ["Three."] }
      ]
    }
    Dir.mktmpdir do |dir|
      payload = File.join(dir, "payload.json")
      File.write(payload, JSON.generate(entry))
      # external_encoding pins the read to UTF-8 regardless of the invoking shell's
      # locale (python3 always emits UTF-8 here) — without it, a shell with no
      # LANG/LC_ALL set tags the bytes US-ASCII and the comparison fails spuriously.
      python = IO.popen(["python3", script, "appstore", "--payload", payload], external_encoding: Encoding::UTF_8, &:read)
      assert_equal python, "#{Zodl::WhatsNew.render(entry)}\n" # print adds the trailing newline
    end
  end
end
