require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'

SCRIPT = "../notes"

class NotesTest < Minitest::Test
  CMD = File.expand_path("../notes", __dir__)
  # In the order they are used.
  COMMANDS = %w[export compare health sync prune baseline]

  def run_cmd(*args)
    out, status = Open3.capture2e({ "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" }, "ruby", CMD, *args)
    [out.force_encoding("UTF-8"), status]
  end

  def test_no_args_shows_usage_and_fails
    out, status = run_cmd
    assert_equal 1, status.exitstatus
    assert_match(/Usage: notes <command>/, out)
  end

  def test_help_lists_every_command
    out, status = run_cmd("--help")
    assert status.success?, out
    COMMANDS.each { |c| assert_match(/^\s+#{c}\s+\S/, out, c) }
  end

  def test_help_lists_commands_in_workflow_order
    out, _ = run_cmd("--help")
    listed = out[/Commands:\n(.*?)\n\n/m, 1].lines.map { |l| l.split.first }
    assert_equal COMMANDS, listed
  end

  def test_help_says_where_to_start
    out, _ = run_cmd("--help")
    assert_match(/Start here:\n\s+notes export\s+\S.*\n\s+notes compare\s+\S/, out)
  end

  def test_every_command_has_a_script
    COMMANDS.each { |c| assert File.executable?(File.expand_path("../libexec/#{c}", __dir__)), c }
  end

  def test_unknown_command_fails
    out, status = run_cmd("nope")
    assert_equal 1, status.exitstatus
    assert_match(/unknown command: nope/, out)
  end

  def test_command_help_is_passed_on
    COMMANDS.each do |c|
      out, status = run_cmd(c, "--help")
      assert status.success?, "#{c}: #{out}"
      assert_match(/Usage: notes #{c}/, out, c)
      assert_match(/Without it, /, out, c)
      assert_match(/\n\nOptions:\n(.*\n)*\s+-h, --help\s+Show this help\n/, out, c)
      assert_operator out.index("Options:"), :<, out.index("Examples:").to_i, c
      assert_match(/\n\nExamples:\n  notes #{c}/, out, c)
    end
  end
  # A PATH with ruby but without pandoc.
  def path_without_pandoc(dir)
    File.symlink(RbConfig.ruby, File.join(dir, "ruby"))
    dir
  end

  def run_with(env, *args)
    out, status = Open3.capture2e({ "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" }.merge(env), RbConfig.ruby, CMD, *args)
    [out.force_encoding("UTF-8"), status]
  end

  def test_missing_pandoc_gives_one_line
    Dir.mktmpdir do |dir|
      %w[export baseline].each do |c|
        out, status = run_with({ "PATH" => path_without_pandoc(File.join(dir, c).tap { |d| Dir.mkdir(d) }) }, c)
        assert_equal 1, status.exitstatus, out
        assert_equal "notes: pandoc not found. Install it with: brew install pandoc\n", out
      end
    end
  end

  def test_commands_without_pandoc_still_run
    Dir.mktmpdir do |dir|
      out, status = run_with({ "PATH" => path_without_pandoc(dir) }, "health", "--help")
      assert status.success?, out
    end
  end

  def test_missing_gem_gives_one_line
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "nokogiri.rb"), "raise LoadError, 'cannot load such file -- nokogiri'\n")
      out, status = run_with({ "RUBYLIB" => dir }, "health")
      assert_equal 1, status.exitstatus, out
      assert_equal "notes: Ruby gem nokogiri is missing. Install it with: bundle install (in #{File.dirname(CMD)})\n", out
    end
  end
end
