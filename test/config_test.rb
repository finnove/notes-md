require_relative 'script_usage_helper'
require 'fileutils'
require 'tmpdir'
require 'yaml'

SCRIPT = "../lib/notes_md/commands/config.rb"

class ConfigTest < Minitest::Test
  include ScriptUsageHelper

  SCRIPT_PATH = File.expand_path(SCRIPT, __dir__)
  COMMON = File.expand_path("../lib/notes_md/common", __dir__)
  KEYS = %w[root raw_cache import baseline db lang bold_line_as_heading]

  def setup
    @dir = Dir.mktmpdir
    @file = File.join(@dir, "config", "notes-md", "config.yml")
  end

  def teardown
    FileUtils.rm_rf @dir
  end

  def env(extra = {}) = { "NOTES_CONFIG" => @file, "HOME" => @dir, "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" }.merge(extra)

  def run_config(extra = {})
    out, @status = Open3.capture2e(env(extra), "ruby", SCRIPT_PATH)
    out.force_encoding("UTF-8")
  end

  # The value the code uses, as the commands load it.
  def setting(expr, extra = {})
    out, status = Open3.capture2e(env(extra), "ruby", "-e", "require #{COMMON.dump}; p #{expr}")
    assert status.success?, out
    out.chomp
  end

  def write_config(text)
    FileUtils.mkdir_p File.dirname(@file)
    File.write(@file, text)
  end

  def test_help_shows_usage
    assert_usage_on_help("lib/notes_md/commands/config.rb")
  end

  def test_creates_the_file_with_every_setting_commented_out
    out = run_config
    assert @status.success?, out
    assert_includes out, "Created #{@file}\n"
    text = File.read(@file)
    KEYS.each { |k| assert_match(/^# #{k}: \S/, text, k) }
    assert_nil YAML.safe_load(text), "all commented out: nothing is set"
  end

  # Each line in the file, with # removed, is a valid setting.
  def test_every_line_in_the_file_can_be_used
    run_config
    lines = File.read(@file).lines.grep(/^# [a-z_]+: /)
    assert_equal KEYS, lines.map { |l| l[/^# ([a-z_]+):/, 1] }
    assert_equal KEYS, YAML.safe_load(lines.map { |l| l.delete_prefix("# ") }.join).keys
  end

  def test_keeps_an_existing_file
    write_config("lang: nb\n")
    out = run_config
    refute_includes out, "Created"
    assert_equal "lang: nb\n", File.read(@file)
  end

  def test_shows_each_setting_and_where_it_comes_from
    write_config("lang: nb\n")
    out = run_config("NOTES_ROOT" => "/r")
    assert_match(%r{^root\s+/r\s+NOTES_ROOT$}, out)
    assert_match(/^lang\s+nb\s+#{Regexp.escape(@file)}$/, out)
    assert_match(%r{^baseline\s+~/notes\.baseline\s+default$}, out)
    assert_match(%r{^raw_cache\s+/r/apple_notes\.raw\s+default$}, out)
  end

  def test_the_file_sets_the_settings
    write_config("root: ~/arkiv\nlang: nb\nbold_line_as_heading: true\n")
    assert_equal File.join(@dir, "arkiv").dump, setting("NotesCommon::NOTES_ROOT")
    assert_equal File.join(@dir, "arkiv", "import").dump, setting("NotesCommon::IMPORT_DIR")
    assert_equal '"Vedlegg"', setting('NotesCommon::MD_TEXT["attachments"]')
    assert_equal '"## Overskrift"', setting('NotesCommon.html_to_markdown("<div><b>Overskrift</b></div>")[0]')
  end

  def test_the_environment_wins_over_the_file
    write_config("lang: nb\nbold_line_as_heading: true\n")
    assert_equal '"Attachments"', setting('NotesCommon::MD_TEXT["attachments"]', "NOTES_LANG" => "en")
    assert_equal '"**Overskrift**"', setting('NotesCommon.html_to_markdown("<div><b>Overskrift</b></div>")[0]',
                                             "NOTES_BOLD_LINE_AS_HEADING" => "0")
  end

  def test_without_a_file_the_defaults
    assert_equal File.join(@dir, "notes").dump, setting("NotesCommon::NOTES_ROOT")
    assert_equal '"Attachments"', setting('NotesCommon::MD_TEXT["attachments"]')
  end

  def test_an_unknown_language_in_the_file_names_the_file
    write_config("lang: xx\n")
    out, status = Open3.capture2e(env, "ruby", "-e", "require #{COMMON.dump}")
    refute status.success?
    assert_equal "lang in #{@file} must be one of: en, nb\n", out
  end

  def test_an_unknown_setting_in_the_file_is_named
    write_config("lnag: nb\n")
    out, status = Open3.capture2e(env, "ruby", "-e", "require #{COMMON.dump}")
    refute status.success?
    assert_equal "#{@file}: unknown setting lnag (known: #{KEYS.join(", ")})\n", out
  end

  # Without NOTES_CONFIG: XDG_CONFIG_HOME, or ~/.config.
  def test_the_file_is_in_the_config_folder
    out, _ = Open3.capture2e(env("NOTES_CONFIG" => nil, "XDG_CONFIG_HOME" => File.join(@dir, "xdg")), "ruby", SCRIPT_PATH)
    assert_includes out, "Created #{File.join(@dir, "xdg", "notes-md", "config.yml")}\n"
    out, _ = Open3.capture2e(env("NOTES_CONFIG" => nil, "XDG_CONFIG_HOME" => nil), "ruby", SCRIPT_PATH)
    assert_includes out, "Created #{File.join(@dir, ".config", "notes-md", "config.yml")}\n"
  end
end
