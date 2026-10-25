#!/usr/bin/env ruby
# Cleans up Apple Notes to match the md files, which are the source of truth:
# goes through notes without an md file, one at a time, shows the raw html
# from the cache and offers to delete the note. Without this the next
# `notes export` would recreate the md file. Deletion goes through
# AppleScript, so the note ends up in "Recently Deleted" and syncs to iCloud.
# The cache for the note is removed as well.
require 'fileutils'
require 'json'
require 'nokogiri'
require 'open3'
require 'optparse'
require 'set'
require 'sqlite3'

TEST_FILE = "test/prune_test.rb"
require_relative '../common'

options = { empty: false }
OptionParser.new do |opts|
  opts.banner = "Usage: notes prune [--empty]\n\n" \
                "Deletes the notes in Notes that you have deleted from ~/notes. Without it, every\n" \
                "note you remove from the archive comes back on the next export.\n\n" \
                "Shows the notes that have no md file under ~/notes, one at a time, with the\n" \
                "html from the local copy. Answer y to delete the note in Notes (it goes to\n" \
                "\"Recently Deleted\") and in the local copy, so the next notes export does not\n" \
                "recreate the md file. n/Enter moves on, q stops.\n\n" \
                "Options:"
  opts.on("--empty", "Delete all obviously empty notes (no text beyond the title, no attachments):",
                     "first asks to delete them from the local copy, then in Notes") { options[:empty] = true }
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  notes prune"
  opts.separator "  notes prune --empty"
end.parse!

begin
  db = NotesCommon.open_db
  store_uuid = db.get_first_value("SELECT Z_UUID FROM Z_METADATA LIMIT 1")

  existing = Set.new
  Dir.glob(File.join(NotesCommon::NOTES_ROOT, "**", "*.md")).each do |f|
    uuid = NotesCommon.frontmatter(File.read(f, encoding: "UTF-8"))["note_id"]
    existing << uuid if uuid
  end

  folder_paths = NotesCommon.folder_paths(db)

  missing = NotesCommon.active_notes(db)
    .reject { |n| existing.include?(n.uuid) }
    .map { |n| [n.pk, n.uuid, n.title, folder_paths[n.folder].to_s.downcase, n.created] }
    .sort_by { |_, _, title, path| [path, title] }

  delete_in_notes = ->(pk) {
    id = "x-coredata://#{store_uuid}/ICNote/p#{pk}"
    _, err, status = Open3.capture3("osascript", "-l", "JavaScript", "-e", "Application('Notes').notes.byId(#{id.to_json}).delete()")
    puts "Could not delete: #{err.strip}" unless status.success?
    status.success?
  }
  delete_cache = ->(uuid) {
    FileUtils.rm_f(%w[html txt].map { |ext| File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.#{ext}") })
  }

  if options[:empty]
    norm = ->(t) { t.unicode_normalize(:nfc).gsub(/[[:space:]]+/, " ").strip }
    with_attachments = Set.new(db.execute("SELECT DISTINCT ZNOTE FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = 5 AND ZNOTE IS NOT NULL").flatten)
    empty = missing.select { |pk, uuid, title|
      html = File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.html")
      next false if with_attachments.include?(pk) || !File.exist?(html)
      doc = Nokogiri::HTML.fragment(File.read(html, encoding: "UTF-8"))
      doc.css("img, object").empty? && norm.(doc.text).delete_prefix(norm.(title)).strip.empty?
    }
    exit if empty.empty?
    empty.each { |_, _, title, path, created| puts "#{title}  #{path}  #{NotesCommon.core_data_to_local_date(created)}" }
    # The cache first, so the diff in ~/notes can be checked before the notes are deleted.
    print "\nDelete cache for #{empty.size} empty notes? [y/N] "
    exit unless $stdin.gets&.strip&.downcase == "y"
    empty.each { |_, uuid| delete_cache.(uuid) }
    print "Delete the #{empty.size} notes in Notes? [y/N] "
    exit unless $stdin.gets&.strip&.downcase == "y"
    empty.each { |pk, *| delete_in_notes.(pk) }
    exit
  end

  missing.each.with_index(1) do |(pk, uuid, title, path, created), i|
    puts "\n[#{i}/#{missing.size}] #{title}"
    puts "#{path}  #{NotesCommon.core_data_to_local_date(created)}  #{uuid}"
    puts ""
    html = File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.html")
    if File.exist?(html)
      puts File.read(html, encoding: "UTF-8")
    else
      puts "(no cache)"
    end
    print "\nDelete the note in Notes? [y/N/q] "
    answer = $stdin.gets&.strip&.downcase
    if answer.nil?
      puts ""
      break
    end
    break if answer == "q"
    delete_cache.(uuid) if answer == "y" && delete_in_notes.(pk)
  end
rescue Interrupt
  puts ""
  exit 130
end
