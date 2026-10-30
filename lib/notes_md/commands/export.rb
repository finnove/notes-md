#!/usr/bin/env ruby
# The pandoc version affects the output. Known behaviour:
#   - 3.8.3+: parses `\&entity;` as an escaped entity and swallows it. notes_common
#     pre-processes these in transform_html to avoid data loss.
# If you see unexpected DIFFERENCES in files that used to pass, check whether
# pandoc was upgraded: `pandoc --version`.
require 'fileutils'
require 'optparse'
require 'set'
require 'sqlite3'

TEST_FILE = "test/export_test.rb"
require_relative '../sync'

begin

cache_complete = ->(uuid) {
  File.exist?(File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.html")) &&
    File.exist?(File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.txt"))
}

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: notes export [--marked | --failed | --assets]\n\n" \
                "Turns your notes into plain md files you own, with attachments and checkboxes\n" \
                "intact. Without it, your notes stay locked inside Apple Notes.\n\n" \
                "Syncs the local copy first (see notes sync), then converts from it.\n" \
                "Creates ~/notes as a git repo the first time. Stops if it exists and is not a git\n" \
                "repo, and asks if md files are uncommitted.\n" \
                "A rebuild skips files edited by hand since the export (note_sum) and keeps\n" \
                "frontmatter fields you added yourself.\n\n" \
                "Without options: builds md files for notes without an md file, and asks\n" \
                "whether to also update the notes you have not changed yourself.\n" \
                "New notes land in NOTES_IMPORT.\n\n" \
                "md files are matched on note_id in the frontmatter, not on the filename.\n" \
                "You can safely rename the md files; --marked writes back to the same path.\n\n" \
                "--marked and --failed offer to run notes baseline if the conversion code or\n" \
                "pandoc has changed since the last one, so you see what changed before real\n" \
                "files are rewritten. y runs it and stops; n rebuilds without it.\n" \
                "Without a baseline folder there is no such check.\n\n" \
                "After writing files, runs notes health and shows only the problems that\n" \
                "were not there before the export; any gives exit 1.\n\n" \
                "Options:"
  opts.on("--marked", "Rebuild notes with export: true in the frontmatter;",
                      "the files are overwritten where they are if the content has changed") { options[:marked] = true }
  opts.on("--failed", "Like --marked, but notes with export: fail in the frontmatter") { options[:failed] = true }
  opts.on("--assets", "Write the attachment section of every md file as the export writes it now,",
                      "also in files edited by hand; the rest of the file is not touched. Copies",
                      "missing attachments, and deletes an old attachment file only when it is the",
                      "same file under its new name and nothing else links to it. Counts first and asks") { options[:assets] = true }
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  notes export"
  opts.separator "  notes export --marked"
  opts.separator "  notes export --failed"
  opts.separator "  notes export --assets"
  opts.separator ""
  opts.separator "Environment variables:"
  opts.separator "  NOTES_IMPORT  where new md files land (default ~/notes/import). Must be under"
  opts.separator "                ~/notes and may only contain files from the export."
  opts.separator "  NOTES_LANG    language of the section headings: en (default) or nb (Norwegian)."
  opts.separator "  NOTES_BOLD_LINE_AS_HEADING=1  a line that is only bold text in Notes becomes a ## heading."
end
parser.parse!

given = %i[marked failed assets].select { |o| options[o] }
abort "--#{given[0].to_s.tr("_", "-")} cannot be combined with --#{given[1].to_s.tr("_", "-")}" if given.size > 1
abort "notes export takes no positional arguments" if ARGV[0]
options[:export] = given.empty?
rebuild = options[:marked] || options[:failed]
mode = options[:marked] ? "--marked" : "--failed"

# A rebuild rewrites real files; check first that the baseline has seen the
# current conversion code and pandoc version.
if rebuild && Dir.exist?(NotesCommon::BASELINE_DIR)
  recorded = File.exist?(NotesCommon::FINGERPRINT_FILE) ? File.read(NotesCommon::FINGERPRINT_FILE) : nil
  if recorded != NotesCommon.conversion_fingerprint
    puts "The conversion has changed since the last notes baseline (code or pandoc)."
    print "Run notes baseline now? [Y/n] "
    answer = $stdin.gets&.strip&.downcase
    if answer && (answer.empty? || answer == "y")
      system(RbConfig.ruby, File.join(__dir__, "baseline.rb")) or exit 1
      abort "Check git -C ~/notes.baseline diff, then run notes export #{mode} again."
    end
  end
elsif rebuild
  puts "Tip: notes baseline shows what a code change does before files are rewritten."
end

root = File.expand_path(NotesCommon::NOTES_ROOT)
import = File.expand_path(NotesCommon::IMPORT_DIR)
abort "NOTES_IMPORT must be under #{root}" unless import.start_with?("#{root}/")
# Only md files with note_id and files in assets/ come from the export.
foreign = Dir.glob(File.join(import, "**", "*"), File::FNM_DOTMATCH).sort.reject do |f|
  File.directory?(f) ||
    File.basename(File.dirname(f)) == "assets" ||
    (f.end_with?(".md") && NotesCommon.frontmatter(File.read(f, encoding: "UTF-8"))["note_id"])
end
unless foreign.empty?
  abort "#{import} contains files that do not come from the export:\n" +
        foreign.map { |f| "  #{f.delete_prefix("#{root}/")}\n" }.join +
        "Empty or move the folder first."
end

# git is what lets an export be rolled back: ~/notes must be a repo, and
# uncommitted md files are asked about before anything is written. The first
# time it is created as one, without the cache.
unless Dir.exist?(root)
  FileUtils.mkdir_p root
  system("git", "init", "-q", root)
  File.write(File.join(root, ".gitignore"), "apple_notes.raw/\n")
  puts "Created ~/notes as a git repo."
end
_, git_ok = Open3.capture2e("git", "-C", root, "rev-parse", "--is-inside-work-tree")
abort "~/notes is not a git repo. Run git -C ~/notes init and commit before exporting." unless git_ok.success?
uncommitted, _ = Open3.capture2("git", "-C", root, "status", "--porcelain", "--", "*.md")
unless uncommitted.empty?
  puts "#{uncommitted.lines.size} md file(s) in ~/notes have uncommitted changes."
  print "Continue without a commit? [y/N] "
  abort "Commit ~/notes first, so the export can be rolled back." unless $stdin.gets&.strip&.downcase == "y"
end

unless ENV["NOTES_SKIP_DB_CHECK"] || !$stdin.tty?
  output, health_ok = Open3.capture2e(RbConfig.ruby, File.join(__dir__, "health.rb"))
  unless health_ok.success?
    puts output
    print "\nProblems found in ~/notes. Continue anyway? (y/n) "
    answer = $stdin.gets&.strip&.downcase
    exit 1 unless answer == "y"
  end
end

# The problems in ~/notes before anything is written. After an export that
# wrote files, only the problems that are new are shown, and they give exit 1.
health_list = -> { Open3.capture2(RbConfig.ruby, File.join(__dir__, "health.rb"), "--list").first.lines.map(&:chomp) }
health_before = health_list.call
health_after = lambda do
  new_problems = health_list.call - health_before
  return if new_problems.empty?
  puts "\nNew problems after the export (notes health):"
  new_problems.each { |p| puts "  #{p}" }
  exit 1
end

BASE_DIR = NotesCommon::IMPORT_DIR

safe_filename = NotesCommon.method(:safe_filename)

# --- Logging ---

def log(msg)
  puts msg
end

db = NotesCommon.open_db

# --assets: the attachment section of every md file as the export writes it
# now. Only the section changes; the text, the frontmatter (except a note_sum
# that matched) and the internal links stay. Counts first, then asks.
if options[:assets]
  texts = Dir.glob(File.join(NotesCommon::NOTES_ROOT, "**", "*.md")).sort.to_h { |f| [f, File.read(f, encoding: "UTF-8")] }
  asset_link = /\]\((assets\/[^)]+)\)/
  # How many md files link to each asset file.
  linked_by = Hash.new(0)
  texts.each { |f, text| text.scan(asset_link).flatten.uniq.each { |r| linked_by[File.expand_path(r, File.dirname(f))] += 1 } }

  counts = Hash.new(0)
  plans = []
  texts.each_with_index do |(f, text), idx|
    puts "[#{idx + 1}/#{texts.size}] checked" if (idx + 1) % 100 == 0
    note_id = NotesCommon.frontmatter(text)["note_id"]
    next unless note_id
    note_pk = db.get_first_value("SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE lower(ZIDENTIFIER) = ?", [note_id.downcase])
    next counts[:not_in_db] += 1 unless note_pk
    att = NotesCommon.attachment_section(db, note_pk)
    # An attachment not downloaded would drop out of the section.
    next counts[:not_downloaded] += 1 if att[:not_downloaded].any?
    next if att[:section].empty?
    new_text = NotesCommon.replace_attachment_section(text, att[:section])
    next if new_text == text
    # A note_sum that matched stays matching: the file is still unedited.
    sum = NotesCommon.frontmatter(text)["note_sum"]
    if sum && sum == NotesCommon.body_sum(text)
      new_text = new_text.sub(/^note_sum: .*$/, "note_sum: #{NotesCommon.body_sum(new_text)}")
    end

    dir = File.dirname(f)
    copies = att[:refs].map { |name, src| [src, File.join(dir, "assets", name)] }.reject { |_, dest| File.exist?(dest) }
    new_names = att[:refs].map { |name, _| "assets/#{name}" }
    old_section = text[NotesCommon::ATTACHMENT_SECTION].to_s
    outside = text.sub(old_section, "")
    deletes = []
    (old_section.scan(asset_link).flatten.uniq - new_names).each do |ref|
      old_path = File.join(dir, ref)
      next unless File.exist?(old_path)
      if outside.include?("](#{ref})")
        counts[:text_links] += 1
      elsif linked_by[File.expand_path(old_path)] <= 1 && att[:refs].any? { |_, src| File.binread(old_path) == NotesCommon.asset_data(src).b }
        deletes << old_path
      else
        counts[:kept] += 1
      end
    end
    counts[:files] += 1
    counts[:copied] += copies.size
    counts[:deleted] += deletes.size
    plans << [f, new_text, copies, deletes]
  end

  puts "#{counts[:files]} file(s) get a new attachment section."
  puts "#{counts[:copied]} attachment(s) copied to assets/."
  puts "#{counts[:deleted]} old attachment file(s) deleted: the same file under its new name."
  puts "#{counts[:kept]} old attachment file(s) kept: check by hand." if counts[:kept] > 0
  puts "#{counts[:text_links]} link(s) in the text point to old attachment names (not changed)." if counts[:text_links] > 0
  puts "#{counts[:not_downloaded]} file(s) skipped: an attachment is not downloaded from iCloud." if counts[:not_downloaded] > 0
  puts "#{counts[:not_in_db]} file(s) skipped: the note is not in Notes." if counts[:not_in_db] > 0
  exit 0 if plans.empty?
  $stdout.write "Continue? [y/N]: "
  $stdout.flush
  exit 0 unless $stdin.gets.to_s.strip.downcase == "y"

  plans.each do |f, new_text, copies, deletes|
    copies.each do |src, dest|
      FileUtils.mkdir_p File.dirname(dest)
      File.binwrite dest, NotesCommon.asset_data(src)
    end
    NotesCommon.write_atomic(f, new_text)
    deletes.each { |path| File.delete(path) }
  end
  puts "\nDone: #{plans.size} file(s) updated."
  puts "\nnext: check the changes with git diff, then stage and commit them yourself (git add, git commit)."
  health_after.call
  exit 0
end

# --- Export dir helper ---

export_dir_for = ->(folder_path) {
  parts = folder_path.split("/").map { |p| safe_filename.call(p) }
  File.join(BASE_DIR, *parts)
}

# Folder path ("Projects/Claude") per folder pk.
folder_paths = NotesCommon.folder_paths(db)

# Step 1 first; if you answer no, the conversion uses the cache as it is.
# Skipped in tests where the DB points to real Apple Notes while the cache is test-local.
NotesSync.sync(db, folder_paths) unless ENV["NOTES_SKIP_DB_CHECK"]

# Iterates over the cache files and looks up the existing md file via note_id.
# Without options only notes without an md file are taken. --marked and
# --failed take marked files and compare: identical = silent skip, different = overwrite.
scan_root = NotesCommon::NOTES_ROOT

# Build the note_id → md file lookup by scanning all md files once.
# The same scan also reads the export field.
md_by_uuid = {}
Dir.glob(File.join(scan_root, "**", "*.md")).sort.each do |f|
  text = File.read(f, encoding: "UTF-8")
  fm = NotesCommon.frontmatter(text)
  next unless fm["note_id"]
  md_by_uuid[fm["note_id"]] = { path: f, export: fm["export"], sum: fm["note_sum"],
                                untouched: fm["note_sum"] == NotesCommon.body_sum(text) }
end

# Iterate over the cache files. For each UUID: look up the md file. If there
# is no match, the candidate becomes a "new file" (path: nil), created in
# the transform loop below.
candidates = []
# Cache from before the note was deleted: no md for notes in "Recently Deleted".
trashed = Set.new(db.execute(
  "SELECT lower(n.ZIDENTIFIER) FROM ZICCLOUDSYNCINGOBJECT n JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER WHERE f.ZFOLDERTYPE = 1"
).flatten)

# Without options: offer to update the md files the export wrote whose body
# is still unchanged (note_sum matches).
update_untouched = false
if options[:export]
  untouched = md_by_uuid.count do |uuid, md|
    md[:untouched] && !trashed.include?(uuid) && File.exist?(File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.html"))
  end
  if untouched > 0
    print "Also update #{untouched} notes you have not changed yourself? [y/N] "
    update_untouched = $stdin.gets&.strip&.downcase == "y"
  end
end

Dir.glob(File.join(NotesCommon::RAW_CACHE_DIR, "*.html")).sort.each do |cache_path|
  uuid = File.basename(cache_path, ".html")
  next if trashed.include?(uuid)
  md = md_by_uuid[uuid]

  if md
    next if options[:export] && !(update_untouched && md[:untouched])
    next if options[:marked] && md[:export] != "true"
    next if options[:failed] && md[:export] != "fail"
    candidates << { path: md[:path], note_id: uuid }
  else
    # New file — no md yet. --marked and --failed only work on
    # existing md files.
    next unless options[:export]
    candidates << { path: nil, note_id: uuid }
  end
end

if candidates.empty?
  puts({ export: "No new notes", marked: "No files with export: true",
         failed: "No files with export: fail" }
         .find { |k, _| options[k] }[1])
  exit 0
end

# Check that the candidates have a complete cache (html + txt). If you
# answered no to the sync, a partial cache can remain; then notes sync must run.
uncached = candidates.reject { |c| cache_complete.call(c[:note_id]) }
unless uncached.empty?
  warn "WARNING: #{uncached.size} of #{candidates.size} candidates are missing a complete cache:"
  uncached.first(20).each { |c| warn "  #{c[:note_id]}" }
  warn "  ..." if uncached.size > 20
  exit 1
end

if options[:marked]
  puts ""
  puts "#{candidates.size} file(s) with export: true."
end

puts ""
if update_untouched
  new_notes = candidates.count { |c| c[:path].nil? }
  puts "Creating md files for #{new_notes} new notes and updating #{candidates.size - new_notes} notes you have not changed yourself."
elsif options[:export]
  puts "Creating md files for #{candidates.size} notes without an md file. Existing files are not touched."
else
  puts "WARNING: all changed files will be overwritten."
end
# y to "Also update" is the confirmation; no second question.
unless update_untouched
  $stdout.write "Continue? [y/N]: "
  $stdout.flush
  ans = $stdin.gets
  unless ans && ans.strip.downcase == "y"
    log "Aborted."
    exit 0
  end
end

log "Comparing #{candidates.size} notes with the cache"
identical_count = 0
overwritten_count = 0
new_count = 0
large_changes = []
LARGE_CHANGE_THRESHOLD = 5

interrupted = false
Signal.trap("INT") { interrupted = true }

# Files whose body no longer matches the note_sum the export wrote.
edited_by_hand = []

candidates.each_with_index do |item, idx|
  if interrupted
    log "\nInterrupted after #{idx} of #{candidates.size}."
    exit 130
  end
  if idx > 0 && idx % 100 == 0
    counts = "#{identical_count} identical, #{overwritten_count} overwritten"
    log "[#{idx}/#{candidates.size}] checked (#{counts})"
  end
  md_path = item[:path]
  note_id = item[:note_id]
  is_new = md_path.nil?
  log_pos = "[#{idx + 1}/#{candidates.size}]"

  unless is_new
    sum = NotesCommon.frontmatter(File.read(md_path))["note_sum"]
    if sum && sum != NotesCommon.body_sum(File.read(md_path))
      edited_by_hand << md_path.sub("#{scan_root}/", '')
      next
    end
  end

  cache_path = File.join(NotesCommon::RAW_CACHE_DIR, "#{note_id}.html")
  raw_body = File.read(cache_path)

  row = db.get_first_row(
    "SELECT Z_PK, ZTITLE1, ZCREATIONDATE3, ZMODIFICATIONDATE1, ZFOLDER FROM ZICCLOUDSYNCINGOBJECT WHERE lower(ZIDENTIFIER) = ?",
    [note_id.downcase]
  )
  unless row
    log "#{log_pos} SKIPPING (not in DB): #{is_new ? note_id : File.basename(md_path)}"
    next
  end
  note_pk, title, cd_created, _cd_modified, folder_pk = row
  created_date  = NotesCommon.core_data_to_local_date(cd_created)

  if is_new
    fp = folder_paths[folder_pk]
    unless fp
      log "#{log_pos} SKIPPING (folder not found in DB): #{note_id}"
      next
    end
    export_dir_new = export_dir_for.call(fp)
    FileUtils.mkdir_p export_dir_new
    base = NotesCommon.note_basename(title, created_date)
    candidate = base + ".md"
    n = 2
    while File.exist?(File.join(export_dir_new, candidate))
      candidate = "#{base} #{n}.md"
      n += 1
    end
    md_path = File.join(export_dir_new, candidate)
  end

  # Attachments are copied to assets/ next to the md file when they are not
  # there yet; the check then sees the file in place.
  export_dir = File.dirname(md_path)
  assets_dir = File.join(export_dir, "assets")
  existing_text = is_new ? "" : File.read(md_path)
  repaired_assets = 0
  copy_asset = ->(safe_name, src) {
    dest = File.join(assets_dir, safe_name)
    unless File.exist?(dest)
      FileUtils.mkdir_p assets_dir
      if File.extname(src).downcase == ".html"
        File.write dest, NotesCommon.asset_data(src)
      else
        FileUtils.cp src, dest
      end
      repaired_assets += 1
    end
    File.exist?(dest)
  }
  built = NotesCommon.build_md(db, note_id, raw_body, note_pk: note_pk, created_date: created_date,
                               ref_ok: copy_asset, existing_text: existing_text)
  if built[:error]
    log "#{log_pos} ERROR pandoc for '#{title}': #{built[:error]}"
    next
  end
  built[:not_downloaded].each { |media_uuid| log "#{log_pos} ATTACHMENT NOT DOWNLOADED: #{md_path.sub("#{scan_root}/", '')} (#{media_uuid})" }
  built[:box_problems].each { |p| log "#{log_pos} CHECKBOX #{md_path.sub("#{scan_root}/", '')}: #{p}" }
  new_text = built[:text]
  result = built[:result]

  if repaired_assets > 0
    puts "#{log_pos} Repaired #{repaired_assets} asset#{repaired_assets == 1 ? '' : 's'}: #{md_path.sub("#{scan_root}/", '')}"
  end

  case NotesCommon.refresh_compare(existing_text, new_text)
  when :identical
    identical_count += 1
    next
  when :differ
    new_refs = new_text.scan(/\]\(assets\/([^)]+)\)/).flatten
    missing = new_refs.reject { |r| File.exist?(File.join(assets_dir, r)) }
    unless missing.empty?
      warn ""
      warn "FATAL: re-export would have written broken refs to #{md_path}"
      warn "  new text points to #{missing.size} file#{missing.size == 1 ? '' : 's'} that do not exist on disk:"
      missing.each { |r| warn "    assets/#{r}" }
      warn ""
      warn "  DEBUG:"
      warn "    note_id:        #{note_id}"
      warn "    assets_dir:     #{assets_dir}"
      warn "    existing refs:  #{existing_text.scan(/\]\(assets\/([^)]+)\)/).flatten.inspect}"
      warn "    new refs:       #{new_refs.inspect}"
      warn "    assets on disk: #{Dir.glob(File.join(assets_dir, '*')).map { |p| File.basename(p) }.sort.inspect}"
      warn ""
      warn "The original is NOT overwritten. Aborting to protect data."
      exit 1
    end

    unless is_new
      # Blank lines do not count.
      old_tally = existing_text.lines.reject { |l| l.strip.empty? }.tally
      new_tally = new_text.lines.reject { |l| l.strip.empty? }.tally
      added = 0
      removed = 0
      (old_tally.keys | new_tally.keys).each do |k|
        diff = (new_tally[k] || 0) - (old_tally[k] || 0)
        if diff > 0
          added += diff
        elsif diff < 0
          removed += -diff
        end
      end
      if (added + removed) >= LARGE_CHANGE_THRESHOLD
        warn "#{log_pos} LARGE CHANGE: #{md_path.sub("#{scan_root}/", '')} (+#{added}/-#{removed})"
        large_changes << { path: md_path.sub("#{scan_root}/", ''), added: added, removed: removed }
      end
    end

    NotesCommon.write_atomic(md_path, new_text)
    result[:missing_urls].each { |url| log "#{log_pos} MISSING URL: #{url}" }
    result[:broken_refs].each  { |ref| log "#{log_pos} MISSING FILE: #{ref}" }
    if is_new
      new_count += 1
    else
      overwritten_count += 1
    end
  end
end

log "\nDone: #{identical_count} identical, #{overwritten_count} overwritten, #{new_count} new"
if edited_by_hand.any?
  puts "\n#{edited_by_hand.size} file(s) edited by hand since the export, not rebuilt."
end
if large_changes.any?
  warn ""
  warn "#{large_changes.size} file(s) had large changes (use git diff to check that nothing was lost)."
end
if overwritten_count + new_count > 0
  puts "\nnext: check the changes with git diff, then stage and commit them yourself (git add, git commit)."
  health_after.call
end
exit 0

rescue Interrupt
  warn "\nAborted."
  exit 130
end
