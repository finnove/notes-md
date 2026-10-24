require 'cgi'
require 'date'
require 'digest'
require 'nokogiri'
require 'open3'
require 'sqlite3'
require 'yaml'
require 'zlib'

# Shared code for the notes commands. The sections, in order: paths, HTML to
# markdown, verification, dates and filenames, files, the Notes database,
# attachments and checkboxes.
module NotesCommon
  module_function

  # --- Paths ---

  NOTES_ROOT    = ENV["NOTES_ROOT"] || File.expand_path("~/notes")
  RAW_CACHE_DIR = ENV["NOTES_RAW_CACHE"] || File.join(NOTES_ROOT, "apple_notes.raw")
  IMPORT_DIR    = ENV["NOTES_IMPORT"] || File.join(NOTES_ROOT, "import")
  BASELINE_DIR  = ENV["NOTES_BASELINE"] || File.expand_path("~/notes.baseline")
  DB_PATH       = ENV["NOTES_DB"] || File.expand_path("~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
  LANGUAGES     = YAML.load_file(File.join(__dir__, "lang.yml"))
  MD_TEXT       = LANGUAGES.fetch(ENV["NOTES_LANG"] || "en") {
    abort "NOTES_LANG must be one of: #{LANGUAGES.keys.join(", ")}"
  }
  # Headings of the sections after the body, in every language, so a file
  # exported in one language is read right with another.
  MD_SECTIONS   = Regexp.union(LANGUAGES.values.flat_map { |t| t.values_at("attachments", "internal_links") })
  LINK_SECTION  = Regexp.union(LANGUAGES.values.map { |t| t["internal_links"] })

  def open_db = SQLite3::Database.new(DB_PATH, readonly: true)

  # Where notes baseline records the fingerprint of the conversion it was built with.
  FINGERPRINT_FILE = File.join(BASELINE_DIR, ".fingerprint")

  # Fingerprint of what decides the conversion: this file and the pandoc version.
  def conversion_fingerprint
    pandoc, _ = Open3.capture2("pandoc", "--version")
    Digest::SHA256.hexdigest(File.read(__FILE__) + "\0" + pandoc.lines.first.to_s)
  end

  # --- HTML to markdown ---

  # Zero-width space and bidi controls, which Notes leaves in the text.
  INVISIBLE = /[\u{200B}\u{202A}-\u{202E}\u{2066}-\u{2069}]/
  # C0 control characters, which Notes sometimes stores as internal separators.
  CONTROL = /[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}]/

  # Converts raw Apple Notes HTML to a cleaned markdown body.
  # Returns [clean_body, raw_html_for_url_scan, error_message].
  # error_message is nil on success, otherwise the error text from pandoc.
  # raw_html_for_url_scan is the HTML after fix_entities + table fold but before
  # transform_html — used by verify to extract URLs.
  def html_to_markdown(raw_body)
    raw_html = fold_tables(fix_entities(raw_body))
    html = transform_html(raw_body)
    # Workaround for pandoc 3.8: the sequence [\] loses ] in markdown_strict conversion.
    # Broken up with a ZWSP, which is stripped from md_body afterwards.
    html = html.gsub("[\\]", "[\\\u{200B}]")
    # Workaround for pandoc 3.8.3+: in the sequences \" and \' (backslash right
    # before a quote) the quote is swallowed in markdown_strict conversion.
    # Replace with a placeholder before pandoc, and swap back afterwards.
    html = html.gsub('\\"', "\u{F8FA}").gsub("\\'", "\u{F8FB}")
    md_body, pandoc_err, pandoc_status = Open3.capture3(
      "pandoc", "-f", "html", "-t", "markdown_strict+hard_line_breaks+strikeout", "--wrap=none",
      stdin_data: html
    )
    return [nil, raw_html, pandoc_err.strip] unless pandoc_status.success?
    md_body = md_body.gsub(INVISIBLE, "")
    md_body = md_body.gsub("\u{F8FA}", '\\"').gsub("\u{F8FB}", "\\'")
    # The control characters have no visible form in Notes — remove them so
    # they do not pollute the markdown export.
    md_body = md_body.gsub(CONTROL, "")

    clean_body = md_body.sub(/\A(?:[ \t]*\n)+/, "")
                        .sub(/(?:\n[ \t]*)+\z/, "")
                        .gsub(/ {2,}$/, "")
                        .gsub(/^[ \t]+$/, "")
                        .gsub(/\n{3,}/, "\n\n")
                        .gsub(/^(\d+\.)  /, '\1 ')
                        .gsub(/^(\\#+) /) { $1.tr('\\', "\u{F8FC}") + " " }
                        .gsub(/\\([^\w\s])/, '\1')
                        .gsub("\u{F8FC}", '\\')
                        .gsub(/\\_/, "_")
    clean_body = CGI.unescapeHTML(clean_body)
    # CGI does not cover named entities like `&aring;`, `&oslash;`. Decode via
    # Nokogiri on bare entity tokens (not the whole string — that would parse
    # `<https://...>` as a tag and cut the content).
    clean_body = clean_body.gsub(/&[a-zA-Z]+;/) { |ent|
      Nokogiri::HTML::DocumentFragment.parse(ent).text
    }
    has_h1 = clean_body.match?(/^# /)
    has_h2 = clean_body.match?(/^## /)
    has_h3 = clean_body.match?(/^### /)
    clean_body = clean_body.gsub(/^### /, "## ") if has_h1 && has_h3 && !has_h2
    # NOTES_BOLD_LINE_AS_HEADING=1: a line that is only bold text becomes a ## heading.
    clean_body = clean_body.gsub(/^\*\*([^*\n]+)\*\*$/, '## \1') if ENV["NOTES_BOLD_LINE_AS_HEADING"] == "1"
    clean_body = clean_body.gsub(/^(\#{1,6} .*?)[ \t ]+$/, '\1')
    # Always one blank line after #, none after ## or deeper, and exactly one
    # before every heading (also right after a ## heading). Lines with only
    # invisible characters count as blank.
    clean_body = clean_body.gsub(/^(# .*)\n(?:[\p{Z}\p{Cf}\t]*\n)*/, "\\1\n\n")
    clean_body = clean_body.gsub(/^(\#{2,6} .*)\n(?:[\p{Z}\p{Cf}\t]*\n)+/, "\\1\n")
    clean_body = clean_body.gsub(/(?:\n[\p{Z}\p{Cf}\t]*)*\n(?=\#{1,6} )/, "\n\n")
    clean_body = clean_body.sub(/\A(?:[\p{Z}\p{Cf}\t]*\n)+/, "").sub(/(?:\n[\p{Z}\p{Cf}\t]*)+\z/, "")

    [clean_body, raw_html, nil]
  end

  def fix_entities(str)
    str.gsub(/&(lt|gt|amp|quot)(?!;)/, '&\1;')
  end

  # Tables become one line per cell, with a blank line between the rows:
  # Notes tables render badly as markdown tables.
  def fold_tables(html)
    html.gsub(/<table.*?<\/table>/m) { |table|
      Nokogiri::HTML.fragment(table).css("tr").map { |tr| tr.css("td").map(&:inner_html).join("\n") }.join("\n<div><br></div>\n")
    }
  end

  # Applies the block to str again and again until nothing changes.
  def repeat_until_stable(str)
    loop do
      changed = yield(str)
      return str if changed == str
      str = changed
    end
  end

  # Replaces each match of re with a numbered placeholder between two `mark`
  # characters and keeps the match in store, so the passes in between leave it alone.
  def mask(html, re, mark, store)
    html.gsub(re) { |m| store << m; "#{mark}#{store.size - 1}#{mark}" }
  end

  # Puts back what mask took out.
  def unmask(html, mark, store)
    html.gsub(/#{mark}(\d+)#{mark}/) { store[$1.to_i] }
  end

  # Apple Notes-specific HTML normalizations that must run before both pandoc
  # and strip_html, so the same normalized content is compared on both
  # sides. Apple Notes splits e.g. one heading over several <hN> tags;
  # without this merge strip_html would add a newline between each
  # fragment and produce "K rav til venti lasjon" where pandoc gives
  # "Krav til ventilasjon".
  def transform_html(html)
    html = fix_entities(html)
    # Pandoc 3.8.3+ parses `\&entity;` as an "escaped entity" and swallows the
    # whole entity — `\&quot;` becomes just `\` in the markdown output. That hits
    # notes where the user has written literal `\"...\"` around quotes. Replace
    # `\&quot;` (and similar) with a backslash + the decoded character, so pandoc
    # sees plain `\"` and keeps them as `\\"` in markdown.
    html = html.gsub(/\\&(quot|apos|lt|gt|amp);/) {
      { "quot" => '\"', "apos" => "\\'", "lt" => "\\<", "gt" => "\\>", "amp" => "\\&" }[$1]
    }
    # Users write code examples in Apple Notes that are stored with
    # entity-encoded tags (&lt;script&gt;…). Pandoc decodes them to real
    # HTML and autolinks URLs inside — so the code example is broken.
    # Wrap such <div>s in <code> so they are kept as inline code.
    html = html.gsub(%r{<div>([^<]*&lt;[a-zA-Z/][^<]*)</div>}) {
      "<div><code>#{$1}</code></div>"
    }
    html = fold_tables(html)
    html = html.gsub(/<img[^>]+src="data:[^"]*"[^>]*\/?>/, "")
    html = html.gsub(%r{<(b|strong)>\s*(<h[1-6]>)}i, '\2')
    html = html.gsub(%r{(</h[1-6]>)\s*</(b|strong)>}i, '\1')
    html = html.gsub(%r{</(h[1-6])>(?:\s|<br/?>)*<\1>}i, "")
    # Only whitespace inside is a word break (code pasted from the web), not empty.
    # Repeated so <font><span><br></span></font> is unwrapped.
    html = repeat_until_stable(html) { |h|
      h.gsub(%r{<(font|span)\b[^>]*>(\s*)((?:<br>\s*)*)</\1>}i) { $3.empty? && !$2.empty? ? " " : $3 }
    }
    html = html.gsub(%r{</(b|i|strong|em)>\s*<\1>}i, "")
    # Repeated so <b><i><br></i></b> is unwrapped.
    html = repeat_until_stable(html) { |h|
      h.gsub(%r{<(b|i|strong|em)>(\s*)((?:<br\s*/?>\s*)*)</\1>}m) { $3.empty? && !$2.empty? ? " " : $3 }
    }
    html = html.gsub(/<(s|strike|del)>\s*(<br\s*\/?>)?\s*<\/\1>/m, '\2')
    html = html.gsub(/<h[1-6]>\s*(<br>)?\s*<\/h[1-6]>/, '\1')
    html = html.gsub(/<span[^>]*style="[^"]*"[^>]*>(.*?)<\/span>/m, '\1')
    # Apple Notes sometimes creates a corrupt `<a href=(null)>...</a>` when a
    # url attachment is an empty stub (ZTYPEUTI=public.url, ZMEDIA=NULL). Pandoc
    # then renders `(null)` as raw text in markdown, while Nokogiri sees an
    # empty link — so the HTML and markdown sides diverge. Remove the whole
    # anchor before pandoc/Nokogiri see it.
    html = html.gsub(%r{<a\s+href=\(null\)[^>]*>.*?</a>}m, "")
    # Apple Notes styles links as colored+underlined text without <a href>.
    # Wrap bare URLs so pandoc creates real markdown links. Existing <a>...</a>
    # blocks are taken out first, so the URL wrap does not double-wrap URLs
    # that are already inside a link.
    anchors = []
    html = mask(html, %r{<a\b[^>]*>.*?</a>}m, "\u{F8FF}", anchors)
    # URLs inside <code>...</code>, <pre>...</pre> and <font face="Courier">...</font>
    # are code text, not real links — shield them from the URL wrap pass below.
    code_blocks = []
    html = mask(html, %r{<(pre|code)\b[^>]*>.*?</\1>}m, "\u{F8F9}", code_blocks)
    html = mask(html, %r{<font face="Courier"[^>]*>.*?</font>}m, "\u{F8F9}", code_blocks)
    html = html.gsub(%r{(https?://[^\s"'<>]+)}) { |url|
      # A closing ) is only part of the URL when it closes a ( in the URL.
      stripped = repeat_until_stable(url.dup) { |u|
        u = u.sub(/[\].,;:!?]+\z/, "").sub(/&(?:quot|amp|lt|gt|apos|nbsp|oslash|aring|Aring|aelig|AElig);?\z/, "")
        u.end_with?(")") && u.count(")") > u.count("(") ? u.chop : u
      }
      trailing = url[stripped.length..]
      %(<a href="#{stripped}">#{stripped}</a>#{trailing})
    }
    html = unmask(html, "\u{F8F9}", code_blocks)
    html = unmask(html, "\u{F8FF}", anchors)
    html = html.gsub(/<\/?u>/, "")
    html = html.gsub(%r{</div>\s*<div>(?!<br\s*/?>)}, "<br>")
    # Empty <li> elements from web clips (Apple Notes often wraps them in empty
    # <b>/<font> tags with only whitespace). Pandoc makes a list marker "-" from
    # these, but strip_html sees them as empty — so they are removed entirely.
    # Apple Notes sometimes closes <ul> in the middle of a sequence of <li>s, so
    # many <li>s are outside a <ul> context. Empty <li>s are therefore stripped
    # regardless of the outer <ul>. Empty <li>s in <ol> must be kept (they hold
    # their place in the numbering), so ol blocks are masked first.
    ol_blocks = []
    html = mask(html, %r{<ol\b[^>]*>.*?</ol>}m, "\u{F8F8}", ol_blocks)
    html = repeat_until_stable(html) { |h|
      h.gsub(%r{<li[^>]*>(?:\s|<br\s*/?>|<(?:b|strong|i|em|font|span)[^>]*>|</(?:b|strong|i|em|font|span)>)*</li>}i, "")
    }
    html = unmask(html, "\u{F8F8}", ol_blocks)
    # Remove empty <ul>/<ol> left after the li stripping. Pandoc 3.8.3+
    # renders these as an empty list marker "-" in markdown, which would
    # otherwise leave a dangling "-" at the end of the export.
    repeat_until_stable(html) { |h| h.gsub(%r{<(ul|ol)[^>]*>\s*</\1>}i, "") }
  end

  # --- Verification ---

  # Verifies that md_content is semantically equal to raw_html_for_url_scan.
  # md_content is the whole md file (with or without frontmatter; strip_markdown
  # handles both). The attachment and link sections are stripped before the text comparison.
  # export_dir is used to check that internal ref paths exist on disk;
  # pass nil to skip that check.
  # Returns { status:, text_match:, missing_urls:, broken_refs: }.
  def verify(raw_html, md_content, export_dir: nil)
    md_for_text = md_content.gsub(/\n+## #{MD_SECTIONS}\n.*\z/m, "")
    notes_text = normalize(strip_html(raw_html))
    md_text    = normalize(strip_markdown(md_for_text))

    url_trim = ->(u) { u.gsub(/[)\].,;:!?"']+$/, "") }
    # URLs inside <font face="Courier"> or <code> are code text, not real
    # links — skip them so they are not flagged as "missing" when markdown
    # shows them as code.
    html_for_urls = raw_html.gsub(%r{<font face="Courier"[^>]*>.*?</font>}m, "")
                            .gsub(%r{<code>.*?</code>}m, "")
                            .gsub(%r{<div>[^<]*&lt;[a-zA-Z/][^<]*</div>}, "")
    html_urls = html_for_urls.scan(/https?:\/\/[^\s"'<>]+/)
                        .map { |u| url_trim.call(Nokogiri::HTML::DocumentFragment.parse(u).text) }
                        .sort.uniq
    # Balanced parentheses belong to the URL; an unbalanced ) ends a link target.
    md_urls = md_content.scan(/https?:\/\/(?:[^\s"'<>()\]]|\([^\s"'<>()\]]*\))+/)
                        .map { |u| url_trim.call(u.gsub(/\\([^\w\s]|_)/, '\1').gsub(/%22\z/, "")) }
                        .sort.uniq
    missing_urls = html_urls - md_urls

    broken_refs = []
    if export_dir
      internal_refs = md_content.scan(/\]\(([^)]+)\)/).flatten.reject { |u| u.start_with?("http") }
      broken_refs = internal_refs.reject { |ref| File.exist?(File.join(export_dir, ref)) }
    end

    text_match = Digest::SHA256.hexdigest(notes_text) == Digest::SHA256.hexdigest(md_text)
    status = (text_match && missing_urls.empty? && broken_refs.empty?) ? "pass" : "fail"
    { status: status, text_match: text_match, missing_urls: missing_urls, broken_refs: broken_refs }
  end

  def strip_html(str)
    str = transform_html(str)
    # Keep the text content of `&lt;...&gt;` (e.g. email addresses in mail
    # headers like "From: Foo &lt;foo@bar&gt;") through Nokogiri parsing. Without
    # this Nokogiri decodes the entities to `<foo@bar>`, parses it as a tag
    # and drops the content — the markdown side keeps it and text_match=false.
    str = str.gsub("&lt;", "\u{F8FE}").gsub("&gt;", "\u{F8FD}")
    doc = Nokogiri::HTML(str)
    doc.css("br").each { |n| n.replace("\n") }
    doc.css("div, p, li, h1, h2, h3, h4, h5, h6, tr, td, th, pre").each { |n| n.add_next_sibling("\n") }
    text = Nokogiri::HTML::DocumentFragment.parse(doc.text).text
    text = text.gsub("\u{F8FE}", "<").gsub("\u{F8FD}", ">")
    text = text.gsub(INVISIBLE, "")
    text.gsub(/^(\s*[-*+] +)+(?=\S)/, "")
        .gsub(/^\s*(\d+\.\s+)+/, "")
        .gsub(/\*{1,3}/, "")
        .gsub(/`{1,3}/, "")
        .gsub(/(^|(?<=\s))_{1,3}((?=\s)|$)/, "")
        .gsub(/\\([^\w\s])/, '\1')
  end

  def strip_markdown(str)
    str = str.gsub(/\A---\R.*?\R---\R/m, "")
    str = str.gsub(INVISIBLE, "")
    str = str.gsub(/\[([^\]]+)\]\([^)]+\)/, '\1')
    str = str.gsub(/^#+\s+/, "")
    str = str.gsub(/`{1,3}/, "")
    str = str.gsub(/\*{1,3}/, "")
    str = str.gsub(/~~/, "")
    str = str.gsub(/(^|(?<=\s))_{1,3}((?=\s)|$)/, "")
    str = str.gsub(/^> /, "")
    # A checkbox after the list marker comes from the note data, not the HTML.
    str = str.gsub(/^(\s*[-*+] +(\[[ xX]\] +)?)+(?=\S)/, "")
    str = str.gsub(/^\s*(\d+\.\s+)+/, "")
    str = str.gsub(/^```.*$/, "")
    str = str.gsub(/\\([^\w\s]|_)/, '\1')
    str = str.gsub(/<(https?:\/\/[^>]+)>/, '\1')
    str
  end

  # \s is only ASCII in Ruby; \p{Z} also counts a hard space (&nbsp;) as a space.
  def normalize(str)
    str.gsub(/[\s\p{Z}]+/, " ").strip
  end

  # --- Dates and filenames ---

  # Core Data epoch: 2001-01-01 00:00:00 UTC. Apple Notes stores timestamps
  # as seconds since this epoch.
  CORE_DATA_EPOCH = 978307200

  # Converts a Core Data timestamp to an ISO date in the machine's local time
  # zone, the same date Notes shows. TZ in the environment overrides, e.g.
  # TZ=Europe/Oslo.
  def core_data_to_local_date(cd_seconds)
    Time.at(CORE_DATA_EPOCH + cd_seconds.to_f).strftime("%Y-%m-%d")
  end

  # Slugifies a filename: removes unsafe characters, collapses whitespace to
  # hyphens, lowercase. Truncates Apple screenshot ("skjermbilde") suffixes after the date.
  # Leading dots are removed so the export never creates hidden files/folders.
  def safe_filename(name)
    name = name.gsub(/[\/\\\:\*\?\"\<\>\|#\[\]\(\),]/, '').sub(/\A[.\s]+/, '').strip.gsub(/[\s-]+/, '-').downcase
    name.sub(/(skjermbilde-\d{4}-\d{2}-\d{2}).*/, '\1')
  end

  # Like safe_filename, but keeps spaces between words. Used for note titles
  # in md filenames. Only the date prefix has hyphens; words are separated by
  # spaces. Leading dots and all … are removed.
  def safe_note_filename(name)
    name = name.gsub(/[\/\\\:\*\?\"\<\>\|#\[\]\(\),…]/, '').sub(/\A[.\s]+/, '').strip.gsub(/\s+/, ' ').downcase
    name.sub(/(skjermbilde \d{4}-\d{2}-\d{2}).*/, '\1')
  end

  MONTHS = %w[januar februar mars april mai juni juli august september oktober november desember].freeze
  WEEKDAYS = %w[mandag tirsdag onsdag torsdag fredag lørdag søndag].freeze
  # Date first in the title, optionally with a weekday in front: ISO, dd.mm.yyyy
  # (. - /) or "2. januar 2025". Month and weekday names are Norwegian. The
  # date must stand alone, not glued to text.
  TITLE_DATE = /\A(?:(#{WEEKDAYS.join("|")})\s+)?(?:(\d{4})-(\d{2})-(\d{2})|(\d{1,2})[.\-\/](\d{1,2})[.\-\/](\d{4})|(\d{1,2})\.?\s+(#{MONTHS.join("|")})\.?\s+(\d{4}))(?=\s|\z)/i
  PLACEHOLDER_TITLE = /\A(?:\d+\s+)?(?:untitled(?:\s+(?:snapshot|text))?(?:\s+note)?|notat)(?:\s+\d+)?\z/i

  # Filename without .md for a new md file. If the title starts with a date,
  # that date comes first and wins over created_at; a weekday in front of the
  # date is moved right after it. Placeholder titles (untitled, notat) give only the date.
  def note_basename(title, created_date)
    title = title.unicode_normalize(:nfc).strip
    date = created_date
    if (m = title.match(TITLE_DATE))
      y, mo, d = if m[2] then [m[2], m[3], m[4]]
                 elsif m[7] then [m[7], m[6], m[5]]
                 else [m[10], MONTHS.index(m[9].downcase) + 1, m[8]]
                 end
      if Date.valid_date?(y.to_i, mo.to_i, d.to_i)
        date = format("%04d-%02d-%02d", y.to_i, mo.to_i, d.to_i)
        title = [m[1], m.post_match.strip].compact.reject(&:empty?).join(" ")
      end
    end
    name = safe_note_filename(title)
    name = "" if name.match?(PLACEHOLDER_TITLE)
    name.empty? ? date : "#{date} #{name}"
  end

  # --- Files ---

  # Compares the existing and new file text for --marked and --failed.
  def refresh_compare(existing_text, new_text)
    existing_text == new_text ? :identical : :differ
  end

  # Atomic write: write to a tmp file, rename into place.
  def write_atomic(path, content)
    tmp = "#{path}.tmp.#{Process.pid}.#{rand(1_000_000)}"
    File.write(tmp, content)
    File.rename(tmp, path)
  end

  FRONTMATTER = /\A---\n.*?\n---\n/m

  # Checksum of the text under the frontmatter. The export writes it as
  # note_sum, so a rebuild can tell whether the file was edited by hand.
  def body_sum(text) = Digest::SHA256.hexdigest(text.sub(FRONTMATTER, ""))[0, 16]

  # The frontmatter fields as written, { "key" => "key: value\n  ...\n" }, with
  # indented continuation lines kept, so fields can be written back unchanged.
  def frontmatter_entries(text)
    block = text[/\A---\n(.*?\n)---\n/m, 1] or return {}
    block.lines.slice_before { |l| l =~ /\A[^\s:][^:]*:/ }.to_h { |e| [e.first[/\A([^:]+):/, 1], e.join] }
  end

  # Frontmatter as { "key" => "value" }, raw text without surrounding quotes.
  # Empty hash if the text does not start with ---.
  def frontmatter(text)
    block = text[/\A---\n(.*?)\n---/m, 1] or return {}
    block.scan(/^([^\s:]+):[ \t]*(.*)$/).to_h { |k, v| [k, v.strip.sub(/\A(["'])(.*)\1\z/, '\2')] }
  end

  # --- Notes database ---

  # Full folder path ("Journal/2024") per folder pk in Notes. "Recently Deleted"
  # (ZFOLDERTYPE 1) is not included.
  def folder_paths(db)
    folders = {}
    db.execute("SELECT Z_PK, ZTITLE2, ZPARENT FROM ZICCLOUDSYNCINGOBJECT " \
               "WHERE ZTITLE2 IS NOT NULL AND ZFOLDERTYPE IS NOT 1").each do |pk, title, parent|
      folders[pk] = [title, parent]
    end
    paths = {}
    path = ->(pk) {
      paths[pk] ||= begin
        title, parent = folders[pk]
        folders.key?(parent) ? "#{path.(parent)}/#{title}" : title
      end
    }
    folders.each_key { |pk| path.(pk) }
    paths
  end

  Note = Struct.new(:pk, :uuid, :title, :folder, :created)

  # Notes in use: not deleted and not in "Recently Deleted".
  def active_notes(db)
    db.execute("SELECT n.Z_PK, lower(n.ZIDENTIFIER), n.ZTITLE1, n.ZFOLDER, n.ZCREATIONDATE3 " \
               "FROM ZICCLOUDSYNCINGOBJECT n LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER " \
               "WHERE n.ZIDENTIFIER IS NOT NULL AND n.ZTITLE1 IS NOT NULL " \
               "AND n.ZMARKEDFORDELETION = 0 AND f.ZFOLDERTYPE IS NOT 1").map { |r| Note.new(*r) }
  end

  # ZDATA (gzip + protobuf) for a note. nil for locked notes, where it is encrypted.
  def note_zdata(db, uuid)
    db.get_first_value("SELECT n.ZDATA FROM ZICNOTEDATA n JOIN ZICCLOUDSYNCINGOBJECT o ON o.Z_PK = n.ZNOTE " \
                       "WHERE lower(o.ZIDENTIFIER) = ? AND o.ZISPASSWORDPROTECTED IS NOT 1", [uuid.downcase])
  end

  # --- Attachments ---

  ATTACHMENT_SQL = "SELECT m.ZIDENTIFIER, m.ZFILENAME, acct.ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT a " \
    "JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK=a.ZMEDIA " \
    "JOIN ZICCLOUDSYNCINGOBJECT acct ON acct.Z_PK=a.ZACCOUNT1 " \
    "WHERE a.Z_ENT=5 AND a.ZNOTE=?"

  # The attachments of a note: [[media_uuid, source_file], ...]. Each media ID has
  # one file: the one named ZFILENAME, two levels down in the account's Media folder.
  # If ZFILENAME is a folder (Numbers package, folder dragged into the note), the
  # attachment is the zip next to it, ZFILENAME.zip; the files Notes has unpacked
  # do not belong to it. nil when the file is missing, e.g. not downloaded from iCloud.
  def attachment_sources(db, note_pk)
    db.execute(ATTACHMENT_SQL, note_pk).map do |media_uuid, filename, account|
      dir = File.expand_path("~/Library/Group Containers/group.com.apple.notes/Accounts/#{account}/Media/#{media_uuid}")
      [media_uuid, attachment_file(dir, filename)]
    end
  end

  def attachment_file(dir, filename)
    return nil unless filename && File.directory?(dir)
    want = filename.unicode_normalize(:nfc)
    # Filenames from disk are marked as UTF-8; without a UTF-8 locale they come back binary.
    children = ->(d) { Dir.children(d).map { |c| c.dup.force_encoding("UTF-8") }.sort.map { |c| File.join(d, c) } }
    entries = children.(dir).select { |c| File.directory?(c) }.flat_map { |sub| children.(sub) }
    named = ->(name) { entries.find { |e| File.basename(e).scrub.unicode_normalize(:nfc) == name } }
    hit = named.(want)
    return nil unless hit
    return hit if File.file?(hit)
    zip = named.(want + ".zip")
    zip if zip && File.file?(zip)
  end

  # The filename an attachment gets in assets/: the attachment's UUID and the source file's extension.
  def asset_name(media_uuid, src)
    "#{media_uuid}#{File.extname(src).downcase}"
  end

  # The content as written to assets/. HTML without a charset gets utf-8.
  def asset_data(src)
    return File.binread(src) unless File.extname(src).downcase == ".html"
    html = File.read(src)
    html.include?("charset") ? html : html.sub(/<html>/, '<html><head><meta charset="utf-8"></head>')
  end

  # --- Checkboxes ---
  # Apple Notes' body() HTML loses the checkbox state: checklists become plain
  # <ul><li>. The state is only in NoteStore.sqlite, in ZDATA (gzip + protobuf).

  # Minimal protobuf reader: field number → list of values (Integer for
  # varint, binary String for length-delimited). 64/32-bit fields are skipped.
  def proto(buf)
    fields = Hash.new { |h, k| h[k] = [] }
    pos = 0
    read_varint = -> {
      n = 0
      shift = 0
      loop do
        byte = buf.getbyte(pos)
        pos += 1
        n |= (byte & 0x7f) << shift
        shift += 7
        break if byte < 0x80
      end
      n
    }
    while pos < buf.bytesize
      key = read_varint.call
      case key & 7
      when 0 then fields[key >> 3] << read_varint.call
      when 1 then pos += 8
      when 2
        len = read_varint.call
        fields[key >> 3] << buf.byteslice(pos, len)
        pos += len
      when 5 then pos += 4
      end
    end
    fields
  end

  # Returns [[text, done, attachment_ids], ...] for all checklist paragraphs in
  # the note. Run lengths are UTF-16 units (NSString), not Ruby characters.
  # Attachments (U+FFFC in the text) have their id in attachment_info (field 12) on their run.
  def checklist_items(zdata)
    data = Zlib::Inflate.new(Zlib::MAX_WBITS + 32).inflate(zdata)
    note = proto(proto(proto(data)[2][0])[3][0])
    text = note[2][0].force_encoding("UTF-8")

    runs = []
    offset = 0
    note[5].each do |run|
      r = proto(run)
      style = proto(r[2][0] || "")
      check = style[5].empty? ? nil : proto(style[5][0])
      att = r[12].empty? ? nil : proto(r[12][0])[1][0]&.force_encoding("UTF-8")
      runs << [offset, offset + r[1][0], check, att]
      offset += r[1][0]
    end

    items = []
    start = 0
    para = +""
    offset = 0
    text.each_char do |c|
      if c == "\n"
        run = runs.find { |s, e, _| s <= start && start < e }
        atts = runs.select { |s, _, _, a| a && s >= start && s < offset }.map(&:last)
        items << [para, run[2][2][0] == 1, atts] if run && run[2]
        para = +""
        start = offset + 1
      else
        para << c
      end
      offset += c.ord > 0xFFFF ? 2 : 1
    end
    run = runs.find { |s, e, _| s <= start && start < e }
    atts = runs.select { |s, _, _, a| a && s >= start }.map(&:last)
    items << [para, run[2][2][0] == 1, atts] if run && run[2] && !para.empty?
    items
  end

  def checkbox_normalize(str)
    str.unicode_normalize(:nfc)
       .gsub(INVISIBLE, "")
       .gsub(CONTROL, "")
       .gsub(/[[:space:]]+/, " ")
       .strip
  end

  # Notes text → regex against normalized md text. U+FFFC is an inline attachment
  # (hashtag, note link etc.) that the export writes out as text. * and ` are
  # removed because strip_markdown removes them on the md side. Spaces are ignored:
  # the export merges `<i>a</i> <i>b</i>` into `*ab*` and loses the space.
  def checkbox_pattern(text)
    parts = checkbox_normalize(text.delete("*`")).delete(" ").split("\u{FFFC}", -1).map { |p| Regexp.escape(p) }
    /\A#{parts.join(".*?")}\z/
  end

  # Numbered items are included: Notes HTML sometimes puts checklist items inside
  # an <ol>, and then they become `2. text` in md. The number is replaced with `-`.
  CHECKBOX_LIST_LINE = /\A(\s*)([-*+]|\d+\.)\s+(?:\[[ xX]\]\s+)?(.*)\z/

  # The content comes after the list marker, so the line-start rules in
  # strip_markdown (numbered list, heading, quote) must not apply. \u{F8F0} in
  # front keeps ^ from matching.
  def checkbox_md_text(content)
    checkbox_normalize(strip_markdown("\u{F8F0}" + content.gsub(/\\([*`])/, "")).delete("\u{F8F0}"))
  end

  # Shows invisible and special characters as \uXXXX, the rest as is.
  def visible(str)
    '"' + str.gsub(/[^\P{Space} ]|\p{Cc}|\p{Cf}|\u{FFFC}|"/) { |c| c == '"' ? '\\"' : format('\\u%04X', c.ord) } + '"'
  end

  def levenshtein(a, b)
    prev = (0..b.size).to_a
    a.each_char.with_index(1) do |ca, i|
      cur = [i]
      b.each_char.with_index(1) do |cb, j|
        cur << [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca == cb ? 0 : 1)].min
      end
      prev = cur
    end
    prev.last
  end

  # Turns `- text` into `- [ ] text` / `- [x] text` in the md text according to
  # the checked state in ZDATA. alt_text looks up the link text (ZALTTEXT) for an
  # attachment id. Returns [new text, problems] where each problem is a
  # checklist item that was not found in md.
  def apply_checkboxes(text, zdata, alt_text)
    items = checklist_items(zdata).reject { |t, _| checkbox_normalize(t).empty? }
    return [text, []] if items.empty?

    lines = text.split("\n", -1)
    body_start = lines[0] == "---" ? lines[1..].index("---") + 2 : 0
    body_end = lines.each_index.find { |i| i >= body_start && lines[i] =~ /\A## #{MD_SECTIONS}\z/ } || lines.size

    # Line breaks inside an item (U+2028 in Notes) become indented lines under
    # the list line in md. They are included so the whole item is compared.
    continuation = ->(i) {
      (i + 1...body_end).take_while { |j| lines[j] =~ /\A\s+\S/ && lines[j] !~ CHECKBOX_LIST_LINE }
                        .map { |j| checkbox_md_text(lines[j]) }
    }
    candidates = (body_start...body_end).select { |i| lines[i] =~ CHECKBOX_LIST_LINE }
                                        .map { |i| [i, ([checkbox_md_text(lines[i][CHECKBOX_LIST_LINE, 3])] + continuation.call(i)).join(" ")] }
    # An item that is only a note link (U+FFFC) is not in the body, only in the
    # internal links section as `- link text → applenotes:...`. The link text
    # (ZALTTEXT) is looked up via the attachment id.
    link_start = lines.each_index.find { |i| i >= body_start && lines[i] =~ /\A## #{LINK_SECTION}\z/ }
    link_lines = []
    if link_start
      (link_start + 1...lines.size).take_while { |i| !lines[i].start_with?("## ") }.each do |i|
        link_lines << [i, checkbox_normalize(checkbox_md_text($1)).delete(" ")] if lines[i] =~ /\A- (?:\[[ xX]\] )?(.*?) → /
      end
    end

    used = {}
    cursor = -1
    not_found = []
    items.each do |item_text, done, atts|
      if checkbox_normalize(item_text.delete("\u{FFFC}")).empty?
        alt = atts.map { |a| alt_text.call(a) }.compact.join(" ")
        hit = link_lines.find { |i, t| !used[i] && !alt.empty? && t == checkbox_normalize(alt).delete(" ") }
        unless hit
          not_found << [alt.empty? ? item_text : alt, item_text]
          next
        end
        i = hit[0]
        used[i] = true
        lines[i] = "- [#{done ? 'x' : ' '}] #{lines[i].sub(/\A- (?:\[[ xX]\] )?/, '')}"
        next
      end

      pattern = checkbox_pattern(item_text)
      free = candidates.reject { |i, _| used[i] }.select { |_, t| t.delete(" ").match?(pattern) }
      hit = free.find { |i, _| i > cursor } || free.first
      unless hit
        not_found << [item_text, item_text]
        next
      end
      i = hit[0]
      used[i] = true
      cursor = i
      indent, marker, content = lines[i].match(CHECKBOX_LIST_LINE).captures
      marker = "-" if marker.end_with?(".")
      lines[i] = "#{indent}#{marker} [#{done ? 'x' : ' '}] #{content}"
    end

    # Raw Notes text and the md line in the body that is most similar, with
    # invisible characters made visible. Line numbers are for the whole file.
    # Link items are shown with the link text and compared against the whole file.
    problems = not_found.map { |shown, raw|
      want = checkbox_normalize(shown).delete(" ")
      i = (body_start...lines.size).reject { |j| lines[j].strip.empty? }
                                   .min_by { |j| levenshtein(want, checkbox_normalize(lines[j]).delete(" ")) }
      md = i ? "md #{i + 1}:  #{visible(lines[i])}" : "md:    (no lines)"
      "not found in md: #{checkbox_normalize(shown)}\n  notes: #{visible(raw)}\n  #{md}"
    }
    [lines.join("\n"), problems]
  end
end
