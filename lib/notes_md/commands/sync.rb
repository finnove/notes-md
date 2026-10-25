#!/usr/bin/env ruby
require 'optparse'
require_relative '../sync'

TEST_FILE = "test/sync_test.rb"

OptionParser.new do |opts|
  opts.banner = "Usage: notes sync\n\n" \
                "Keeps a local copy of every note, so exports run offline and Notes is only asked\n" \
                "for what changed. Without it, every export would fetch all notes from Notes again.\n\n" \
                "Shows the differences between Notes and the local copy and syncs after\n" \
                "confirmation: fetches missing, partial and changed notes, and deletes the\n" \
                "local copy of notes in \"Recently Deleted\" or gone from Notes. Locked notes\n" \
                "must be unlocked in Notes first. Answer v to see the content of the notes\n" \
                "being removed from the local copy.\n\n" \
                "Options:"
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  notes sync"
  opts.separator "  NOTES_LIMIT_FOLDER=journal notes sync"
  opts.separator ""
  opts.separator "Environment variables:"
  opts.separator "  NOTES_LIMIT_FOLDER  sync only this folder in Notes"
end.parse!

begin
  db = NotesCommon.open_db
  NotesSync.sync(db, NotesCommon.folder_paths(db))
rescue Interrupt
  warn "\nAborted."
  exit 130
end
