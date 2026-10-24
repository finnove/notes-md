require_relative 'export_helper'
require_relative 'script_usage_helper'

SCRIPT = "../libexec/report"

class ReportTest < Minitest::Test
  include ScriptUsageHelper
  include ExportHelper

  SCRIPT_PATH = File.expand_path(SCRIPT, __dir__)
  # The words of the test note. None of them may be in the report.
  WORDS = %w[Hemmelig tekst slutt Aktiv]

  def run_report(env, *args) = run_script(SCRIPT_PATH, env, *args, input: "")

  # The test note in Notes with HTML the check fails on (<sup> stays as HTML in
  # md), and its md file with export: fail.
  def failing_note(dir, html: "<div>Hemmelig tekst x<sup>2</sup> slutt</div>")
    env = export_env(dir)
    File.write(cache(env, ACTIVE, "html"), html)
    write_md(dir, "journal/hemmelig tekst.md", ACTIVE_MD.sub("export: pass", "export: fail"))
    env
  end

  def test_help_shows_usage
    assert_usage_on_help("libexec/report")
  end

  def test_help_says_nothing_is_written
    out, _ = run_report({ "LANG" => "en_US.UTF-8" }, "--help")
    assert_includes out, "Usage: notes report [--baseline]\n"
    assert_includes out, "Writes nothing."
  end

  def test_versions_first
    Dir.mktmpdir do |dir|
      out, status = run_report(failing_note(dir))
      assert status.success?, out
      lines = out.lines
      assert_match(/\Anotes-md: \h{7,}/, lines[0])
      assert_match(/\Apandoc: \d/, lines[1])
      assert_match(/\AmacOS: /, lines[2])
    end
  end

  def test_shows_the_difference_masked
    Dir.mktmpdir do |dir|
      out, status = run_report(failing_note(dir))
      assert status.success?, out
      assert_includes out, "1 note(s) with export: fail, 1 still fail with this code.\n"
      assert_includes out, "Note 1 of 1: the text differs\n"
      assert_includes out, "  first difference at character 17\n"
      assert_includes out, "  Notes: digit, md: <\n"
      assert_includes out, "  Notes text: aaaaaaaa aaaaa a0 aaaaa\n"
      assert_includes out, "  md text:    aaaaaaaa aaaaa a<sup>0</sup> aaaaa\n"
      assert_includes out, "  HTML:\n    <div>aaaaaaaa aaaaa a<sup>0</sup> aaaaa</div>\n"
      assert_includes out, "  md:\n    aaaaaaaa aaaaa a<sup>0</sup> aaaaa\n"
    end
  end

  def test_no_text_from_the_note
    Dir.mktmpdir do |dir|
      out, _ = run_report(failing_note(dir, html: "<div>Hemmelig tekst 1986 x<sup>2</sup> slutt</div>"))
      WORDS.each { |w| refute_match(/#{w}/i, out, w) }
      refute_includes out, "1986"
      refute_includes out, "journal"
    end
  end

  # Text between < and > is not a tag unless it is an HTML tag, so it is masked.
  def test_text_that_looks_like_a_tag_is_masked
    Dir.mktmpdir do |dir|
      out, _ = run_report(failing_note(dir, html: "<div>tekst &lt;b slutt=hemmelig&gt; x<sup>2</sup></div>"))
      WORDS.each { |w| refute_match(/#{w}/i, out, w) }
    end
  end

  # The text from Notes has no tags: something like a tag in it is text.
  def test_notes_text_has_no_tags
    Dir.mktmpdir do |dir|
      out, _ = run_report(failing_note(dir, html: "<div>&lt;b&gt; x<sup>2</sup></div>"))
      assert_includes out, "  Notes text: <a> a0\n"
    end
  end

  # A cut word at the start is marked, so its length is not taken as a word length.
  def test_cut_text_marked
    Dir.mktmpdir do |dir|
      out, _ = run_report(failing_note(dir, html: "<div>#{"Hemmelig " * 6}x<sup>2</sup></div>"))
      assert_match(/^  Notes text: …a+ aaaaaaaa /, out)
    end
  end

  # Attribute values are masked, except those that say how the text looks.
  def test_attribute_values_masked_except_formatting
    Dir.mktmpdir do |dir|
      out, _ = run_report(failing_note(dir, html: %(<div><a href="https://hemmelig.no/tekst">slutt</a> <font face="Courier">x</font><sup>2</sup></div>)))
      assert_includes out, %(<a href="aaaaa://aaaaaaaa.aa/aaaaa">aaaaa</a>)
      assert_includes out, %(<font face="Courier">a</font>)
    end
  end

  def test_invisible_characters_shown_as_codes
    Dir.mktmpdir do |dir|
      out, _ = run_report(failing_note(dir, html: "<div>tekst x<sup>2</sup></div>"))
      assert_includes out, "aaaaa\\u00A0a<sup>0</sup>"
    end
  end

  def test_last_line_says_it_can_be_pasted
    Dir.mktmpdir do |dir|
      out, _ = run_report(failing_note(dir))
      assert_equal "The report has no text from your notes and can be pasted into an issue; " \
                   "it shows the structure (word lengths, punctuation, emoji).\n", out.lines.last
    end
  end

  # A note that passes with the code now is counted, not shown.
  def test_note_that_passes_now
    Dir.mktmpdir do |dir|
      out, _ = run_report(failing_note(dir, html: "<div>Aktiv</div><div>tekst</div>"))
      assert_includes out, "1 note(s) with export: fail, 0 still fail with this code.\n"
      refute_includes out, "Note 1 of"
    end
  end

  def test_writes_nothing
    Dir.mktmpdir do |dir|
      env = failing_note(dir)
      run_report(env)
      status, _ = Open3.capture2("git", "-C", env["NOTES_ROOT"], "status", "--porcelain")
      assert_empty status
    end
  end

  def test_no_failed_notes
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      write_md(dir, "journal/aktiv.md", ACTIVE_MD)
      out, status = run_report(env)
      assert status.success?, out
      assert_includes out, "0 note(s) with export: fail.\n"
      refute_includes out, "still fail"
    end
  end

  # --baseline takes the notes that fail in the baseline instead of ~/notes.
  def test_baseline_takes_failed_notes_from_the_baseline
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      File.write(cache(env, ACTIVE, "html"), "<div>Hemmelig tekst x<sup>2</sup> slutt</div>")
      write_md(dir, "journal/aktiv.md", ACTIVE_MD)
      FileUtils.mkdir_p env["NOTES_BASELINE"]
      File.write(File.join(env["NOTES_BASELINE"], "#{ACTIVE}.md"), ACTIVE_MD.sub("export: pass", "export: fail"))
      out, _ = run_report(env)
      assert_includes out, "0 note(s) with export: fail.\n"
      out, status = run_report(env, "--baseline")
      assert status.success?, out
      assert_includes out, "1 note(s) with export: fail, 1 still fail with this code.\n"
      assert_includes out, "  md text:    aaaaaaaa aaaaa a<sup>0</sup> aaaaa\n"
    end
  end

  def test_help_lists_baseline
    out, _ = run_report({ "LANG" => "en_US.UTF-8" }, "--help")
    assert_match(/^\s+--baseline\s+\S/, out)
    assert_includes out, "  notes report --baseline\n"
  end

  # Without a local copy of the note it cannot be built.
  def test_note_not_in_the_local_copy
    Dir.mktmpdir do |dir|
      env = failing_note(dir)
      File.delete(cache(env, ACTIVE, "html"))
      out, _ = run_report(env)
      assert_includes out, "1 note(s) not in the local copy: run notes sync.\n"
    end
  end
end
