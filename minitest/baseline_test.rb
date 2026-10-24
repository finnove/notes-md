require_relative 'script_usage_helper'
require_relative 'notes_proto_helper'
require 'fileutils'
require 'sqlite3'
require 'tmpdir'
require_relative '../notes_common'

SCRIPT = "../libexec/baseline"

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
    db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZISPASSWORDPROTECTED INTEGER, ZALTTEXT TEXT)"
    db.execute "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)"
    db.close
  end

  def teardown
    FileUtils.rm_rf @dir
  end

  def add_note(html, items, locked: 0)
    File.write(File.join(@raw, "#{UUID}.html"), html)
    db = SQLite3::Database.new @db
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (ZIDENTIFIER, ZISPASSWORDPROTECTED) VALUES (?, ?)", [UUID.upcase, locked]
    pk = db.last_insert_row_id
    blob = locked == 1 ? "kryptert".b : Proto.zdata(items)
    db.execute "INSERT INTO ZICNOTEDATA (ZNOTE, ZDATA) VALUES (?, ?)", [pk, SQLite3::Blob.new(blob)]
    db.close
  end

  def add_plain_note(html)
    File.write(File.join(@raw, "#{UUID}.html"), html)
  end

  # Commits everything in the baseline folder, as the user does after a diff.
  def commit_baseline
    system("git", "-C", @baseline, "add", "-A")
    system("git", "-C", @baseline, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "baseline")
  end

  def baseline_md
    File.read(File.join(@baseline, "#{UUID}.md"), encoding: "UTF-8")
  end

  def run_baseline(*args)
    out, @status = Open3.capture2e(
      { "NOTES_ROOT" => @root, "NOTES_RAW_CACHE" => @raw, "NOTES_BASELINE" => @baseline, "NOTES_DB" => @db,
        "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
      "ruby", File.expand_path(SCRIPT, __dir__), *args
    )
    out.force_encoding("UTF-8")
  end

  def test_help_shows_usage
    assert_usage_on_help("libexec/baseline")
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
    assert_equal "Hei\n", baseline_md
  end

  def test_headings_blank_lines
    add_plain_note("<div>tekst</div><h1>Tittel</h1><div>a</div><h2>Vedlegg</h2><div><br></div><h2>Under</h2>" \
                   "<div> </div><h3>Dypere</h3><div><br></div><div>b</div>")
    out = run_baseline
    assert @status.success?, out
    assert_equal "tekst\n\n# Tittel\n\na\n\n## Vedlegg\n\n## Under\n\n### Dypere\nb\n", baseline_md
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
    assert_equal NotesCommon.html_to_markdown(html)[0] + "\n", baseline_md
  end

  def test_overwrites_previous_conversion
    add_plain_note("<div>Hei</div>")
    File.write(File.join(@baseline, "#{UUID}.md"), "Gammel\n")
    commit_baseline
    run_baseline
    assert_equal "Hei\n", baseline_md
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

  def test_shows_progress_every_100_notes
    100.times { |i| File.write(File.join(@raw, "#{i}.html"), "<div>Hei</div>") }
    out = run_baseline
    assert @status.success?, out
    assert_includes out, "[100/100] converted"
  end

  def test_missing_baseline_dir_aborts
    FileUtils.rm_rf @baseline
    add_plain_note("<div>Hei</div>")
    out = run_baseline
    refute @status.success?, out
    assert_match(/notes\.baseline/, out)
    refute Dir.exist?(@baseline)
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

  def test_baseline_must_be_git_repo
    FileUtils.rm_rf File.join(@baseline, ".git")
    add_plain_note("<div>Hei</div>")
    out = run_baseline
    refute @status.success?, out
    assert_equal "#{@baseline} is not a git repo. Run: git -C #{@baseline} init\n", out
  end
end
