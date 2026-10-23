require_relative 'script_usage_helper'
require 'fileutils'
require 'sqlite3'
require 'tmpdir'

SCRIPT = "../libexec/compare"

class CompareTest < Minitest::Test
  include ScriptUsageHelper

  A = "11111111-1111-1111-1111-111111111111"
  B = "22222222-2222-2222-2222-222222222222"

  def setup
    @dir = Dir.mktmpdir
    @root = File.join(@dir, "notes")
    @raw = File.join(@root, "apple_notes.raw")
    @db = File.join(@dir, "NoteStore.sqlite")
    FileUtils.mkdir_p @raw
    db = SQLite3::Database.new @db
    db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZTITLE1 TEXT, " \
               "ZTITLE2 TEXT, ZPARENT INTEGER, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER, ZMARKEDFORDELETION INTEGER, " \
               "ZISPASSWORDPROTECTED INTEGER, ZCREATIONDATE3 REAL)"
    db.execute "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)"
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (1, 'Journal', 0), (2, 'Nylig slettet', 1)"
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION) VALUES " \
               "(10, ?, 'a', 1, 0), (11, ?, 'b', 2, 0)", [A.upcase, B.upcase]
    db.close
    File.write(File.join(@root, "a.md"), "---\ncreated_at: 2024-01-01\nnote_id: #{A}\n---\n\ntekst\n")
  end

  def teardown
    FileUtils.rm_rf @dir
  end

  def run_compare(*args)
    out, status = Open3.capture2e(
      { "NOTES_DB" => @db, "NOTES_ROOT" => @root, "NOTES_RAW_CACHE" => @raw,
        "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
      "ruby", File.expand_path(SCRIPT, __dir__), "-s", @root, *args
    )
    [out.force_encoding("UTF-8"), status]
  end

  def test_help_shows_usage
    assert_usage_on_help("libexec/compare")
  end

  def test_recently_deleted_not_shown_or_counted
    out, _ = run_compare("-v")
    refute_match(/nylig slettet/i, out)
    refute_includes out, B
    assert_match(/^journal\s+1\s+1\s+✅/, out)
    assert_match(/^Total\s+1\s+1\s+✅/, out)
  end

  def test_md_for_note_in_recently_deleted_is_orphaned
    File.write(File.join(@root, "b.md"), "---\ncreated_at: 2024-01-01\nnote_id: #{B}\n---\n\ntekst\n")
    out, _ = run_compare
    assert_match(/^journal\s+1\s+1\s+✅/, out)
    assert_match(/⚠️/, check_line(out, "md files without a note in Notes"))
    assert_includes check_line(out, "md files without a note in Notes"), "(notes compare -v)"
  end

  C = "33333333-3333-3333-3333-333333333333"
  D = "44444444-4444-4444-4444-444444444444"

  def sql(*args)
    db = SQLite3::Database.new @db
    db.execute(*args)
    db.close
  end

  def md(name, uuid, extra = "", body = "tekst")
    path = File.join(@root, name)
    FileUtils.mkdir_p File.dirname(path)
    File.write(path, "---\nnote_id: #{uuid}\n#{extra}---\n\n#{body}\n")
  end

  def check_line(out, label)
    out.lines.find { |l| l.start_with?(label) }
  end

  def test_missing_note_counted_and_listed_verbose
    sql "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION) VALUES (12, ?, 'c', 1, 0)", [C.upcase]
    out, _ = run_compare("-v")
    assert_match(/^journal\s+2\s+1\s+⚠️\s+1 missing/, out)
    assert_match(/missing \(1\):\n\s+#{C}/, out)
  end

  def test_missing_not_hidden_by_orphan_in_same_folder
    sql "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION) VALUES (12, ?, 'c', 1, 0)", [C.upcase]
    md("d.md", D)
    out, _ = run_compare
    assert_match(/^journal\s+2\s+1\s+⚠️\s+1 missing$/, out)
    assert_match(/⚠️/, check_line(out, "md files without a note in Notes"))
  end

  def test_note_marked_for_deletion_not_counted
    sql "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION) VALUES (12, ?, 'c', 1, 1)", [C.upcase]
    out, _ = run_compare
    assert_match(/^journal\s+1\s+1\s+✅/, out)
  end

  def test_md_counted_in_notes_folder_wherever_it_is_on_disk
    sql "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (3, 'Arkiv', 0)"
    sql "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION) VALUES (12, ?, 'c', 3, 0)", [C.upcase]
    md("journal/c.md", C, "folder: journal\n")
    out, _ = run_compare
    assert_match(/^arkiv\s+1\s+1\s+✅/, out)
    assert_match(/^journal\s+1\s+1\s+✅/, out)
  end

  def test_orphan_md_listed_verbose
    md("d.md", D)
    out, _ = run_compare("-v")
    assert_match(/## Orphaned \(1\)\n\s+#{D}/, out)
  end

  def test_export_fail_counted
    File.write(File.join(@root, "a.md"), "---\nnote_id: #{A}\nexport: fail\n---\n\ntekst\n")
    out, _ = run_compare
    assert_match(/^journal\s+1\s+1\s+⚠️\s+1 fail/, out)
    assert_match(/^Total\s+1\s+1\s+⚠️\s+1 fail/, out)
  end

  def test_folder_filter_shows_subfolders_indented
    sql "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZPARENT, ZFOLDERTYPE) VALUES (3, '2024', 1, 0), (4, 'Arkiv', NULL, 0)"
    sql "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION) VALUES (12, ?, 'c', 3, 0)", [C.upcase]
    md("2024/c.md", C)
    out, _ = run_compare("journal")
    assert_match(/^journal\s+1\s+1\s+✅/, out)
    assert_match(/^  2024\s+1\s+1\s+✅/, out)
    refute_match(/arkiv/i, out)
    assert_match(/^Total\s+2\s+2\s+✅/, out)
  end

  def test_folder_filter_without_match
    out, status = run_compare("finnes ikke")
    assert status.success?, out
    assert_equal "No folders found\n", out
  end

  def test_folder_filter_does_not_match_prefix_of_other_folder
    sql "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (3, 'Journalen', 0)"
    out, _ = run_compare("journal")
    refute_includes out, "journalen"
  end

  def test_all_checks_ok_on_clean_tree
    FileUtils.touch [File.join(@raw, "#{A}.html"), File.join(@raw, "#{A}.txt")]
    out, _ = run_compare
    ["Disk health check", "Local copy", "md files without a note in Notes"].each do |label|
      assert_match(/✅/, check_line(out, label), label)
    end
  end

  def test_health_problem_warns
    md("a.md", A, "created_at: 2024-01-01\n", "![](assets/borte.png)")
    out, _ = run_compare
    assert_match(/⚠️/, check_line(out, "Disk health check"))
  end

  def test_raw_cache_needs_both_html_and_txt
    FileUtils.touch File.join(@raw, "#{A}.html")
    out, _ = run_compare("-v")
    assert_match(/⚠️/, check_line(out, "Local copy"))
    assert_match(/## Missing from local copy \(1\)\n\s+#{A}/, out)
  end

  def test_verbose_silent_when_all_ok
    FileUtils.touch [File.join(@raw, "#{A}.html"), File.join(@raw, "#{A}.txt")]
    out, _ = run_compare("-v")
    refute_includes out, "## "
  end
end
