require_relative "lib/notes_md/version"

Gem::Specification.new do |s|
  s.name        = "notes-md"
  s.version     = NotesMd::VERSION
  s.summary     = "Export Apple Notes to markdown files with YAML frontmatter"
  s.authors     = ["Finn-Ove Lium"]
  s.homepage    = "https://github.com/finnove/notes-md"
  s.license     = "GPL-3.0-only"
  s.required_ruby_version = ">= 3.0"

  s.files       = Dir["bin/*", "lib/**/*", "README.md", "LICENSE"]
  s.executables = ["notes"]

  s.add_dependency "nokogiri"
  s.add_dependency "sqlite3"
end
