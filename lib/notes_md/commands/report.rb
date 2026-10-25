#!/usr/bin/env ruby
# encoding: UTF-8
# Builds every note with export: fail again in memory, as notes export builds
# it, and shows where the check fails with the text masked, so the report can
# be pasted into an issue. Writes nothing.

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require_relative '../common'
require_relative '../version'
require 'open3'
require 'optparse'
require 'sqlite3'

TEST_FILE = "test/report_test.rb"

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: notes report [--baseline]\n\n" \
                "Makes a report of the notes that fail the check, which you can paste into an issue.\n" \
                "Without it, a bug report needs the text of your notes.\n\n" \
                "Builds every md file with export: fail again in memory, with the code you have now, and\n" \
                "shows where the check fails: the first difference, the HTML from Notes and the md around it.\n" \
                "Letters become a and digits 0; punctuation, markdown and HTML tags are shown, invisible\n" \
                "characters as \\uXXXX. Writes nothing.\n\n" \
                "Options:"
  opts.on("--baseline", "The notes with export: fail in the baseline (~/notes.baseline) instead of ~/notes") { options[:baseline] = true }
  opts.on("-h", "--help", "Show this help") { puts opts; exit }
  opts.separator ""
  opts.separator "Examples:"
  opts.separator "  notes report"
  opts.separator "  notes report --baseline"
  opts.separator "  notes report > report.txt"
end
parser.parse!

# --- Masking ---

# Tags and attributes from Notes that are shown as they are. Anything else
# between < and > is text and masked.
TAGS = %w[a b blockquote br code del div em font h1 h2 h3 h4 h5 h6 hr i img li object ol p pre s span strike strong sub sup table tbody td th thead tr tt u ul]
ATTRIBUTES = %w[href src alt face style class dir color size]
# Attribute values shown as they are: they say how the text looks, not what it says.
SHOWN_VALUES = %w[face style class dir color size]
ENTITIES = %w[lt gt amp quot apos nbsp]

