# The tests run with the defaults, whatever the user has set: no config file
# and none of the settings from the environment. Loaded before the code, which
# reads the settings when it is loaded, and inherited by every command a test
# runs; a test that needs a setting passes it itself.
ENV["NOTES_CONFIG"] = File::NULL
%w[NOTES_ROOT NOTES_RAW_CACHE NOTES_IMPORT NOTES_BASELINE NOTES_DB NOTES_LANG
   NOTES_BOLD_LINE_AS_HEADING NOTES_LIMIT_FOLDER].each { |name| ENV.delete(name) }
