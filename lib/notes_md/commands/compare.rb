#!/usr/bin/env ruby
require 'optparse'
require 'set'
require 'sqlite3'
require_relative '../common'

TEST_FILE = "test/compare_test.rb"

options = { search_dir: NotesCommon::NOTES_ROOT }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: notes compare [options] [folder name]\n\n" \
                "Tells you, folder by folder, whether every note in Notes has an md file.\n" \
                "Without it, a note that was never exported can go unnoticed.\n\n" \
                "A folder name limits the comparison to that folder in Notes.\n\n" \
                "Options:"
  opts.on("-s", "--search-dir DIR", "Root folder to search recursively for .md files") { |d| options[:search_dir] = File.expand_path(d) }
  opts.on("-v", "--verbose", "List the note IDs in each category of differences") { options[:verbose] = true }
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  notes compare"
  opts.separator "  notes compare journal/2022"
  opts.separator "  notes compare -s ~/notes/archive journal/2022"
end
parser.parse!

SEARCH_DIR = options[:search_dir]
folder_name = ARGV[0]

# --- SQLite: build folder hierarchy and note→folder mapping ---

db = NotesCommon.open_db

# "Recently Deleted" is not in the folder tree, so notes there are neither
# shown nor counted.
folder_path_cache = NotesCommon.folder_paths(db)

notes_count_per_path = Hash.new(0)
notes_uuids_per_path = Hash.new { |h, k| h[k] = Set.new }
uuid_to_notes_path = {}
all_paths = Set.new

folder_path_cache.each_value { |p| all_paths << p.downcase if p }

NotesCommon.active_notes(db).each do |note|
  fp = folder_path_cache[note.folder]
  next unless fp
  fpd = fp.downcase
  notes_count_per_path[fpd] += 1
  notes_uuids_per_path[fpd] << note.uuid
  uuid_to_notes_path[note.uuid] = fpd
end

# Filter on folder_name (case-insensitive)
filter = folder_name&.downcase
match_filter = ->(fp) {
  return true unless filter
  fpd = fp.downcase
  fpd == filter || fpd.start_with?("#{filter}/")
}

filtered_paths = all_paths.select(&match_filter).sort

if filtered_paths.empty?
  puts "No folders found"
  exit 0
end

# --- Disk scan: collect UUIDs per Notes folder and fail status ---
# An md file is counted in the folder its note is in in Notes, wherever it
# is on disk. md files without a note in Notes are orphaned.

disk_uuids_per_path = Hash.new { |h, k| h[k] = Set.new }
fail_counts = Hash.new(0)
orphaned_uuids = []
all_md_uuids = Set.new

Dir.glob(File.join(SEARCH_DIR, "**", "*.md")).each do |f|
  fm = NotesCommon.frontmatter(File.read(f, encoding: "UTF-8"))
  uuid = fm["note_id"]
  next unless uuid
  all_md_uuids << uuid
  fpd = uuid_to_notes_path[uuid]
  if fpd.nil?
    orphaned_uuids << uuid
    next
  end
  next unless match_filter.call(fpd)

  disk_uuids_per_path[fpd] << uuid
  fail_counts[fpd] += 1 if fm["export"] == "fail"
end

# --- Format table ---

rows = []

filtered_paths.each do |path|
  nc = notes_count_per_path[path]
  ec = disk_uuids_per_path[path].size
  fc = fail_counts[path]
  ms = (notes_uuids_per_path[path] - disk_uuids_per_path[path]).size
  depth = folder_name ? path.split("/").size - folder_name.split("/").size : path.split("/").size - 1
  indent = "  " * depth
  label = indent + path.split("/").last
  rows << [label, nc, ec, ms, fc]
end

max_notes = rows.map { |r| r[1] }.max || 0
max_export = rows.map { |r| r[2] }.max || 0
name_width = [(rows.map { |r| r[0].length }.max || 6), 6].max
notes_width = [max_notes.to_s.length, 5].max
export_width = [max_export.to_s.length, 6].max

header = "%-#{name_width}s  %#{notes_width}s  %#{export_width}s  %s" % ["Folder", "Notes", "Export", "Status"]
puts header
puts "-" * header.length

format_status = ->(ms, fc) {
  if ms == 0 && fc == 0
    "✅"
  else
    reasons = []
    reasons << "#{ms} missing" if ms > 0
    reasons << "#{fc} fail" if fc > 0
    "⚠️  #{reasons.join(', ')}"
  end
}

rows.each do |label, nc, ec, ms, fc|
  puts "%-#{name_width}s  %#{notes_width}d  %#{export_width}d  %s" % [label, nc, ec, format_status.call(ms, fc)]
end
puts "-" * header.length
total_nc  = rows.sum { |r| r[1] }
total_ec  = rows.sum { |r| r[2] }
total_ms  = rows.sum { |r| r[3] }
total_fc  = rows.sum { |r| r[4] }
puts "%-#{name_width}s  %#{notes_width}d  %#{export_width}d  %s" % ["Total", total_nc, total_ec, format_status.call(total_ms, total_fc)]
puts "-" * header.length

# --- Disk checks: delegated to notes health (0 = healthy, 1 = problem) ---

system(RbConfig.ruby, File.join(__dir__, "health.rb"), "-s", SEARCH_DIR, "--silent")
health_problems = $?.exitstatus

checks = [
  ["Disk health check",                    health_problems,      "notes health"],
  ["md files without a note in Notes",     orphaned_uuids.size,  "notes compare -v"],
]

puts ""
checks.each do |label, count, cmd|
  status = count == 0 ? "✅" : "⚠️"
  puts "%-40s %s  (%s)" % [label, status, cmd]
end

# --- Cache-status ---

cached_uuids = []
missing_cache_uuids = []
all_md_uuids.each do |uuid|
  has_html = File.exist?(File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.html"))
  has_txt  = File.exist?(File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.txt"))
  if has_html && has_txt
    cached_uuids << uuid
  else
    missing_cache_uuids << uuid
  end
end

cache_status = missing_cache_uuids.empty? ? "✅" : "⚠️"
puts "%-40s %s  (%s)" % ["Local copy", cache_status, "notes sync"]

if options[:verbose]
  filtered_paths.each do |path|
    missing = (notes_uuids_per_path[path] - disk_uuids_per_path[path]).to_a.sort
    next if missing.empty?

    puts ""
    puts "## #{path}"
    puts "  missing (#{missing.size}):"
    missing.each { |u| puts "    #{u}" }
  end

  unless orphaned_uuids.empty?
    puts ""
    puts "## Orphaned (#{orphaned_uuids.size})"
    orphaned_uuids.sort.each { |u| puts "    #{u}" }
  end

  unless missing_cache_uuids.empty?
    puts ""
    puts "## Missing from local copy (#{missing_cache_uuids.size})"
    missing_cache_uuids.sort.each { |u| puts "    #{u}" }
  end
end