TAG = %r{<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:\s+[a-zA-Z-]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>"']+))?)*)\s*(/?)>}
ATTRIBUTE = /(\s+)([a-zA-Z-]+)(?:(\s*=\s*)("[^"]*"|'[^']*'|[^\s>"']+))?/

mask_text = ->(s) { s.gsub(/\p{L}/, "a").gsub(/\p{N}/, "0") }
# Invisible and special characters as \uXXXX; line breaks are kept.
visible = ->(s) { s.gsub(/[\p{Cc}\p{Cf}\p{Z}\u{FFFC}&&[^ \n]]/) { |c| format("\\u%04X", c.ord) } }

mask_tag = ->(m) {
  close, name, attrs, slash = m.match(TAG).captures
  return nil unless TAGS.include?(name.downcase)
  attrs = attrs.gsub(ATTRIBUTE) {
    space, attr, eq, value = $1, $2, $3, $4
    attr = mask_text.(attr) unless ATTRIBUTES.include?(attr.downcase)
    value = mask_text.(value) if value && !SHOWN_VALUES.include?(attr.downcase)
    "#{space}#{attr}#{eq}#{value}"
  }
  "<#{close}#{name}#{attrs}#{slash}>"
}

# Text with the letters and digits masked; HTML tags from TAGS and the
# entities in ENTITIES are shown.
mask = ->(s) {
  out = s.gsub(/#{TAG}|&([a-zA-Z]+);|[^<&]+|[<&]/) { |m|
    if m.start_with?("<") && m.length > 1
      mask_tag.(m) || mask_text.(m)
    elsif m.start_with?("&") && m.length > 1
      ENTITIES.include?(m[1..-2]) ? m : mask_text.(m)
    else
      mask_text.(m)
    end
  }
  visible.(out)
}

# What a character is: letter, digit, space, end of text, or the character
# itself (punctuation, symbols, emoji), invisible ones as \uXXXX.
char_class = ->(c) {
  if c.nil? then "end of text"
  elsif c.match?(/\p{L}/) then "letter"
  elsif c.match?(/\p{N}/) then "digit"
  elsif c == " " then "space"
  else visible.(c)
  end
}

# --- Where the difference is ---

# The smallest prefix of raw whose stripped, normalized text reaches past
# position k, so the raw text around the difference can be shown.
position_in = ->(raw, k, strip) {
  lo = 0
  hi = raw.length
  while lo < hi
    mid = (lo + hi) / 2
    if NotesCommon.normalize(strip.(raw[0, mid])).length > k
      hi = mid
    else
      lo = mid + 1
    end
  end
  lo
}

# The raw text around position p, masked, indented on its own lines.
around = ->(raw, p) {
  from = [p - 120, 0].max
  mask.(raw[from, 240]).split("\n").reject(&:empty?).map { |l| "    #{l}\n" }.join
}

# --- Versions ---

# The first line a command prints; nil when it fails or is missing (sw_vers outside macOS).
run = lambda do |*cmd|
  out, status = Open3.capture2(*cmd, err: File::NULL)
  status.success? ? out.lines.first.to_s.strip : nil
rescue Errno::ENOENT
  nil
end
# The commit too when run from the repo; an installed gem has no git.
repo = File.expand_path("../../..", __dir__)
commit = run.("git", "-C", repo, "rev-parse", "--short", "HEAD")
dirty = run.("git", "-C", repo, "status", "--porcelain", "--", "bin", "lib")
puts "notes-md: #{NotesMd::VERSION}#{" (#{commit}#{", with changes" if dirty && !dirty.empty?})" if commit}"
puts "pandoc: #{run.("pandoc", "--version").to_s.sub(/\Apandoc /, "")}"
puts "macOS: #{run.("sw_vers", "-productVersion") || "unknown"}"
puts ""

# --- The notes ---

db = NotesCommon.open_db
failed = []
Dir.glob(File.join(options[:baseline] ? NotesCommon::BASELINE_DIR : NotesCommon::NOTES_ROOT, "**", "*.md")).sort.each do |f|
  fm = NotesCommon.frontmatter(File.read(f, encoding: "UTF-8"))
  failed << fm["note_id"] if fm["note_id"] && fm["export"] == "fail"
end

reports = []
not_cached = 0
not_in_db = 0
failed.each do |id|
  cache_path = File.join(NotesCommon::RAW_CACHE_DIR, "#{id}.html")
  next not_cached += 1 unless File.exist?(cache_path)
  raw = File.read(cache_path, encoding: "UTF-8")
  pk, cd = db.get_first_row("SELECT Z_PK, ZCREATIONDATE3 FROM ZICCLOUDSYNCINGOBJECT WHERE lower(ZIDENTIFIER) = ?", [id.downcase])
  next not_in_db += 1 unless pk
  built = NotesCommon.build_md(db, id, raw, note_pk: pk, created_date: NotesCommon.core_data_to_local_date(cd),
                               ref_ok: ->(_, src) { File.exist?(src) })
  if built[:error]
    reports << ["pandoc failed", "  #{mask.(built[:error])}\n"]
    next
  end
  r = built[:result]
  next if r[:status] == "pass"

  lines = []
  unless r[:text_match]
    # The same text the check compares, as verify builds it.
    body = built[:text].sub(NotesCommon::FRONTMATTER, "").gsub(/(\A|\n+)## #{NotesCommon::MD_SECTIONS}\n.*\z/m, "")
    a = NotesCommon.normalize(NotesCommon.strip_html(raw))
    b = NotesCommon.normalize(NotesCommon.strip_markdown(body))
    k = (0...[a.size, b.size].min).find { |j| a[j] != b[j] } || [a.size, b.size].min
    from = [k - 40, 0].max
    cut = from > 0 ? "…" : ""
    lines << "  first difference at character #{k + 1}\n"
    lines << "  Notes: #{char_class.(a[k])}, md: #{char_class.(b[k])}\n"
    # The text from Notes has no tags left: everything in it is text.
    lines << "  Notes text: #{cut}#{visible.(mask_text.(a[from, 80].to_s))}\n"
    lines << "  md text:    #{cut}#{mask.(b[from, 80].to_s)}\n"
    lines << "  HTML:\n" + around.(raw, position_in.(raw, k, ->(s) { NotesCommon.strip_html(s) }))
    lines << "  md:\n" + around.(body, position_in.(body, k, ->(s) { NotesCommon.strip_markdown(s) }))
  end
  r[:missing_urls].each { |u| lines << "  URL missing in md: #{mask.(u)}\n" }
  r[:broken_refs].each { |ref| lines << "  attachment missing: #{mask.(File.extname(ref))}\n" }
  what = [("the text differs" unless r[:text_match]), ("URLs are missing" if r[:missing_urls].any?),
          ("attachments are missing" if r[:broken_refs].any?)].compact.join(", ")
  reports << [what, lines.join]
end

puts "#{failed.size} note(s) with export: fail#{", #{reports.size} still fail with this code" if failed.any?}."
puts "#{not_cached} note(s) not in the local copy: run notes sync." if not_cached > 0
puts "#{not_in_db} note(s) not in Notes." if not_in_db > 0
reports.each_with_index do |(what, text), i|
  puts ""
  puts "Note #{i + 1} of #{reports.size}: #{what}"
  print text
end
puts ""
puts "The report has no text from your notes and can be pasted into an issue; " \
     "it shows the structure (word lengths, punctuation, emoji)."
