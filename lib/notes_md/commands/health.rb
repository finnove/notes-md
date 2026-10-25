#!/usr/bin/env ruby
require 'optparse'
require 'set'
require 'fileutils'
require_relative '../common'

TEST_FILE = "test/health_test.rb"

Encoding.default_external = "UTF-8"

options = { search_dir: NotesCommon::NOTES_ROOT }
parser = OptionParser.new do |opts|
  opts.banner = <<~BANNER
    Usage: notes health [options]

    Catches broken picture links, stray attachments and duplicate notes in ~/notes
    early. Without it, a missing attachment is only discovered when you need it.

    Without a category, every report runs, plus checks for duplicate
    note_id and hidden md files.

    Options:
  BANNER
  opts.on("--multi", "Report assets referenced by more than one file") { options[:multi] = true }
  opts.on("--orphans", "List assets not referenced by any markdown file") { options[:orphans] = true }
  opts.on("--broken", "List markdown files referring to assets that do not exist on disk") { options[:broken] = true }
  opts.separator "                                     With --orphans or --broken: an orphan with the same filename as"
  opts.separator "                                     a broken reference is offered moved into place, Y/n for each"
  opts.on("--created", "List markdown files missing created_at in the frontmatter") { options[:created] = true }
  opts.on("--rm", "With --orphans: delete orphaned assets") { options[:rm] = true }
  opts.on("--silent", "No output, only the exit code (0 = healthy, 1 = problem)") { options[:silent] = true }
  opts.on("-v", "--verbose", "Show all sections, including green ones (hidden by default)") { options[:verbose] = true }
  opts.on("-s", "--search-dir DIR", "Root folder to search") { |d| options[:search_dir] = File.expand_path(d) }
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  notes health"
  opts.separator "  notes health --broken"
  opts.separator "  notes health --orphans --rm"
  opts.separator "  notes health -s ~/notes/archive"
end
parser.parse!

categories = %i[multi orphans broken created].select { |k| options[k] }
options[:all] = true if categories.empty?
if options[:rm] && (options[:all] || categories != [:orphans])
  puts parser
  exit 1
end

if options[:all]
  options[:multi] = true
  options[:orphans] = true
  options[:broken] = true
  options[:created] = true
end

RED = "\e[31m"
GRN = "\e[32m"
CYN = "\e[36m"
YLW = "\e[33m"
MAG = "\e[35m"
BLD = "\e[1m"
DIM = "\e[2m"
RST = "\e[0m"

def section(title)
  puts ""
  puts "#{BLD}#{MAG}━━ #{title} ━━#{RST}"
  puts ""
end

def status_line(label, count)
  marker = count == 0 ? "#{GRN}✓#{RST}" : "#{YLW}•#{RST}"
  color = count == 0 ? GRN : YLW
  puts "  #{marker} #{label}: #{color}#{BLD}#{count}#{RST}"
end

search_dir = options[:search_dir]

all_md = Dir.glob(File.join(search_dir, "**", "*.md"))

ASSET_RE = /\]\(((?:[^)\s:]*\/)?assets\/[^)]+)\)/

# Asks Y/n; nil on EOF
def yes?(question)
  print "#{question} [Y/n] "
  answer = $stdin.gets
  return nil if answer.nil?
  answer.strip.empty? || answer.strip.downcase == "y"
end

# One broken reference and one orphaned asset with the same filename — move the asset to the md file's assets/, Y/n
def remap(all_md, search_dir)
  broken_refs = []
  all_md.each do |f|
    File.read(f, encoding: "UTF-8").scan(ASSET_RE).flatten.each do |rel|
      broken_refs << [f, rel] unless File.exist?(File.expand_path(rel, File.dirname(f)))
    end
  end

  referenced = Set.new
  all_md.each do |f|
    File.read(f, encoding: "UTF-8").scan(ASSET_RE).flatten.each do |rel|
      referenced << File.expand_path(rel, File.dirname(f)).unicode_normalize(:nfc)
    end
  end
  orphans_by_name = Hash.new { |h, k| h[k] = [] }
  Dir.glob(File.join(search_dir, "**", "assets", "*")).each do |a|
    next unless File.file?(a)
    next if referenced.include?(a.unicode_normalize(:nfc))
    orphans_by_name[File.basename(a).unicode_normalize(:nfc)] << a
  end
  broken_by_name = broken_refs.uniq.group_by { |_, rel| File.basename(rel).unicode_normalize(:nfc) }

  broken_by_name.sort.each do |name, refs|
    next unless refs.size == 1 && orphans_by_name[name].size == 1
    f, rel = refs.first
    src = orphans_by_name[name].first
    dst = File.expand_path(rel, File.dirname(f))
    puts "  reference found in: #{CYN}#{f}#{RST}"
    unless File.directory?(File.dirname(dst))
      puts "  #{YLW}asset folder missing: #{File.dirname(dst)}#{RST}"
      next
    end
    answer = yes?("  move #{src} → #{GRN}#{dst}#{RST}")
    break if answer.nil?
    FileUtils.mv(src, dst) if answer
  end
rescue Interrupt
  puts ""
  exit 1
end

# Index: absolute asset path → Set of md files referring to it
asset_refs = Hash.new { |h, k| h[k] = Set.new }

all_md.each do |f|
  begin
    text = File.read(f, encoding: "UTF-8")
    text.scan(ASSET_RE).flatten.each do |rel|
      abs = File.expand_path(rel, File.dirname(f)).unicode_normalize(:nfc)
      asset_refs[abs] << f
    end
  rescue
  end
end

