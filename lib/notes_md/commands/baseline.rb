#!/usr/bin/env ruby
# encoding: UTF-8
# Converts the whole cache to the baseline folder, one <uuid>.md per note,
# built exactly as notes export builds it.
# The folder is outside ~/notes in its own git repo: `git diff` shows what a
# code change did to the conversion, `git commit` accepts it as the new
# baseline. The md files in ~/notes are not touched.

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require_relative '../common'
require 'fileutils'
require 'optparse'
require 'sqlite3'

TEST_FILE = "test/baseline_test.rb"

parser = OptionParser.new do |opts|
  opts.banner = "Usage: notes baseline\n\n" \
                "Shows what a code change or a pandoc upgrade does to every note, before it touches\n" \
                "your archive. Without it, you only find out when your real md files change.\n\n" \
                "Converts the whole local copy to the baseline folder (~/notes.baseline), one <uuid>.md per note,\n" \
                "built exactly as notes export builds it; attachments are linked, not copied.\n" \
                "See the changes with git diff in the folder, and commit to accept them as the new baseline.\n" \
                "The folder is created as a git repo the first time. It stops if the folder is not a git repo,\n" \
                "or if the previous baseline is not committed or discarded.\n" \
                "Shows how many notes have failed the check so far, so you can stop early with Ctrl-C,\n" \
                "and at the end, now and in the previous baseline. When notes fail the check, it first asks\n" \
                "whether to rebuild those first, then whether to rebuild all notes (default no while some still fail).\n" \
                "The md files in ~/notes are not touched.\n\n" \
                "Also records a fingerprint of the conversion code and pandoc version in .fingerprint.\n" \
                "notes export --marked and --failed offer to run notes baseline when the conversion has changed since.\n\n" \
                "Options:"
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  notes baseline"
  opts.separator "  notes baseline && git -C ~/notes.baseline diff"
  opts.separator ""
  opts.separator "Environment variables:"
  opts.separator "  NOTES_BASELINE  the baseline folder (default ~/notes.baseline). Created as a git repo the first time."
end
parser.parse!

shown = NotesCommon::BASELINE_DIR.sub(/\A#{Regexp.escape(Dir.home)}(?=\/|\z)/, "~")
# The first time, the folder is created as a git repo.
unless Dir.exist?(NotesCommon::BASELINE_DIR)
  FileUtils.mkdir_p NotesCommon::BASELINE_DIR
  system("git", "init", "-q", NotesCommon::BASELINE_DIR)
  puts "Created #{shown} as a git repo."
end

# The previous baseline must be committed or discarded first, so one diff
# shows one code change.
top, git_ok = Open3.capture2e("git", "-C", NotesCommon::BASELINE_DIR, "rev-parse", "--show-toplevel")
unless git_ok.success? && File.realpath(top.chomp) == File.realpath(NotesCommon::BASELINE_DIR)
  abort "#{shown} is not a git repo. Run: git -C #{shown} init"
end
changes, _ = Open3.capture2("git", "-C", NotesCommon::BASELINE_DIR, "status", "--porcelain")
abort "#{shown} has uncommitted changes. Commit or discard them first (git -C #{shown} status)." unless changes.empty?

db = NotesCommon.open_db

uuids = Dir.glob(File.join(NotesCommon::RAW_CACHE_DIR, "*.html")).map { |f| File.basename(f, ".html") }

# Notes that fail the check in the previous baseline, to compare with at the end.
failed_ids = Dir.glob(File.join(NotesCommon::BASELINE_DIR, "*.md"))
                .select { |f| File.read(f, 2000).to_s.match?(/^export: fail$/) }.map { |f| File.basename(f, ".md") }
failed_before = failed_ids.size

trap("INT") { warn "\nAborted."; exit 130 }
ask = ->(question, default_yes: true) {
  print "#{question} #{default_yes ? "[Y/n]" : "[y/N]"} "
  $stdout.flush
  answer = $stdin.gets.to_s.strip.downcase
  puts unless $stdin.tty?
  answer.empty? ? default_yes : answer == "y"
}

# Each file is built the way notes export builds it. Attachments are linked
# but not copied: the check looks for the original file in Notes instead.
# Returns how many of the notes fail the check.
original_exists = ->(_, src) { File.exist?(src) }
build = ->(ids) {
  failed = 0
  ids.each_with_index do |uuid, idx|
    # The failures so far, from the first one on, so a broken change can be
    # stopped early.
    puts "[#{idx + 1}/#{ids.size}] converted#{", #{failed} failed" if failed > 0}" if (idx + 1) % 100 == 0
    raw = File.read(File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.html"), encoding: "UTF-8")
    note_pk, cd_created = db.get_first_row("SELECT Z_PK, ZCREATIONDATE3 FROM ZICCLOUDSYNCINGOBJECT WHERE lower(ZIDENTIFIER) = ?", [uuid.downcase])
    unless note_pk
      warn "SKIPPING (not in DB): #{uuid}"
      next
    end
    built = NotesCommon.build_md(db, uuid, raw, note_pk: note_pk, created_date: NotesCommon.core_data_to_local_date(cd_created),
                                 ref_ok: original_exists)
    if built[:error]
      warn "ERROR pandoc for #{uuid}: #{built[:error]}"
      next
    end
    File.write(File.join(NotesCommon::BASELINE_DIR, "#{uuid}.md"), built[:text])
    failed += 1 if built[:result][:status] == "fail"
  end
  failed
}

# With notes that fail the check, those are rebuilt first: quick while a fix
# is worked on. Then it asks to rebuild the rest: yes by default when they
# all pass, no when some still fail (they may be known and waiting). A
# partial baseline keeps the other files and the old fingerprint, as it is
# not the baseline of the current code.
first = []
failed_now = 0
report_hint = -> { puts "See why with notes report --baseline; it shows no text from the notes." if failed_now > 0 }
if !failed_ids.empty? && ask.("#{failed_ids.size} note(s) fail the check. Rebuild those first?")
  first = uuids & failed_ids
  failed_now = build.(first)
  puts "#{failed_now} note(s) fail the check (was #{failed_before})."
  rest = failed_now.zero? ? ask.("All pass. Rebuild all notes?") : ask.("#{failed_now} still fail. Rebuild all notes anyway?", default_yes: false)
  unless rest
    report_hint.()
    exit 0
  end
end

failed_now += build.(uuids - first)
(Dir.glob(File.join(NotesCommon::BASELINE_DIR, "*.md")).map { |f| File.basename(f, ".md") } - uuids).each do |uuid|
  File.delete(File.join(NotesCommon::BASELINE_DIR, "#{uuid}.md"))
end
File.write(NotesCommon::FINGERPRINT_FILE, NotesCommon.conversion_fingerprint)
puts "#{failed_now} note(s) fail the check (was #{failed_before})."
report_hint.()
