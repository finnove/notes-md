#!/usr/bin/env ruby
# Creates the config file the first time, with every setting commented out,
# and shows the settings that apply and where each comes from.
require 'fileutils'
require 'optparse'
require_relative '../common'

TEST_FILE = "test/config_test.rb"

OptionParser.new do |opts|
  opts.banner = "Usage: notes config\n\n" \
                "Shows the settings notes-md uses, and where each comes from: the default, the config\n" \
                "file or an environment variable. Without it, you would have to read the code to know.\n\n" \
                "The first time, it creates the config file (#{NotesSettings::CONFIG_FILE})\n" \
                "with every setting, what it does and its default, all commented out. Remove the # in\n" \
                "front of a line to change it. An environment variable changes a setting for one run.\n" \
                "An existing file is never changed.\n\n" \
                "Options:"
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  notes config"
  opts.separator "  NOTES_LANG=nb notes config"
end.parse!

unless File.exist?(NotesSettings::CONFIG_FILE)
  FileUtils.mkdir_p File.dirname(NotesSettings::CONFIG_FILE)
  File.write(NotesSettings::CONFIG_FILE, NotesSettings.template)
  puts "Created #{NotesSettings::CONFIG_FILE}"
  puts ""
end

values = {
  "root" => NotesCommon::NOTES_ROOT, "raw_cache" => NotesCommon::RAW_CACHE_DIR, "import" => NotesCommon::IMPORT_DIR,
  "baseline" => NotesCommon::BASELINE_DIR, "db" => NotesCommon::DB_PATH,
  "lang" => NotesSettings.value("lang"), "bold_line_as_heading" => NotesSettings.value("bold_line_as_heading"),
}
# Paths in the home folder as ~/…, as they are written in the file.
shown = values.transform_values { |v| v.to_s.sub(/\A#{Regexp.escape(Dir.home)}(?=\/|\z)/, "~") }
width = shown.keys.map(&:size).max
value_width = shown.values.map(&:size).max
shown.each { |key, value| puts "#{key.ljust(width)}  #{value.ljust(value_width)}  #{NotesSettings.source(key)}" }