multi = asset_refs.select { |_, refs| refs.size > 1 }.sort_by { |a, _| a }

all_assets = []
orphan_assets = []
broken = Hash.new { |h, k| h[k] = [] }
if options[:orphans] || options[:broken]
  all_assets = Dir.glob(File.join(search_dir, "**", "assets", "*")).select { |f| File.file?(f) }
  orphan_assets = all_assets.reject { |a| asset_refs.key?(a.unicode_normalize(:nfc)) }.sort
  asset_refs.each do |abs, files|
    next if File.exist?(abs)
    files.each { |f| broken[f] << abs }
  end
end

# Same filename across --orphans and --broken
orphans_by_name = orphan_assets.group_by { |a| File.basename(a).unicode_normalize(:nfc) }
broken_by_name = Hash.new { |h, k| h[k] = [] }
broken.each { |f, assets| assets.each { |a| broken_by_name[File.basename(a)] << f } }

if options[:rm]
  if broken.any?
    warn "Broken references exist — run notes health --broken first"
    exit 1
  end
  orphan_assets.each { |a| File.delete(a) }
end

missing_ca = []
if options[:created]
  all_md.each do |f|
    missing_ca << f unless NotesCommon.frontmatter(File.read(f, encoding: "UTF-8")).key?("created_at")
  end
  missing_ca.sort!
end

dup_note_ids = 0
if options[:all]
  uuid_to_files = Hash.new { |h, k| h[k] = [] }
  all_md.each do |f|
    uuid = NotesCommon.frontmatter(File.read(f, encoding: "UTF-8"))["note_id"]
    uuid_to_files[uuid] << f if uuid
  end
  dup_note_ids = uuid_to_files.count { |_, fs| fs.size >= 2 }
end

# Hidden md files (name or folder starts with .) are not seen by Dir.glob
# above, and should not exist in ~/notes.
hidden_md = []
if options[:all]
  hidden_md = (Dir.glob(File.join(search_dir, "**", "*.md"), File::FNM_DOTMATCH) - all_md).sort
end

problems = 0
problems += multi.size if options[:multi]
problems += orphan_assets.size if options[:orphans]
problems += broken.size if options[:broken]
problems += missing_ca.size if options[:created]
problems += dup_note_ids if options[:all]
problems += hidden_md.size if options[:all]

unless options[:silent]
  show = ->(count) { count > 0 || options[:verbose] }

  if options[:all]
    rows = [
      ["--multi", multi.size],
      ["--orphans", orphan_assets.size],
      ["--broken", broken.size],
      ["--created", missing_ca.size],
      ["Duplicate note_id", dup_note_ids],
      ["Hidden md files", hidden_md.size],
    ].select { |_, count| show.call(count) }

    if rows.any?
      section "Notes health"
      puts "  #{DIM}#{all_md.size} files scanned, #{asset_refs.size} unique assets#{RST}"
      puts ""
      rows.each { |label, count| status_line label, count }
      hidden_md.each { |f| puts "    #{RED}#{f}#{RST}" }
    end
  else
    if options[:multi] && show.call(multi.size)
      section "Multi-referenced assets"
      puts "  #{DIM}#{all_md.size} files scanned, #{asset_refs.size} unique assets#{RST}"
      status_line "Referenced by more than one file", multi.size
      puts ""

      multi.each do |asset, refs|
        puts "  #{YLW}#{asset}#{RST}"
        refs.to_a.sort.each { |f| puts "    #{CYN}#{f}#{RST}" }
        puts ""
      end

      dir_counts = Hash.new(0)
      multi.each do |asset, _|
        parts = File.dirname(asset).split("/")
        (1...parts.size).each do |i|
          dir_counts[parts[0..i].join("/")] += 1
        end
      end

      if dir_counts.any?
        puts "  #{BLD}Statistics per folder:#{RST}"
        dir_counts.sort_by { |d, _| d }.each do |dir, count|
          puts "    #{DIM}#{dir}#{RST}  #{YLW}#{count}#{RST}"
        end
      end
    end

    if options[:orphans] && show.call(orphan_assets.size)
      section "Orphaned assets"
      status_line "Without reference (of #{all_assets.size} total)", orphan_assets.size
      puts ""
      orphan_assets.each do |a|
        puts "  #{RED}#{a}#{RST}"
        broken_by_name[File.basename(a).unicode_normalize(:nfc)].sort.each { |f| puts "    #{DIM}--broken:#{RST} #{CYN}#{f}#{RST}" }
      end
      puts "" if orphan_assets.any?
    end

    if options[:broken] && show.call(broken.size)
      section "Broken asset references"
      status_line "Files referring to missing assets", broken.size
      puts ""
      broken.sort_by { |f, _| f }.each do |f, assets|
        puts "  #{CYN}#{f}#{RST}"
        assets.sort.each do |a|
          puts "    #{RED}missing: #{a}#{RST}"
          orphans_by_name.fetch(File.basename(a), []).each { |o| puts "      #{DIM}--orphans:#{RST} #{YLW}#{o}#{RST}" }
        end
        puts ""
      end
    end

    if options[:created] && show.call(missing_ca.size)
      section "Missing created_at"
      status_line "Files without created_at in frontmatter", missing_ca.size
      puts ""
      missing_ca.each { |f| puts "  #{RED}#{f}#{RST}" }
      puts "" if missing_ca.any?
    end
  end
end


if (options[:orphans] || options[:broken]) && !options[:rm] && !options[:all] && !options[:silent]
  remap(all_md, search_dir)
end

exit(problems > 0 ? 1 : 0)
