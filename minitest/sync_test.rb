require_relative 'export_helper'
require_relative 'script_usage_helper'

SCRIPT = "../libexec/sync"

class SyncTest < Minitest::Test
  include ScriptUsageHelper
  include ExportHelper

  SYNC = File.expand_path("../libexec/sync", __dir__)

  def run_sync(env, *args, input: "y\n") = run_script(SYNC, env, *args, input: input)

  def test_help_shows_usage
    assert_usage_on_help("libexec/sync")
  end

  def test_sync_ignores_foreign_files_in_import_dir
    Dir.mktmpdir do |dir|
      env, _ = fill_env(dir)
      write_cache(env, ACTIVE)
      write_md(dir, "import/handleliste.md", "melk\n")
      out, status = run_sync(env, input: "")
      assert status.success?, out
    end
  end

  def test_sync_lists_missing_and_fetches_after_yes
    Dir.mktmpdir do |dir|
      env, bin = fill_env(dir)
      out, status = run_sync(env)
      assert status.success?, out
      assert_match(/^Missing from cache: 1\n  Journal  Aktiv\n/, out)
      assert_equal "x-coredata://STORE/ICNote/p10", File.read(File.join(bin, "asked"))
      assert_equal "<div>Fra Notes</div>", File.read(cache(env, ACTIVE, "html"))
      assert_empty import_files(dir)
    end
  end

  def test_sync_answer_no_changes_nothing
    Dir.mktmpdir do |dir|
      env, bin = fill_env(dir)
      write_cache(env, GHOST)
      run_sync(env, input: "n\n")
      refute File.exist?(File.join(bin, "asked"))
      refute File.exist?(cache(env, ACTIVE, "html"))
      assert File.exist?(cache(env, GHOST, "html"))
    end
  end

  def test_sync_in_sync_is_silent
    Dir.mktmpdir do |dir|
      env, bin = fill_env(dir)
      write_cache(env, ACTIVE)
      out, status = run_sync(env, input: "")
      assert status.success?, out
      assert_equal "", out
      refute File.exist?(File.join(bin, "asked"))
    end
  end

  def test_sync_refetches_note_changed_after_caching
    Dir.mktmpdir do |dir|
      env, _ = fill_env(dir)
      write_cache(env, ACTIVE)
      File.utime(Time.at(0), Time.at(0), cache(env, ACTIVE, "html"), cache(env, ACTIVE, "txt"))
      sql env, "UPDATE ZICCLOUDSYNCINGOBJECT SET ZMODIFICATIONDATE1 = 536500000.0 WHERE Z_PK = 10"
      out, _ = run_sync(env)
      assert_match(/^Changed in Notes: 1\n  Journal  Aktiv\n/, out)
      assert_equal "<div>Fra Notes</div>", File.read(cache(env, ACTIVE, "html"))
    end
  end

  def test_sync_refetches_half_cache
    Dir.mktmpdir do |dir|
      env, _ = fill_env(dir)
      File.write(cache(env, ACTIVE, "html"), "<div>gammel</div>")
      out, _ = run_sync(env)
      assert_match(/^Partial cache: 1\n  Journal  Aktiv\n/, out)
      assert_equal "Fra Notes", File.read(cache(env, ACTIVE, "txt"))
    end
  end

  def test_sync_deletes_cache_for_trashed_and_gone_notes
    Dir.mktmpdir do |dir|
      env, bin = fill_env(dir)
      write_cache(env, ACTIVE)
      write_cache(env, TRASHED)
      write_cache(env, GHOST)
      out, _ = run_sync(env)
      assert_match(/^In "Recently Deleted" – removed from cache: 1\n  Nylig slettet  Slettet\n/, out)
      assert_match(/^Not in Notes – removed from cache: 1\n  #{GHOST}  txt\n/, out)
      [TRASHED, GHOST].each { |u| assert_empty Dir.glob(cache(env, u, "*")), u }
      assert File.exist?(cache(env, ACTIVE, "html"))
      refute File.exist?(File.join(bin, "asked"))
    end
  end

  def test_sync_v_shows_notes_to_be_deleted_then_asks_again
    Dir.mktmpdir do |dir|
      env, _ = fill_env(dir)
      write_cache(env, ACTIVE)
      File.write(cache(env, GHOST, "html"), "<div>Gammelt notat</div>")
      File.write(cache(env, GHOST, "txt"), "Gammelt notat\nlinje 2")
      out, _ = run_sync(env, input: "v\nn\n")
      assert_match(/^  #{GHOST}  Gammelt notat\n/, out)
      assert_match(/── #{GHOST} ──\nGammelt notat\nlinje 2\n/, out)
      assert_equal 2, out.scan("Sync the cache? [y/N/v]").size
      assert File.exist?(cache(env, GHOST, "txt"))
    end
  end

  def test_sync_lists_locked_notes_separately
    Dir.mktmpdir do |dir|
      env, _ = fill_env(dir)
      sql env, "UPDATE ZICCLOUDSYNCINGOBJECT SET ZISPASSWORDPROTECTED = 1 WHERE Z_PK = 10"
      out, _ = run_sync(env, input: "n\n")
      assert_match(/^Locked – unlock in Notes first: 1\n  Journal  Aktiv\n/, out)
      refute_includes out, "Missing from cache"
    end
  end

  def test_sync_takes_no_arguments
    Dir.mktmpdir do |dir|
      env, _ = fill_env(dir)
      out, status = run_sync(env, "--export")
      refute status.success?
      assert_match(/invalid option: --export/, out)
    end
  end
end
