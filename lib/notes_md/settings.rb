require 'yaml'

# The settings of notes-md. Each has a default; the config file
# (~/.config/notes-md/config.yml) changes it, and the environment variable
# changes it for one run. notes config creates the file and shows them.
module NotesSettings
  module_function

  # key => [environment variable, the default as shown, what it does]
  SETTINGS = {
    "root"                 => ["NOTES_ROOT", "~/notes", "The archive with your md files."],
    "raw_cache"            => ["NOTES_RAW_CACHE", "~/notes/apple_notes.raw", "The local copy of the notes that notes sync keeps. Default: apple_notes.raw in root."],
    "import"               => ["NOTES_IMPORT", "~/notes/import", "Where notes export puts new md files; must be in root. Default: import in root."],
    "baseline"             => ["NOTES_BASELINE", "~/notes.baseline", "The folder notes baseline builds every note into."],
    "db"                   => ["NOTES_DB", "~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite", "The database of Apple Notes."],
    "lang"                 => ["NOTES_LANG", "en", "Language of the section headings in the md files: en or nb."],
    "bold_line_as_heading" => ["NOTES_BOLD_LINE_AS_HEADING", false, "With true, a line that is only bold text in Notes becomes a ## heading."],
  }

  CONFIG_FILE = ENV["NOTES_CONFIG"] ||
                File.join(ENV["XDG_CONFIG_HOME"] || File.expand_path("~/.config"), "notes-md", "config.yml")

  FILE_VALUES = File.file?(CONFIG_FILE) ? (YAML.safe_load(File.read(CONFIG_FILE)) || {}) : {}
  unknown = FILE_VALUES.keys - SETTINGS.keys
  abort "#{CONFIG_FILE}: unknown setting #{unknown.first} (known: #{SETTINGS.keys.join(", ")})" if unknown.any?

  # The value set for key, from the environment or the file; nil when only the
  # default applies. bold_line_as_heading is true or false.
  def get(key)
    env = ENV[SETTINGS.fetch(key)[0]]
    value = env || FILE_VALUES[key]
    return value if value.nil?
    return [true, "1", "true"].include?(value) if key == "bold_line_as_heading"
    value.to_s
  end

  # The value of key: the one set, or the default.
  def value(key) = get(key).nil? ? SETTINGS.fetch(key)[1] : get(key)

  # The value of key as a full path; default for a default that depends on another setting.
  def path(key, default = SETTINGS.fetch(key)[1]) = File.expand_path(get(key) || default)

  # Where the value of key comes from: the environment variable, the file, or default.
  def source(key)
    name = SETTINGS.fetch(key)[0]
    return name if ENV[name]
    FILE_VALUES.key?(key) ? CONFIG_FILE : "default"
  end

  # The name of key for a message: the environment variable, or key in the file.
  def name(key) = source(key) == CONFIG_FILE ? "#{key} in #{CONFIG_FILE}" : SETTINGS.fetch(key)[0]

  # The config file as notes config creates it: every setting with what it
  # does, commented out with its default.
  def template
    "# notes-md settings. Remove the # in front of a line to change it.\n" \
    "# An environment variable (#{SETTINGS.values.first[0]}, …) changes a setting for one run.\n" +
      SETTINGS.map { |key, (_, default, text)| "\n# #{text}\n# #{key}: #{default}\n" }.join
  end
end
