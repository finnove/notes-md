require_relative 'script_usage_helper'
require_relative 'notes_proto_helper'
require 'fileutils'
require 'sqlite3'
require 'tmpdir'
require_relative '../lib/notes_md/common'

SCRIPT = "../lib/notes_md/commands/baseline.rb"

class BaselineTest < Minitest::Test
  include ScriptUsageHelper

  UUID = "11111111-2222-3333-4444-555555555555"

  def setup
    @dir      = Dir.mktmpdir
    @root     = File.join(@dir, "notes")
    @raw      = File.join(@root, "apple_notes.raw")
    @baseline = File.join(@dir, "notes.baseline")
    @db       = File.join(@dir, "NoteStore.sqlite")
    FileUtils.mkdir_p [@raw, @baseline]
    system("git", "-C", @baseline, "init", "-q")
    db = SQLite3::Database.new @db
    db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, ZISPASSWORDPROTECTED INTEGER, " \
               "ZALTTEXT TEXT, ZCREATIONDATE3 REAL, ZTYPEUTI1 TEXT, ZNOTE INTEGER, ZNOTE1 INTEGER, ZTOKENCONTENTIDENTIFIER TEXT, " \
               "ZMEDIA INTEGER, ZACCOUNT1 INTEGER, ZFILENAME TEXT)"
    db.execute "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)"
    db.close
  end

  def teardown
    FileUtils.rm_rf @dir
  end

  def add_note(html, items, locked: 0)
    File.write(File.join(@raw, "#{UUID}.html"), html)
    db = SQLite3::Database.new @db
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (ZIDENTIFIER, ZISPASSWORDPROTECTED, ZCREATIONDATE3) VALUES (?, ?, 536500000.0)", [UUID.upcase, locked]
    pk = db.last_insert_row_id
    blob = locked == 1 ? "kryptert".b : Proto.zdata(items)
    db.execute "INSERT INTO ZICNOTEDATA (ZNOTE, ZDATA) VALUES (?, ?)", [pk, SQLite3::Blob.new(blob)]
    db.close
  end

  def add_plain_note(html)
    File.write(File.join(@raw, "#{UUID}.html"), html)
    db = SQLite3::Database.new @db
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (ZIDENTIFIER, ZCREATIONDATE3) VALUES (?, 536500000.0)", [UUID.upcase]
    db.close
  end

  # Commits everything in the baseline folder, as the user does after a diff.
  def commit_baseline
    system("git", "-C", @baseline, "add", "-A")
    system("git", "-C", @baseline, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "baseline")
  end

  def baseline_md
    File.read(File.join(@baseline, "#{UUID}.md"), encoding: "UTF-8")
  end

  # The text under the frontmatter.
  def baseline_body
    baseline_md.sub(NotesCommon::FRONTMATTER, "").delete_prefix("\n")
  end

  def run_baseline(*args, input: "")
    out, @status = Open3.capture2e(
      { "NOTES_ROOT" => @root, "NOTES_RAW_CACHE" => @raw, "NOTES_BASELINE" => @baseline, "NOTES_DB" => @db,
        "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
      "ruby", File.expand_path(SCRIPT, __dir__), *args, stdin_data: input
    )
    out.force_encoding("UTF-8")
  end

  def test_help_shows_usage
    assert_usage_on_help("lib/notes_md/commands/baseline.rb")
  end

  def test_help_shows_folder_as_written
    out = run_baseline("--help")
    assert_includes out, "Converts the whole local copy to the baseline folder (~/notes.baseline),"
    refute_includes out, @baseline
  end

  def test_writes_conversion_per_note
    add_plain_note("<div>Hei</div>")
    out = run_baseline
    assert @status.success?, out
    assert_equal "Hei\n", baseline_body
  end

  def test_headings_blank_lines
    add_plain_note("<div>tekst</div><h1>Tittel</h1><div>a</div><h2>Vedlegg</h2><div><br></div><h2>Under</h2>" \
                   "<div> </div><h3>Dypere</h3><div><br></div><div>b</div>")
    out = run_baseline
    assert @status.success?, out
    assert_equal "tekst\n\n# Tittel\n\na\n\n## Vedlegg\n\n## Under\n\n### Dypere\nb\n", baseline_body
  end

  def test_records_conversion_fingerprint
    add_plain_note("<div>Hei</div>")
    run_baseline
    assert_equal NotesCommon.conversion_fingerprint, File.read(File.join(@baseline, ".fingerprint"))
  end

  def test_fingerprint_survives_cleanup
    File.write(File.join(@baseline, ".fingerprint"), "old")
    commit_baseline
    add_plain_note("<div>Hei</div>")
    run_baseline
    assert File.exist?(File.join(@baseline, ".fingerprint"))
  end

  def test_checkboxes_from_notestore
    add_note("<div>Liste</div><ul><li>Melk</li><li>Brød</li></ul>", [["Liste", :plain], ["Melk", :done], ["Brød", :check]])
    run_baseline
    assert_match(/^- \[x\] +Melk$/, baseline_md)
    assert_match(/^- \[ \] +Brød$/, baseline_md)
  end

  def test_locked_note_without_checkboxes
    html = "<div>Liste</div><ul><li>Melk</li></ul>"
    add_note(html, [], locked: 1)
    run_baseline
    assert_equal NotesCommon.html_to_markdown(html)[0] + "\n", baseline_body
  end

  def test_overwrites_previous_conversion
    add_plain_note("<div>Hei</div>")
    File.write(File.join(@baseline, "#{UUID}.md"), "Gammel\n")
    commit_baseline
    run_baseline
    assert_equal "Hei\n", baseline_body
  end

  def test_removes_baseline_without_cache
    File.write(File.join(@baseline, "borte.md"), "Borte\n")
    commit_baseline
    out = run_baseline
    assert @status.success?, out
    refute File.exist?(File.join(@baseline, "borte.md"))
  end

  def test_leaves_md_files_in_notes_untouched
    add_plain_note("<div>Hei</div>")
    md = File.join(@root, "liste.md")
    File.write(md, "---\nnote_id: #{UUID}\n---\n\nRedigert\n")
    run_baseline
    assert_equal "---\nnote_id: #{UUID}\n---\n\nRedigert\n", File.read(md)
  end

  # Notes in the cache and the database, with one note that fails the check.
  def add_many_notes(count, failing: 0)
    db = SQLite3::Database.new @db
    count.times do |i|
      id = format("00000000-0000-0000-0000-%012d", i)
      html = i < failing ? "<div>Hei</div><!-- https://x.no/borte -->" : "<div>Hei</div>"
      File.write(File.join(@raw, "#{id}.html"), html)
      db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (ZIDENTIFIER, ZCREATIONDATE3) VALUES (?, 536500000.0)", [id.upcase]
    end
    db.close
  end

  # The progress line counts the failures so far, so a broken change can be
  # stopped early.
  # From the first failure on, every progress line shows the count.
  def test_shows_progress_and_failures_every_100_notes
    add_many_notes(200, failing: 1)
    out = run_baseline
    assert @status.success?, out
    assert_includes out, "[100/200] converted, 1 failed\n"
    assert_includes out, "[200/200] converted, 1 failed\n"
  end

  def test_progress_without_failures_has_no_count
    add_many_notes(100)
    out = run_baseline
    assert_includes out, "[100/100] converted\n"
  end

  # Ctrl-C stops cleanly, without a stack trace.
  def test_interrupt_stops_cleanly
    add_many_notes(400)
    env = { "NOTES_ROOT" => @root, "NOTES_RAW_CACHE" => @raw, "NOTES_BASELINE" => @baseline, "NOTES_DB" => @db,
            "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" }
    out = +""
    Open3.popen2e(env, "ruby", File.expand_path(SCRIPT, __dir__)) do |_, io, thr|
      out << io.gets.to_s until out.include?("converted") || io.eof?
      Process.kill("INT", thr.pid)
      out << io.read
      refute thr.value.success?
    end
    assert_includes out, "Aborted."
    refute_match(/\.rb:\d+:in /, out)
  end

  # The previous baseline must be committed or discarded first, so one diff
  # shows one code change.
  def test_uncommitted_baseline_aborts
    add_plain_note("<div>Hei</div>")
    File.write(File.join(@baseline, "#{UUID}.md"), "Ikke committet\n")
    out = run_baseline
    refute @status.success?, out
    assert_equal "#{@baseline} has uncommitted changes. Commit or discard them first (git -C #{@baseline} status).\n", out
    assert_equal "Ikke committet\n", baseline_md
  end

  def test_runs_again_after_commit
    add_plain_note("<div>Hei</div>")
    run_baseline
    commit_baseline
    out = run_baseline
    assert @status.success?, out
  end

  # The last line counts the notes that fail the check, before and now, so a
  # code change that breaks notes shows before ~/notes is rebuilt.
  def test_counts_notes_that_fail_the_check
    add_plain_note("<div>Hei</div><!-- https://x.no/borte -->")
    out = run_baseline
    assert @status.success?, out
    assert out.end_with?("1 note(s) fail the check (was 0).\n#{REPORT_HINT}"), out
    commit_baseline
    add_plain_note("<div>Hei</div>")
    out = run_baseline
    assert out.end_with?("0 note(s) fail the check (was 1).\n"), out
  end

  REPORT_HINT = "See why with notes report --baseline; it shows no text from the notes.\n"

  # Two notes, one that fails the check; a committed baseline of both, with a
  # mark in the file of the note that passes, to see whether it is rebuilt.
  def baseline_with_one_failure
    add_many_notes(2, failing: 1)
    run_baseline
    ok = File.join(@baseline, format("00000000-0000-0000-0000-%012d.md", 1))
    File.write(ok, File.read(ok) + "merke\n")
    File.write(File.join(@baseline, ".fingerprint"), "old")
    commit_baseline
    ok
  end

  # With notes that fail the check, it asks to rebuild only those first.
  def test_rebuilds_only_the_failed_notes
    ok = baseline_with_one_failure
    out = run_baseline(input: "y\n")
    assert @status.success?, out
    assert_includes out, "1 note(s) fail the check. Rebuild those first? [Y/n] "
    assert_includes out, "1 note(s) fail the check (was 1).\n1 still fail. Rebuild all notes anyway? [y/N] "
    assert out.end_with?(REPORT_HINT), out
    assert_includes File.read(ok), "merke", "a passing note was rebuilt"
    assert_equal "old", File.read(File.join(@baseline, ".fingerprint")), "a partial baseline is not current"
  end

  # Notes that still fail can be known (waiting for a decision), so it also
  # offers to rebuild all, with no as the default.
  def test_rebuild_all_anyway_while_notes_still_fail
    ok = baseline_with_one_failure
    out = run_baseline(input: "y\ny\n")
    assert @status.success?, out
    refute_includes File.read(ok), "merke"
    assert_equal NotesCommon.conversion_fingerprint, File.read(File.join(@baseline, ".fingerprint"))
    assert out.end_with?("1 note(s) fail the check (was 1).\n#{REPORT_HINT}"), out
  end

  # When the failed notes pass, it asks to rebuild all the others too.
  def test_asks_to_rebuild_all_when_the_failed_pass
    ok = baseline_with_one_failure
    File.write(File.join(@raw, format("00000000-0000-0000-0000-%012d.html", 0)), "<div>Hei</div>")
    out = run_baseline(input: "y\ny\n")
    assert @status.success?, out
    assert_includes out, "0 note(s) fail the check (was 1).\nAll pass. Rebuild all notes? [Y/n] "
    refute_includes File.read(ok), "merke"
    assert_equal NotesCommon.conversion_fingerprint, File.read(File.join(@baseline, ".fingerprint"))
    assert out.end_with?("0 note(s) fail the check (was 1).\n"), out
  end

  def test_no_to_rebuild_all_keeps_the_rest
    ok = baseline_with_one_failure
    File.write(File.join(@raw, format("00000000-0000-0000-0000-%012d.html", 0)), "<div>Hei</div>")
    out = run_baseline(input: "y\nn\n")
    assert @status.success?, out
    assert_includes File.read(ok), "merke"
    assert_equal "old", File.read(File.join(@baseline, ".fingerprint"))
  end

  def test_n_rebuilds_all_notes
    ok = baseline_with_one_failure
    out = run_baseline(input: "n\n")
    assert @status.success?, out
    refute_includes File.read(ok), "merke"
    assert_equal NotesCommon.conversion_fingerprint, File.read(File.join(@baseline, ".fingerprint"))
  end

  def test_no_question_without_failed_notes
    add_many_notes(2)
    run_baseline
    commit_baseline
    out = run_baseline(input: "y\n")
    refute_includes out, "Rebuild only those"
  end

  # The first time, the baseline folder is created as a git repo.
  def test_creates_the_baseline_folder_the_first_time
    FileUtils.rm_rf @baseline
    add_plain_note("<div>Hei</div>")
    out = run_baseline
    assert @status.success?, out
    assert_includes out, "Created #{@baseline} as a git repo.\n"
    assert File.directory?(File.join(@baseline, ".git"))
    assert File.exist?(File.join(@baseline, "#{UUID}.md"))
  end

  def test_help_says_the_folder_is_created
    out = run_baseline("--help")
    assert_includes out, "Created as a git repo the first time"
    refute_includes out, "Must exist"
  end

  def test_baseline_must_be_git_repo
    FileUtils.rm_rf File.join(@baseline, ".git")
    add_plain_note("<div>Hei</div>")
    out = run_baseline
    refute @status.success?, out
    assert_equal "#{@baseline} is not a git repo. Run: git -C #{@baseline} init\n", out
  end
end

require_relative 'export_helper'

# The baseline is the file the export writes, for every note, so a diff in
# ~/notes.baseline shows all a code change does: frontmatter with the result
# of the check, sections and tags, not only the converted text.
class BaselineMatchesExportTest < Minitest::Test
  include ExportHelper

  BASELINE = File.expand_path("../lib/notes_md/commands/baseline.rb", __dir__)
  EXPORT = File.expand_path("../lib/notes_md/commands/export.rb", __dir__)

  def export_and_baseline(dir, env)
    FileUtils.mkdir_p env["NOTES_BASELINE"]
    system("git", "-C", env["NOTES_BASELINE"], "init", "-q")
    out, status = run_script(BASELINE, env)
    assert status.success?, out
    out, _ = run_script(EXPORT, env)
    exported = File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
    [File.read(File.join(env["NOTES_BASELINE"], "#{ACTIVE}.md")), exported, out]
  end

  def test_baseline_file_is_the_exported_file
    Dir.mktmpdir do |dir|
      baseline, exported, out = export_and_baseline(dir, export_env(dir))
      assert_equal exported, baseline, out
      assert_includes baseline, "\nexport: pass\n"
    end
  end

  # An attachment is linked as in the export, checked against the original
  # file in Notes, and not copied into the baseline folder.
  def test_baseline_with_attachment_and_link
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      home = File.join(dir, "home")
      media = File.join(home, "Library", "Group Containers", "group.com.apple.notes", "Accounts", "KONTO", "Media", "MEDIA1", "x")
      FileUtils.mkdir_p media
      File.write(File.join(media, "bilde.png"), "png")
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (30, 'MEDIA1', 'bilde.png'), (31, 'KONTO', NULL)"
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (32, 5, 10, 30, 31)"
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTYPEUTI1, ZALTTEXT, ZTOKENCONTENTIDENTIFIER, ZNOTE1) VALUES " \
               "(20, 9, 'com.apple.notes.inlinetextattachment.link', 'Annet notat', 'applenotes:note/abc?ownerIdentifier=x', 10)"
      env = env.merge("HOME" => home, "RUBYOPT" => "-EUTF-8")
      baseline, exported, out = export_and_baseline(dir, env)
      assert_equal exported, baseline, out
      assert_includes baseline, "\nexport: pass\n"
      assert_includes baseline, "![bilde.png](assets/MEDIA1.png)"
      refute Dir.exist?(File.join(env["NOTES_BASELINE"], "assets"))
    end
  end
end
