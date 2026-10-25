require_relative 'script_usage_helper'
require 'fileutils'
require 'sqlite3'
require 'tmpdir'

SCRIPT = "../lib/notes_md/commands/prune.rb"

class NotesPruneTest < Minitest::Test
  include ScriptUsageHelper

  STORE = "STORE-UUID"
  A = "11111111-1111-1111-1111-111111111111"
  B = "22222222-2222-2222-2222-222222222222"
  C = "33333333-3333-3333-3333-333333333333"

  def setup
    @dir = Dir.mktmpdir
    @root = File.join(@dir, "notes")
    @raw = File.join(@root, "apple_notes.raw")
    @db = File.join(@dir, "NoteStore.sqlite")
    @bin = File.join(@dir, "bin")
    @log = File.join(@dir, "osascript.log")
    FileUtils.mkdir_p [@raw, @bin]
    File.write(File.join(@bin, "osascript"), "#!/bin/sh\nprintf '%s\\n' \"$*\" >> #{@log}\n")
    File.chmod(0o755, File.join(@bin, "osascript"))
    db = SQLite3::Database.new @db
    db.execute "CREATE TABLE Z_METADATA (Z_UUID TEXT)"
    db.execute "INSERT INTO Z_METADATA VALUES (?)", [STORE]
    db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZTITLE1 TEXT, " \
               "ZTITLE2 TEXT, ZPARENT INTEGER, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER, ZMARKEDFORDELETION INTEGER, " \
               "ZCREATIONDATE3 REAL, Z_ENT INTEGER, ZNOTE INTEGER)"
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (1, 'Journal', 0), (2, 'Nylig slettet', 1)"
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZPARENT, ZFOLDERTYPE) VALUES (3, '2018', 1, 0)"
    db.close
  end

  def teardown
    FileUtils.rm_rf @dir
  end

  def add_note(pk, uuid, title, folder: 3, deleted: 0, html: nil)
    db = SQLite3::Database.new @db
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION, ZCREATIONDATE3) " \
               "VALUES (?, ?, ?, ?, ?, ?)", [pk, uuid.upcase, title, folder, deleted, 536_500_000.0]
    db.close
    return unless html
    File.write(File.join(@raw, "#{uuid}.html"), html)
    File.write(File.join(@raw, "#{uuid}.txt"), "txt")
  end

  def add_md(uuid)
    File.write(File.join(@root, "#{uuid}.md"), "---\nnote_id: #{uuid}\n---\n\ntekst\n")
  end

  def add_attachment(note_pk)
    db = SQLite3::Database.new @db
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE) VALUES (?, 5, ?)", [1000 + note_pk, note_pk]
    db.close
  end

  def run_review(input, *args)
    out, status = Open3.capture2e(
      { "NOTES_ROOT" => @root, "NOTES_RAW_CACHE" => @raw, "NOTES_DB" => @db,
        "PATH" => "#{@bin}:#{ENV['PATH']}", "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
      "ruby", File.expand_path(SCRIPT, __dir__), *args, stdin_data: input
    )
    [out.force_encoding("UTF-8"), status]
  end

  def deletions
    File.exist?(@log) ? File.read(@log) : ""
  end

  def test_help_shows_usage
    assert_usage_on_help("lib/notes_md/commands/prune.rb")
  end

  def test_shows_missing_note_with_cache_content
    add_note(10, A, "Tom dag", html: "<div>16.01.2018</div><div>Innhold her</div>")
    out, status = run_review("n\n")
    assert status.success?, out
    assert_includes out, "[1/1] Tom dag"
    assert_includes out, "journal/2018"
    assert_includes out, A
    assert_includes out, "<div>16.01.2018</div><div>Innhold her</div>"
    assert_includes out, "[y/N/q]"
    assert_equal "", deletions
  end

  def test_yes_deletes_via_applescript_and_removes_cache
    add_note(10, A, "Tom dag", html: "<div>x</div>")
    run_review("y\n")
    assert_includes deletions, "x-coredata://#{STORE}/ICNote/p10"
    assert_includes deletions, ".delete()"
    refute File.exist?(File.join(@raw, "#{A}.html"))
    refute File.exist?(File.join(@raw, "#{A}.txt"))
  end

  def test_no_keeps_note_and_cache
    add_note(10, A, "Tom dag", html: "<div>x</div>")
    run_review("n\n")
    assert_equal "", deletions
    assert File.exist?(File.join(@raw, "#{A}.html"))
  end

  def test_enter_defaults_to_no
    add_note(10, A, "Tom dag", html: "<div>x</div>")
    run_review("\n")
    assert_equal "", deletions
  end

  def test_one_at_a_time_in_order
    add_note(10, A, "a", html: "<div>x</div>")
    add_note(11, B, "b", html: "<div>y</div>")
    out, _ = run_review("n\ny\n")
    assert_operator out.index("[1/2] a"), :<, out.index("[2/2] b")
    assert_includes deletions, "ICNote/p11"
    refute_includes deletions, "ICNote/p10"
  end

  def test_notes_with_md_are_skipped
    add_note(10, A, "har md", html: "<div>x</div>")
    add_md(A)
    add_note(11, B, "mangler", html: "<div>y</div>")
    out, _ = run_review("n\n")
    refute_includes out, "har md"
    assert_includes out, "[1/1] mangler"
  end

  def test_notes_in_recently_deleted_and_marked_deleted_are_skipped
    add_note(10, A, "i papirkurv", folder: 2, html: "<div>x</div>")
    add_note(11, B, "merket slettet", deleted: 1, html: "<div>y</div>")
    add_note(12, C, "mangler", html: "<div>z</div>")
    out, _ = run_review("n\n")
    refute_includes out, "papirkurv"
    refute_includes out, "merket slettet"
    assert_includes out, "[1/1] mangler"
  end

  def test_note_without_cache_says_so
    add_note(10, A, "uten cache")
    out, _ = run_review("n\n")
    assert_includes out, "(no cache)"
  end

  def test_q_stops
    add_note(10, A, "a", html: "<div>x</div>")
    add_note(11, B, "b", html: "<div>y</div>")
    out, status = run_review("q\n")
    assert status.success?, out
    refute_includes out, "[2/2]"
  end

  def test_eof_stops_cleanly
    add_note(10, A, "a", html: "<div>x</div>")
    out, status = run_review("")
    assert status.success?, out
    refute_match(/Error|\.rb:\d+/, out)
  end

  def test_nothing_missing_is_silent
    add_note(10, A, "har md", html: "<div>x</div>")
    add_md(A)
    out, status = run_review("")
    assert status.success?, out
    assert_equal "", out
  end

  def test_failed_applescript_keeps_cache_and_reports
    File.write(File.join(@bin, "osascript"), "#!/bin/sh\necho 'feil fra notes' >&2\nexit 1\n")
    add_note(10, A, "a", html: "<div>x</div>")
    out, _ = run_review("y\n")
    assert_includes out, "feil fra notes"
    assert File.exist?(File.join(@raw, "#{A}.html"))
  end

  # --empty: empty notes are deleted together, cache first, then in Notes
  def test_empty_lists_only_obviously_empty_notes
    add_note(10, A, "16.01.2018", html: "<div><h1>16.01.2018</h1></div><div><br></div>")
    add_note(11, B, "Handleliste", html: "<div>Handleliste</div><div>melk</div>")
    add_note(12, C, "uten cache")
    out, status = run_review("n\n", "--empty")
    assert status.success?, out
    assert_includes out, "16.01.2018"
    refute_includes out, "Handleliste"
    refute_includes out, "uten cache"
    assert_includes out, "Delete cache for 1 empty notes? [y/N]"
    refute_includes out, "in Notes?"
    assert_equal "", deletions
    assert File.exist?(File.join(@raw, "#{A}.html"))
  end

  def test_empty_yes_deletes_all_and_removes_cache
    add_note(10, A, "16.01.2018", html: "<div>16.01.2018</div>")
    add_note(11, B, "17.01.2018", html: "<div>17.01.2018&nbsp;</div><div></div>")
    out, _ = run_review("y\ny\n", "--empty")
    assert_includes out, "Delete the 2 notes in Notes? [y/N]"
    assert_includes deletions, "ICNote/p10"
    assert_includes deletions, "ICNote/p11"
    refute File.exist?(File.join(@raw, "#{A}.html"))
    refute File.exist?(File.join(@raw, "#{B}.txt"))
  end

  def test_empty_html_without_text_counts_as_empty
    add_note(10, A, "Ny notat", html: "<div><br></div>")
    out, _ = run_review("n\n", "--empty")
    assert_includes out, "Delete cache for 1 empty"
  end

  def test_empty_note_with_attachment_is_not_empty
    add_note(10, A, "16.01.2018", html: "<div>16.01.2018</div>")
    add_attachment(10)
    add_note(11, B, "17.01.2018", html: "<div>17.01.2018</div><div><img src=\"x\"></div>")
    out, status = run_review("", "--empty")
    assert status.success?, out
    assert_equal "", out
    assert_equal "", deletions
  end

  def test_empty_skips_notes_with_md
    add_note(10, A, "16.01.2018", html: "<div>16.01.2018</div>")
    add_md(A)
    out, _ = run_review("", "--empty")
    assert_equal "", out
  end

  def test_empty_failed_applescript_continues
    File.write(File.join(@bin, "osascript"), "#!/bin/sh\ncase \"$*\" in *p10*) echo 'feil fra notes' >&2; exit 1;; esac\nprintf '%s\\n' \"$*\" >> #{@log}\n")
    add_note(10, A, "16.01.2018", html: "<div>16.01.2018</div>")
    add_note(11, B, "17.01.2018", html: "<div>17.01.2018</div>")
    out, _ = run_review("y\ny\n", "--empty")
    assert_includes out, "feil fra notes"
    assert_includes deletions, "ICNote/p11"
  end

  def test_empty_cache_deleted_before_notes_question
    add_note(10, A, "16.01.2018", html: "<div>16.01.2018</div>")
    out, _ = run_review("y\nn\n", "--empty")
    refute File.exist?(File.join(@raw, "#{A}.html"))
    refute File.exist?(File.join(@raw, "#{A}.txt"))
    assert_includes out, "Delete the 1 notes in Notes? [y/N]"
    assert_equal "", deletions
  end
end
