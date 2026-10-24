require_relative 'export_helper'
require_relative 'script_usage_helper'
require_relative '../notes_common'

SCRIPT = "../libexec/export"

SCRIPT_PATH = File.expand_path "../libexec/export", __dir__

class ExportTest < Minitest::Test
  include ScriptUsageHelper
  include ExportHelper

  def run_export(env, dir, *args, input: "y\n") = run_script(SCRIPT_PATH, env, *args, input: input)

  def test_help_shows_usage
    assert_usage_on_help("libexec/export")
  end

  def test_usage_lists_every_mode
    out = `ruby #{SCRIPT_PATH} --help 2>&1`
    assert_includes out, "Usage: notes export [--marked | --failed]\n"
  end

  def test_folder_name_argument_fails
    out = `ruby #{SCRIPT_PATH} "Claude" 2>&1`
    refute $?.success?, "should fail when a folder name is given"
    assert_match(/notes export takes no positional arguments/, out)
  end

  def test_marked_and_failed_cannot_be_combined
    out = `ruby #{SCRIPT_PATH} --marked --failed 2>&1`
    refute $?.success?
    assert_match(/--marked cannot be combined with --failed/, out)
  end

  def test_export_skips_notes_in_recently_deleted
    Dir.mktmpdir do |dir|
      out, _ = run_export(export_env(dir), dir)
      assert_equal ["journal/2018-01-01 aktiv.md"], import_files(dir), out
    end
  end

  def test_export_uses_timezone_from_env
    Dir.mktmpdir do |dir|
      env = export_env(dir).merge("TZ" => "UTC")
      cd = Time.utc(2024, 12, 31, 23, 30, 0).to_i - 978307200
      sql env, "UPDATE ZICCLOUDSYNCINGOBJECT SET ZCREATIONDATE3 = ? WHERE Z_PK = 10", [cd.to_f]
      out, _ = run_export(env, dir)
      assert_equal ["journal/2024-12-31 aktiv.md"], import_files(dir), out
    end
  end

  def test_export_builds_only_notes_without_md
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      root = File.join(dir, "notes")
      c = "33333333-3333-3333-3333-333333333333"
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION, ZCREATIONDATE3) " \
               "VALUES (12, ?, 'Ny', 1, 0, 536500000.0)", [c.upcase]
      File.write(File.join(env["NOTES_RAW_CACHE"], "#{c}.html"), "<div>Ny</div><div>tekst</div>")
      File.write(File.join(env["NOTES_RAW_CACHE"], "#{c}.txt"), "txt")
      existing = File.join(root, "journal", "aktiv.md")
      FileUtils.mkdir_p File.dirname(existing)
      before = "---\nnote_id: #{ACTIVE}\n---\n\nendret for hånd\n"
      File.write(existing, before)
      commit_all(dir)
      out, _ = run_export(env, dir)
      assert_equal before, File.read(existing), out
      assert_equal ["journal/2018-01-01 ny.md"], import_files(dir), out
      assert_includes out, "Creating md files for 1 notes without an md file. Existing files are not touched."
      refute_includes out, "WARNING"
      refute_includes out, "Checklist"
    end
  end

  def checklist_export(dir, locked: 0)
    env = export_env(dir)
    File.write(cache(env, ACTIVE, "html"), "<div>Aktiv</div><ul><li>Melk</li><li>Egg</li></ul>")
    db = SQLite3::Database.new env["NOTES_DB"]
    db.execute "UPDATE ZICCLOUDSYNCINGOBJECT SET ZISPASSWORDPROTECTED = ? WHERE Z_PK = 10", [locked]
    blob = locked == 1 ? "kryptert".b : Proto.zdata([["Aktiv", :plain], ["Melk", :done], ["Egg", :check]])
    db.execute "INSERT INTO ZICNOTEDATA (ZNOTE, ZDATA) VALUES (10, ?)", [SQLite3::Blob.new(blob)]
    db.close
    out, _ = run_export(env, dir)
    [File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md")), out]
  end

  def test_export_sets_checkboxes_from_zdata
    Dir.mktmpdir do |dir|
      md, out = checklist_export(dir)
      assert_includes md, "- [x] Melk\n- [ ] Egg\n", out
      refute_includes out, "CHECKBOX"
    end
  end

  def test_export_locked_note_keeps_plain_list
    Dir.mktmpdir do |dir|
      md, out = checklist_export(dir, locked: 1)
      refute_includes md, "[x]", out
      refute_includes md, "[ ]", out
      assert_match(/Melk/, md)
    end
  end

  def test_export_writes_hashtags_as_tag
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTYPEUTI1, ZALTTEXT, ZNOTE1) VALUES " \
               "(20, 'com.apple.notes.inlinetextattachment.hashtag', '#handel', 10), " \
               "(21, 'com.apple.notes.inlinetextattachment.hashtag', '#mat', 10)"
      out, _ = run_export(env, dir)
      md = File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
      assert_includes md, "tags: [handel, mat]\n", out
    end
  end

  def add_note(env, pk, uuid, title, html, folder: 1)
    sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION, ZCREATIONDATE3) " \
             "VALUES (?, ?, ?, ?, 0, 536500000.0)", [pk, uuid.upcase, title, folder]
    File.write(cache(env, uuid, "html"), html)
    File.write(cache(env, uuid, "txt"), "txt")
  end

  def test_new_note_gets_frontmatter_and_body
    Dir.mktmpdir do |dir|
      out, status = run_export(export_env(dir), dir)
      assert status.success?, out
      assert_equal BUILT_MD, File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
      assert_includes out, "Done: 0 identical, 0 overwritten, 1 new"
      refute_includes out, "New:"
      assert out.end_with?("\nnext: check the changes with git diff, then stage and commit them yourself (git add, git commit).\n"), out
    end
  end

  # The export writes export: pass itself; fm is not part of notes.
  def test_export_status_written_without_fm
    Dir.mktmpdir do |dir|
      path = ENV["PATH"].split(File::PATH_SEPARATOR).reject { |d| File.exist?(File.join(d, "fm")) }.join(File::PATH_SEPARATOR)
      out, status = run_export(export_env(dir).merge("PATH" => path), dir)
      assert status.success?, out
      assert_equal BUILT_MD, File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
    end
  end

  def test_rerun_finds_nothing_to_build
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      run_export(env, dir)
      out, _ = run_export(env, dir, input: "y\nn\n")
      assert_includes out, "No new notes"
      assert_equal ["journal/2018-01-01 aktiv.md"], import_files(dir)
    end
  end

  # An exported file whose body is still what the export wrote, but older
  # than the note in the cache.
  def untouched_md
    old = ACTIVE_MD.sub("tekst", "gammel")
    old.sub("export: pass\n", "export: pass\nnote_sum: #{NotesCommon.body_sum(old)}\n")
  end

  def test_export_offers_to_update_untouched_notes
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      path = write_md(dir, "journal/aktiv.md", untouched_md)
      out, _ = run_export(env, dir, input: "y\n")
      assert_includes out, "Also update 1 notes you have not changed yourself? [y/N] "
      refute_includes out, "Continue?"
      assert_equal BUILT_MD, File.read(path), out
    end
  end

  def test_export_leaves_untouched_notes_on_no
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      path = write_md(dir, "journal/aktiv.md", untouched_md)
      out, _ = run_export(env, dir, input: "n\n")
      assert_equal untouched_md, File.read(path), out
      assert_includes out, "No new notes"
    end
  end

  def test_export_does_not_offer_notes_changed_by_hand
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      text = untouched_md.sub("gammel", "skrevet for hånd")
      path = write_md(dir, "journal/aktiv.md", text)
      out, _ = run_export(env, dir)
      refute_includes out, "Also update", out
      assert_equal text, File.read(path), out
    end
  end

  def test_export_never_overwrites_existing_md
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      text = ACTIVE_MD.sub("tekst", "skrevet for hånd")
      path = write_md(dir, "journal/aktiv.md", text)
      out, _ = run_export(env, dir)
      assert_equal text, File.read(path), out
      assert_includes out, "No new notes"
    end
  end

  def test_existing_md_found_by_note_id_and_updated_in_place
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      path = write_md(dir, "egen/omdøpt.md", ACTIVE_MD.sub("export: pass", "export: true").sub("tekst", "gammel tekst"))
      out, _ = run_export(env, dir, "--marked")
      assert_equal BUILT_MD, File.read(path), out
      assert_includes out, "Done: 0 identical, 1 overwritten, 0 new"
      refute_includes out, "Overwritten:"
      assert_empty import_files(dir)
    end
  end

  def test_marked_skips_export_false
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      text = ACTIVE_MD.sub("export: pass", "export: false").sub("tekst", "skrevet for hånd")
      path = write_md(dir, "journal/aktiv.md", text)
      out, _ = run_export(env, dir, "--marked")
      assert_equal text, File.read(path), out
      assert_includes out, "No files with export: true"
    end
  end

  def test_answer_other_than_y_writes_nothing
    Dir.mktmpdir do |dir|
      out, status = run_export(export_env(dir), dir, input: "n\n")
      assert status.success?, out
      assert_includes out, "Aborted."
      assert_empty import_files(dir)
    end
  end

  def test_failed_takes_only_failed
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      path = write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("tekst", "gammel"))
      out, _ = run_export(env, dir, "--failed")
      assert_includes out, "No files with export: fail"
      File.write(path, ACTIVE_MD.sub("export: pass", "export: fail").sub("tekst", "gammel"))
      commit_all(dir)
      out, _ = run_export(env, dir, "--failed")
      assert_includes out, "Done: 0 identical, 1 overwritten, 0 new"
      refute_includes out, "Overwritten:"
      assert_empty import_files(dir)
    end
  end

  def test_stops_when_notes_is_not_a_git_repo
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      FileUtils.rm_rf File.join(dir, "notes", ".git")
      out, status = run_export(env, dir)
      refute status.success?
      assert_includes out, "~/notes is not a git repo. Run git -C ~/notes init and commit before exporting."
      assert_empty import_files(dir)
    end
  end

  def test_asks_when_md_files_are_not_committed
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      File.write(File.join(dir, "notes", "egen.md"), "uendret\n")
      out, status = run_export(env, dir, input: "n\n")
      refute status.success?
      assert_includes out, "1 md file(s) in ~/notes have uncommitted changes."
      assert_includes out, "Continue without a commit? [y/N] "
      assert_includes out, "Commit ~/notes first, so the export can be rolled back."
      assert_empty import_files(dir)
      out, _ = run_export(env, dir, input: "y\ny\n")
      assert_equal ["journal/2018-01-01 aktiv.md"], import_files(dir), out
    end
  end

  def test_no_question_when_committed
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      out, _ = run_export(env, dir)
      refute_includes out, "uncommitted"
      write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: true"))
      out, _ = run_export(env, dir, "--marked")
      refute_includes out, "uncommitted"
      refute_includes out, "run git commit first"
    end
  end

  def test_progress_counts_checked_notes
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      100.times { |i| add_note(env, 100 + i, format("44444444-4444-4444-4444-%012d", i), "N#{i}", "<div>N#{i}</div>") }
      out, _ = run_export(env, dir)
      assert_includes out, "[100/101] checked (0 identical, 0 overwritten)", out
    end
  end

  def test_add_sum_flag_is_gone
    Dir.mktmpdir do |dir|
      out, status = run_export(export_env(dir), dir, "--add-sum")
      refute status.success?
      assert_match(/invalid option: --add-sum/, out)
    end
  end

  def test_rebuild_keeps_own_frontmatter_fields
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      text = ACTIVE_MD.sub("export: pass", "export: true").sub("note_id", "hint: \"a: b\"\nnote_id")
                      .sub("---\n\n", "reviews: 3\nsteps:\n  - one\n  - two\n---\n\n").sub("tekst", "gammel")
      path = write_md(dir, "journal/aktiv.md", text)
      out, _ = run_export(env, dir, "--marked")
      md = File.read(path)
      assert_includes md, "\nhint: \"a: b\"\n", out
      assert_includes md, "\nreviews: 3\n", out
      assert_includes md, "\nsteps:\n  - one\n  - two\n", out
      assert_includes md, "\nexport: pass\n", out
      assert_match(/\n\nAktiv\ntekst\n\z/, md)
    end
  end

  def test_export_writes_checksum_of_body
    Dir.mktmpdir do |dir|
      run_export(export_env(dir), dir)
      md = File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
      assert_equal NotesCommon.body_sum(md), NotesCommon.frontmatter(md)["note_sum"]
    end
  end

  def test_rebuild_skips_file_edited_by_hand
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      edited = BUILT_MD.sub("export: pass", "export: true").sub("tekst", "tekst\nmin egen linje")
      path = write_md(dir, "journal/aktiv.md", edited)
      out, _ = run_export(env, dir, "--marked")
      assert_equal edited, File.read(path), out
      assert_includes out, "1 file(s) edited by hand since the export, not rebuilt.\n"
      refute_includes out, "next:"
      refute_includes out, "  journal/aktiv.md"
    end
  end

  # A file with export: fail that was edited afterwards is not rebuilt either.
  def test_failed_skips_file_edited_by_hand
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      edited = BUILT_MD.sub("export: pass", "export: fail").sub("tekst", "tekst\nmin egen linje")
      path = write_md(dir, "journal/aktiv.md", edited)
      out, _ = run_export(env, dir, "--failed")
      assert_equal edited, File.read(path), out
      assert_includes out, "1 file(s) edited by hand since the export, not rebuilt.\n"
    end
  end

  def test_rebuild_ignores_frontmatter_changes_in_checksum
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      path = write_md(dir, "journal/aktiv.md", BUILT_MD.sub("export: pass", "export: true\nreviews: 2"))
      out, _ = run_export(env, dir, "--marked")
      refute_includes out, "edited by hand", out
      assert_includes File.read(path), "\nexport: pass\n"
    end
  end

  # A baseline with this fingerprint in the test baseline folder.
  def baseline_with(env, fingerprint)
    FileUtils.mkdir_p env["NOTES_BASELINE"]
    File.write(File.join(env["NOTES_BASELINE"], ".fingerprint"), fingerprint)
    system("git", "-C", env["NOTES_BASELINE"], "init", "-q")
    system("git", "-C", env["NOTES_BASELINE"], "add", "-A")
    system("git", "-C", env["NOTES_BASELINE"], "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "baseline")
  end

  def test_no_to_baseline_continues_export
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      baseline_with(env, "old")
      %w[--marked --failed].each do |flag|
        mark = flag == "--marked" ? "true" : "fail"
        path = write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: #{mark}").sub("tekst", "gammel"))
        out, _ = run_export(env, dir, flag, input: "n\ny\n")
        assert_includes out, "The conversion has changed since the last notes baseline", flag
        assert_includes out, "Run notes baseline now? [Y/n] ", flag
        assert_equal BUILT_MD, File.read(path), "#{flag}: #{out}"
        assert_equal "old", File.read(File.join(env["NOTES_BASELINE"], ".fingerprint")), flag
      end
    end
  end

  def test_stop_offers_to_build_baseline_then_stops
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      baseline_with(env, "old")
      text = ACTIVE_MD.sub("export: pass", "export: true").sub("tekst", "gammel")
      path = write_md(dir, "journal/aktiv.md", text)
      out, status = run_export(env, dir, "--marked", input: "\n")
      refute status.success?, out
      assert_equal NotesCommon.conversion_fingerprint, File.read(File.join(env["NOTES_BASELINE"], ".fingerprint")), out
      assert_includes out, "Check git -C ~/notes.baseline diff, then run notes export --marked again."
      assert_equal text, File.read(path)
      out, _ = run_export(env, dir, "--marked")
      assert_equal BUILT_MD, File.read(path), out
    end
  end

  def test_marked_runs_when_baseline_is_current
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      baseline_with(env, NotesCommon.conversion_fingerprint)
      path = write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: true").sub("tekst", "gammel"))
      out, _ = run_export(env, dir, "--marked")
      assert_equal BUILT_MD, File.read(path), out
    end
  end

  def test_new_notes_not_stopped_by_old_baseline
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      baseline_with(env, "old")
      out, status = run_export(env, dir)
      assert status.success?, out
      assert_equal ["journal/2018-01-01 aktiv.md"], import_files(dir)
    end
  end

  def test_marked_runs_without_baseline_folder
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      path = write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: true").sub("tekst", "gammel"))
      out, _ = run_export(env, dir, "--marked")
      assert_equal BUILT_MD, File.read(path), out
      assert_includes out, "Tip: create ~/notes.baseline to see what a code change does before files are rewritten."
    end
  end

  def test_no_tip_with_baseline_or_for_new_notes
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      out, _ = run_export(env, dir)
      refute_includes out, "Tip:"
      baseline_with(env, NotesCommon.conversion_fingerprint)
      write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: true"))
      out, _ = run_export(env, dir, "--marked")
      refute_includes out, "Tip:"
    end
  end

  def test_marked_takes_only_marked
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      path = write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("tekst", "gammel"))
      out, _ = run_export(env, dir, "--marked")
      assert_includes out, "No files with export: true"
      File.write(path, ACTIVE_MD.sub("export: pass", "export: true").sub("tekst", "gammel"))
      commit_all(dir)
      out, _ = run_export(env, dir, "--marked")
      assert_includes out, "1 file(s) with export: true.\n\n"
      assert_includes out, "Done: 0 identical, 1 overwritten, 0 new"
      refute_includes out, "Overwritten:"
      assert_empty import_files(dir)
    end
  end

  def test_mark_is_replaced_even_when_body_is_unchanged
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      path = write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: true"))
      out, _ = run_export(env, dir, "--marked")
      assert_includes out, "Done: 0 identical, 1 overwritten, 0 new"
      refute_includes out, "Overwritten:"
      assert_includes File.read(path), "\nexport: pass\n"
    end
  end

  def test_incomplete_cache_stops_before_writing
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      File.delete cache(env, ACTIVE, "txt")
      out, status = run_export(env, dir)
      refute status.success?
      assert_includes out, "WARNING: 1 of 1 candidates are missing a complete cache"
      assert_empty import_files(dir)
    end
  end

  def test_cache_without_note_in_db_is_skipped
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      File.write(cache(env, GHOST, "html"), "<div>Borte</div>")
      File.write(cache(env, GHOST, "txt"), "txt")
      out, _ = run_export(env, dir)
      assert_includes out, "SKIPPING (not in DB): #{GHOST}"
      assert_equal ["journal/2018-01-01 aktiv.md"], import_files(dir)
    end
  end

  def test_new_file_does_not_overwrite_file_with_same_name
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      text = "---\nnote_id: 99999999-9999-9999-9999-999999999999\n---\n\nannet notat\n"
      other = write_md(dir, "import/journal/2018-01-01 aktiv.md", text)
      run_export(env, dir)
      assert_equal text, File.read(other)
      assert_includes import_files(dir), "journal/2018-01-01 aktiv 2.md"
    end
  end

  def test_notes_import_sets_import_dir
    Dir.mktmpdir do |dir|
      env = export_env(dir).merge("NOTES_IMPORT" => File.join(dir, "notes", "annet"))
      out, _ = run_export(env, dir)
      assert File.exist?(File.join(dir, "notes", "annet", "journal", "2018-01-01 aktiv.md")), out
      assert_empty import_files(dir)
    end
  end

  def test_import_dir_outside_notes_root_is_refused
    Dir.mktmpdir do |dir|
      env = export_env(dir).merge("NOTES_IMPORT" => File.join(dir, "ut"))
      out, status = run_export(env, dir)
      refute status.success?
      assert_includes out, "NOTES_IMPORT must be under #{File.join(dir, 'notes')}"
      refute Dir.exist?(File.join(dir, "ut"))
    end
  end

  def test_import_dir_with_foreign_files_is_refused
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      write_md(dir, "import/handleliste.md", "melk\n")
      write_md(dir, "import/bilder/ferie.jpg", "jpg")
      out, status = run_export(env, dir)
      refute status.success?
      import = File.join(dir, "notes", "import")
      assert_includes out, "#{import} contains files that do not come from the export:\n" \
                           "  import/bilder/ferie.jpg\n  import/handleliste.md\nEmpty or move the folder first."
      assert_equal ["handleliste.md"], import_files(dir)
    end
  end

  def test_import_dir_with_hidden_files_is_refused
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      write_md(dir, "import/.DS_Store", "x")
      write_md(dir, "import/.skjult/notat.md", "melk\n")
      out, status = run_export(env, dir)
      refute status.success?
      import = File.join(dir, "notes", "import")
      assert_includes out, "#{import} contains files that do not come from the export:\n" \
                           "  import/.DS_Store\n  import/.skjult/notat.md\nEmpty or move the folder first."
    end
  end

  def test_import_dir_with_exported_files_and_assets_is_accepted
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      write_md(dir, "import/journal/eldre.md", "---\nnote_id: 99999999-9999-9999-9999-999999999999\n---\n\nx\n")
      write_md(dir, "import/journal/assets/bilde.png", "png")
      out, status = run_export(env, dir)
      assert status.success?, out
      assert_includes import_files(dir), "journal/2018-01-01 aktiv.md"
    end
  end

  def test_new_note_in_subfolder
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZPARENT, ZFOLDERTYPE) VALUES (3, 'Reiser', 1, 0)"
      add_note(env, 12, "33333333-3333-3333-3333-333333333333", "Tur", "<div>Tur</div>", folder: 3)
      run_export(env, dir)
      md = File.read(File.join(dir, "notes", "import", "journal", "reiser", "2018-01-01 tur.md"))
      refute_includes md, "folder:"
    end
  end

  def test_internal_links_section
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTYPEUTI1, ZALTTEXT, ZTOKENCONTENTIDENTIFIER, ZNOTE1) VALUES " \
               "(20, 9, 'com.apple.notes.inlinetextattachment.link', 'Annet notat', 'applenotes:note/abc?ownerIdentifier=x', 10)"
      run_export(env, dir)
      md = File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
      assert_includes md, "tekst\n\n## Internal links\n- Annet notat → applenotes:note/abc\n"
    end
  end

  # NOTES_LANG=nb writes the section headings in Norwegian.
  def test_norwegian_section_headings
    Dir.mktmpdir do |dir|
      md = export_with_sections(dir, "<div>Aktiv</div>", "NOTES_LANG" => "nb")
      assert_includes md, "\n\n## Vedlegg\n![bilde.png](assets/MEDIA1.png)\n\n## Interne lenker\n- Annet notat → applenotes:note/abc\n"
    end
  end

  def test_unknown_language_gives_one_line
    Dir.mktmpdir do |dir|
      out, status = run_export(export_env(dir).merge("NOTES_LANG" => "xx"), dir)
      refute status.success?
      assert_equal "NOTES_LANG must be one of: en, nb\n", out
    end
  end

  def test_attachment_copied_to_assets_and_listed
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      home = File.join(dir, "home")
      media = File.join(home, "Library", "Group Containers", "group.com.apple.notes", "Accounts", "KONTO", "Media", "MEDIA1", "x")
      FileUtils.mkdir_p media
      File.write(File.join(media, "bilde.png"), "png")
      File.write(File.join(media, "forhåndsvisning.png"), "ikke vedlegget")
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (30, 'MEDIA1', 'bilde.png'), (31, 'KONTO', NULL)"
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (32, 5, 10, 30, 31)"
      out, _ = run_export(env.merge("HOME" => home), dir)
      assets = Dir.glob(File.join(dir, "notes", "import", "journal", "assets", "*"))
      assert_equal [File.join(dir, "notes", "import", "journal", "assets", "MEDIA1.png")], assets, out
      assert_equal "png", File.read(assets.first)
      md = File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
      assert_includes md, "tekst\n\n## Attachments\n![bilde.png](assets/MEDIA1.png)\n"
    end
  end

  # The active note with body html, one attachment and one internal link;
  # returns the exported md.
  def export_with_sections(dir, html, extra_env = {})
    env = export_env(dir).merge(extra_env)
    File.write(File.join(env["NOTES_RAW_CACHE"], "#{ACTIVE}.html"), html)
    home = File.join(dir, "home")
    media = File.join(home, "Library", "Group Containers", "group.com.apple.notes", "Accounts", "KONTO", "Media", "MEDIA1", "x")
    FileUtils.mkdir_p media
    File.write(File.join(media, "bilde.png"), "png")
    sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (30, 'MEDIA1', 'bilde.png'), (31, 'KONTO', NULL)"
    sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (32, 5, 10, 30, 31)"
    sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTYPEUTI1, ZALTTEXT, ZTOKENCONTENTIDENTIFIER, ZNOTE1) VALUES " \
             "(20, 9, 'com.apple.notes.inlinetextattachment.link', 'Annet notat', 'applenotes:note/abc?ownerIdentifier=x', 10)"
    out, _ = run_export(env.merge("HOME" => home, "RUBYOPT" => "-EUTF-8"), dir)
    path = File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md")
    assert File.exist?(path), out
    File.read(path)
  end

  # Ufravikelig: tom linje foran enhver overskrift i hele den skrevne fila,
  # også ### og dypere, og også foran ## Attachments og ## Internal links.
  def test_blank_line_before_every_heading_in_written_file
    (1..6).each do |n|
      ["<div>Aktiv</div><h#{n}>Slutt</h#{n}>", "<div>Aktiv</div><h#{n}>Midt</h#{n}><div>tekst</div>",
       "<ul><li>a</li></ul><h#{n}>Etter liste</h#{n}><div>x</div>",
       "<div>Aktiv</div><h#{n == 6 ? 5 : n + 1}>Over</h#{n == 6 ? 5 : n + 1}><h#{n}>Under</h#{n}><div>x</div>"].each do |html|
        Dir.mktmpdir do |dir|
          md = export_with_sections(dir, html)
          lines = md.sub(NotesCommon::FRONTMATTER, "").split("\n", -1)
          lines.each_with_index do |line, i|
            next unless i > 0 && line.match?(/\A {0,3}\#{1,6}(\s|\z)/)
            assert_equal "", lines[i - 1], "no blank line before line #{i + 1}: #{md.inspect}"
          end
          assert_includes md, "\n\n## Attachments\n"
        end
      end
    end
  end

  def test_sections_after_body_ending_with_heading
    Dir.mktmpdir do |dir|
      md = export_with_sections(dir, "<div>Aktiv</div><h2>Slutt</h2>")
      assert_includes md, "\n\nAktiv\n\n## Slutt\n\n## Attachments\n![bilde.png](assets/MEDIA1.png)\n\n" \
                          "## Internal links\n- Annet notat → applenotes:note/abc\n"
      assert md.end_with?("applenotes:note/abc\n"), md
    end
  end

  def test_sections_after_body_ending_with_invisible_line
    Dir.mktmpdir do |dir|
      md = export_with_sections(dir, "<div>Aktiv</div><h2>Slutt</h2><div>&nbsp;</div>")
      assert_includes md, "## Slutt\n\n## Attachments\n"
    end
  end

  def test_sections_with_empty_body
    Dir.mktmpdir do |dir|
      md = export_with_sections(dir, "")
      assert_match(/\n---\n\n## Attachments\n!\[bilde\.png\]/, md)
    end
  end

  # ZFILENAME is a folder (folder dragged into the note, Numbers package):
  # the attachment is the zip next to it, not the files Notes has unpacked.
  def export_package(filename, inner)
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      home = File.join(dir, "home")
      media = File.join(home, "Library", "Group Containers", "group.com.apple.notes", "Accounts", "KONTO", "Media", "MEDIA1", "x")
      FileUtils.mkdir_p File.join(media, filename)
      File.write(File.join(media, "#{filename}.zip"), "zip")
      inner.each do |n|
        FileUtils.mkdir_p File.dirname(File.join(media, filename, n))
        File.write(File.join(media, filename, n), n)
      end
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (30, 'MEDIA1', ?), (31, 'KONTO', NULL)", [filename]
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (32, 5, 10, 30, 31)"
      out, _ = run_export(env.merge("HOME" => home), dir)
      assets = File.join(dir, "notes", "import", "journal", "assets")
      md = File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
      yield out, Dir.children(assets).sort, File.read(File.join(assets, "MEDIA1.zip")), md
    end
  end

  def test_folder_attachment_exports_only_the_zip
    export_package("Apple mail bug", ["a.png", "b.png", "notat.txt"]) do |out, assets, zip, md|
      assert_equal ["MEDIA1.zip"], assets, out
      assert_equal "zip", zip
      assert_includes md, "\n\n## Attachments\n[Apple mail bug.zip](assets/MEDIA1.zip)\n"
    end
  end

  def test_numbers_package_exports_only_the_zip
    export_package("Regneark.numbers", ["Index.zip", "Data/preview.jpg"]) do |out, assets, _, md|
      assert_equal ["MEDIA1.zip"], assets, out
      assert_includes md, "\n\n## Attachments\n[Regneark.numbers.zip](assets/MEDIA1.zip)\n"
    end
  end

  def test_attachment_label_is_nfc
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      home = File.join(dir, "home")
      media = File.join(home, "Library", "Group Containers", "group.com.apple.notes", "Accounts", "KONTO", "Media", "MEDIA1", "x")
      FileUtils.mkdir_p media
      nfd = "blåbær.png".unicode_normalize(:nfd)
      File.write(File.join(media, nfd), "png")
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (30, 'MEDIA1', ?), (31, 'KONTO', NULL)", [nfd]
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (32, 5, 10, 30, 31)"
      out, _ = run_export(env.merge("HOME" => home), dir)
      md = File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
      assert_includes md, "![blåbær.png](assets/MEDIA1.png)", out
    end
  end

  def test_attachment_label_escapes_brackets
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      home = File.join(dir, "home")
      media = File.join(home, "Library", "Group Containers", "group.com.apple.notes", "Accounts", "KONTO", "Media", "MEDIA1", "x")
      FileUtils.mkdir_p media
      File.write(File.join(media, 'bilde [1]\.png'), "png")
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (30, 'MEDIA1', ?), (31, 'KONTO', NULL)", ['bilde [1]\.png']
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (32, 5, 10, 30, 31)"
      out, _ = run_export(env.merge("HOME" => home), dir)
      md = File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md"))
      assert_includes md, '![bilde \[1\]\\\\.png](assets/MEDIA1.png)', out
    end
  end

  def test_attachment_named_by_media_uuid_on_rebuild
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      home = File.join(dir, "home")
      media = File.join(home, "Library", "Group Containers", "group.com.apple.notes", "Accounts", "KONTO", "Media", "MEDIA2", "x")
      FileUtils.mkdir_p media
      File.write(File.join(media, "Kontrakt.PDF"), "pdf")
      write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: true"))
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (30, 'MEDIA1', 'borte.png'), (31, 'KONTO', NULL), (33, 'MEDIA2', 'Kontrakt.PDF')"
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (32, 5, 10, 30, 31), (34, 5, 10, 33, 31)"
      out, _ = run_export(env.merge("HOME" => home), dir, "--marked")
      assert_equal "pdf", File.read(File.join(dir, "notes", "journal", "assets", "MEDIA2.pdf")), out
      md = File.read(File.join(dir, "notes", "journal", "aktiv.md"))
      assert_includes md, "\n\n## Attachments\n[Kontrakt.PDF](assets/MEDIA2.pdf)\n"
    end
  end

  def test_attachment_not_downloaded_is_warned
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      home = File.join(dir, "home")
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (30, 'MEDIA1', 'borte.png'), (31, 'KONTO', NULL)"
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (32, 5, 10, 30, 31)"
      out, _ = run_export(env.merge("HOME" => home), dir)
      assert_includes out, "ATTACHMENT NOT DOWNLOADED: import/journal/2018-01-01 aktiv.md (MEDIA1)"
    end
  end

  def test_large_change_is_warned
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: true").sub("tekst\n", "en\nto\ntre\nfire\nfem\n"))
      out, _ = run_export(env, dir, "--marked")
      assert_match(/LARGE CHANGE: journal\/aktiv\.md \(\+3\/-6\)/, out)
      assert_includes out, "1 file(s) had large changes (use git diff to check that nothing was lost).\n"
      assert_equal 1, out.scan("journal/aktiv.md (+3/-6)").size
    end
  end

  def test_blank_lines_are_not_a_large_change
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      write_md(dir, "journal/aktiv.md", ACTIVE_MD.sub("export: pass", "export: true").sub("Aktiv\n", "Aktiv\n\n\n\n\n\n"))
      out, _ = run_export(env, dir, "--marked")
      assert_includes out, "Done: 0 identical, 1 overwritten, 0 new"
      refute_includes out, "LARGE CHANGE"
      refute_includes out, "had large changes"
    end
  end

  def test_argument_errors
    Dir.mktmpdir do |dir|
      env = export_env(dir)
      [[["journal"], /notes export takes no positional arguments/],
       [["--marked", "--failed"], /--marked cannot be combined with --failed/],
       [["--marked", "journal"], /notes export takes no positional arguments/],
       [["--export"], /invalid option: --export/]].each do |args, pattern|
        out, status = run_export(env, dir, *args)
        refute status.success?, args.inspect
        assert_match pattern, out, args.inspect
      end
      assert_empty import_files(dir)
    end
  end

  def test_export_fills_missing_cache_from_notes
    Dir.mktmpdir do |dir|
      env, bin = fill_env(dir)
      out, status = run_export(env, dir, input: "y\ny\n")
      assert status.success?, out
      assert_equal "x-coredata://STORE/ICNote/p10", File.read(File.join(bin, "asked"))
      assert_equal "<div>Fra Notes</div>", File.read(cache(env, ACTIVE, "html"))
      assert_equal "Fra Notes", File.read(cache(env, ACTIVE, "txt"))
      assert_includes File.read(File.join(dir, "notes", "import", "journal", "2018-01-01 aktiv.md")), "\nFra Notes\n"
    end
  end

  def test_export_does_not_ask_notes_when_cache_in_sync
    Dir.mktmpdir do |dir|
      env, bin = fill_env(dir)
      write_cache(env, ACTIVE)
      out, _ = run_export(env, dir)
      refute File.exist?(File.join(bin, "asked")), out
      refute_includes out, "Sync the cache"
    end
  end

  def test_export_answer_no_converts_from_cache_without_notes
    Dir.mktmpdir do |dir|
      env, bin = fill_env(dir)
      out, _ = run_export(env, dir, input: "n\ny\n")
      refute File.exist?(File.join(bin, "asked")), out
      assert_includes out, "No new notes"
    end
  end

  def test_export_fills_only_limit_folder
    Dir.mktmpdir do |dir|
      env, bin = fill_env(dir)
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (3, 'Arkiv', 0)"
      sql env, "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION, ZCREATIONDATE3) " \
               "VALUES (12, '33333333-3333-3333-3333-333333333333', 'Annet', 3, 0, 536500000.0)"
      run_export(env.merge("NOTES_LIMIT_FOLDER" => "arkiv"), dir, input: "y\nn\n")
      assert_equal "x-coredata://STORE/ICNote/p12", File.read(File.join(bin, "asked"))
    end
  end

  def test_help_and_argument_errors_do_not_kill_notes
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "killed")
      File.write(File.join(dir, "killall"), "#!/bin/sh\ntouch #{marker}\n")
      File.chmod(0o755, File.join(dir, "killall"))
      env = { "PATH" => "#{dir}:#{ENV['PATH']}" }
      [["--help"], ["--marked", "--failed"], ["journal"]].each do |args|
        Open3.capture2e(env, "ruby", SCRIPT_PATH, *args)
        refute File.exist?(marker), "killall ran for #{args.inspect}"
      end
    end
  end
end
