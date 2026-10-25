require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'tmpdir'
require 'sqlite3'
require_relative 'notes_proto_helper'
require_relative 'test_env'
require_relative '../lib/notes_md/common'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# Test database, cache and folders shared by export_test.rb and sync_test.rb.
module ExportHelper
  ACTIVE = "11111111-1111-1111-1111-111111111111"
  TRASHED = "22222222-2222-2222-2222-222222222222"
  GHOST = "44444444-4444-4444-4444-444444444444"
  ACTIVE_MD = "---\ncreated_at: 2018-01-01\nexport: pass\nnote_id: #{ACTIVE}\n---\n\nAktiv\ntekst\n"
  # ACTIVE_MD as the export writes it, with the checksum of the body.
  BUILT_MD = ACTIVE_MD.sub("\n---\n\n", "\nnote_sum: #{NotesCommon.body_sum(ACTIVE_MD)}\n---\n\n")

  def export_env(dir)
    root = File.join(dir, "notes")
    raw = File.join(root, "apple_notes.raw")
    db_path = File.join(dir, "NoteStore.sqlite")
    FileUtils.mkdir_p raw
    db = SQLite3::Database.new db_path
    db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, " \
               "ZTITLE1 TEXT, ZTITLE2 TEXT, ZPARENT INTEGER, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER, " \
               "ZMARKEDFORDELETION INTEGER, ZISPASSWORDPROTECTED INTEGER, ZCREATIONDATE3 REAL, ZMODIFICATIONDATE1 REAL, " \
               "ZTYPEUTI1 TEXT, ZNOTE INTEGER, ZNOTE1 INTEGER, ZALTTEXT TEXT, ZTOKENCONTENTIDENTIFIER TEXT, " \
               "ZMEDIA INTEGER, ZACCOUNT1 INTEGER, ZFILENAME TEXT)"
    db.execute "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)"
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (1, 'Journal', 0), (2, 'Nylig slettet', 1)"
    [[10, ACTIVE, "Aktiv", 1], [11, TRASHED, "Slettet", 2]].each do |pk, uuid, title, folder|
      db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION, ZCREATIONDATE3) " \
                 "VALUES (?, ?, ?, ?, 0, 536500000.0)", [pk, uuid.upcase, title, folder]
      File.write(File.join(raw, "#{uuid}.html"), "<div>#{title}</div><div>tekst</div>")
      File.write(File.join(raw, "#{uuid}.txt"), "txt")
    end
    db.close
    system("git", "init", "-q", root)
    { "NOTES_DB" => db_path, "NOTES_RAW_CACHE" => raw, "NOTES_ROOT" => root, "NOTES_SKIP_DB_CHECK" => "1",
      "NOTES_BASELINE" => File.join(dir, "notes.baseline"),
      "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" }
  end

  def run_script(script, env, *args, input: "y\n")
    out, status = Open3.capture2e(env, "ruby", script, *args, stdin_data: input)
    [out.force_encoding("UTF-8"), status]
  end

  def import_files(dir)
    import = File.join(dir, "notes", "import")
    Dir.glob(File.join(import, "**", "*.md")).map { |f| f.delete_prefix(import + "/") }.sort
  end

  # Writes a file in the test archive and commits it, as the user would
  # before an export.
  def write_md(dir, rel, text)
    path = File.join(dir, "notes", rel)
    FileUtils.mkdir_p File.dirname(path)
    File.write(path, text)
    commit_all(dir)
    path
  end

  def commit_all(dir)
    root = File.join(dir, "notes")
    system("git", "-C", root, "add", "-A")
    system("git", "-C", root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "test", out: File::NULL)
  end

  # Fake osascript: answers the JXA script with the note the way Notes does,
  # one block per id, and logs which ids were asked for.
  def fake_notes(dir)
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p bin
    File.write(File.join(bin, "osascript"), <<~'RUBY')
      #!/usr/bin/env ruby
      script = ARGV.last
      delim = script[/const delim = "([^"]+)"/, 1]
      ids = script[/const ids = \[(.*?)\];/, 1].scan(/"([^"]+)"/).flatten
      File.write(File.join(__dir__, "asked"), ids.join("\n"))
      blobs = ids.map { |id| "Fra Notes\n2018-01-01\n2018-01-01\n#{id}\n---BODY---\n<div>Fra Notes</div>\n---PLAINTEXT---\nFra Notes" }
      print [ids.size.to_s, *blobs].join(delim)
    RUBY
    File.write(File.join(bin, "killall"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(bin, "osascript"), File.join(bin, "killall"))
    bin
  end

  # Empty cache, a store UUID and a fake Notes, so the sync fetches for real.
  def fill_env(dir)
    env = export_env(dir)
    db = SQLite3::Database.new env["NOTES_DB"]
    db.execute "CREATE TABLE Z_METADATA (Z_UUID TEXT)"
    db.execute "INSERT INTO Z_METADATA VALUES ('STORE')"
    db.close
    File.delete(*Dir.glob(File.join(env["NOTES_RAW_CACHE"], "#{ACTIVE}.*")))
    File.delete(*Dir.glob(File.join(env["NOTES_RAW_CACHE"], "#{TRASHED}.*")))
    env.delete("NOTES_SKIP_DB_CHECK")
    bin = fake_notes(dir)
    [env.merge("PATH" => "#{bin}:#{ENV['PATH']}"), bin]
  end

  def cache(env, uuid, ext) = File.join(env["NOTES_RAW_CACHE"], "#{uuid}.#{ext}")

  def write_cache(env, uuid)
    File.write(cache(env, uuid, "html"), "<div>Aktiv</div><div>tekst</div>")
    File.write(cache(env, uuid, "txt"), "txt")
  end

  def sql(env, *args)
    db = SQLite3::Database.new env["NOTES_DB"]
    db.execute(*args)
    db.close
  end
end
