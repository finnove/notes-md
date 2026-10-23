# Tests for notes_common.rb. The end-to-end tests for notes export are
# in export_test.rb.
require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'set'
require 'sqlite3'
require 'tmpdir'
require 'yaml'
require_relative 'notes_proto_helper'
require_relative '../notes_common'

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# The tests should give the same result whether or not the user has turned the rule on.
ENV.delete("NOTES_BOLD_LINE_AS_HEADING")

class NotesCommonTest < Minitest::Test
  def n(s); NotesCommon.normalize(s); end
  def h(s); NotesCommon.strip_html(s); end
  def m(s); NotesCommon.strip_markdown(s); end

  # Text written into the md files is read from lang.yml.
  def test_body_sum_ignores_frontmatter
    a = NotesCommon.body_sum("---\nexport: pass\n---\n\nHei\n")
    assert_equal a, NotesCommon.body_sum("---\nexport: fail\nreviews: 2\n---\n\nHei\n")
    refute_equal a, NotesCommon.body_sum("---\nexport: pass\n---\n\nHei!\n")
    assert_match(/\A\h{16}\z/, a)
  end

  def test_frontmatter_entries_keep_lines_as_written
    entries = NotesCommon.frontmatter_entries("---\nhint: \"a: b\"\nsteps:\n  - one\n  - two\nx: 1\n---\nbody\n")
    assert_equal({ "hint" => "hint: \"a: b\"\n", "steps" => "steps:\n  - one\n  - two\n", "x" => "x: 1\n" }, entries)
    assert_equal({}, NotesCommon.frontmatter_entries("no frontmatter\n"))
  end

  def test_conversion_fingerprint_is_stable_sha256
    fp = NotesCommon.conversion_fingerprint
    assert_match(/\A\h{64}\z/, fp)
    assert_equal fp, NotesCommon.conversion_fingerprint
  end

  def test_md_text_read_from_lang_file
    lang = YAML.load_file(File.expand_path('../lang.yml', __dir__))
    assert_equal lang["en"], NotesCommon::MD_TEXT
    assert_equal %w[en nb], lang.keys.sort
    lang.each_value { |t| assert_equal %w[attachments internal_links], t.keys.sort }
  end

  def test_md_headings_not_hardcoded
    %w[libexec/export notes_common.rb].each do |f|
      code = File.readlines(File.expand_path("../#{f}", __dir__)).reject { |l| l.strip.start_with?("#") }
      refute code.any? { |l| l.include?("Attachments") || l.include?("Internal links") }, f
    end
  end

  # K3: block elements should give a space between their contents
  def test_consecutive_divs_get_spaced
    assert_equal "linje1 linje2", n(h("<div>linje1</div><div>linje2</div>"))
  end

  def test_br_gives_space
    assert_equal "linje1 linje2", n(h("linje1<br>linje2"))
  end

  def test_list_items_get_spaced
    assert_equal "foo bar", n(h("<ul><li>foo</li><li>bar</li></ul>"))
  end

  def test_headings_get_spaced
    assert_equal "Tittel Brødtekst", n(h("<h1>Tittel</h1><div>Brødtekst</div>"))
  end

  # K2: links should be compared on link text, not URL
  def test_markdown_link_reduces_to_text
    assert_equal "klikk her", n(m("[klikk her](https://example.com/foo)"))
  end

  def test_html_and_markdown_link_match
    html = '<a href="https://example.com/x">link</a>'
    md   = '[link](https://example.com/x)'
    assert_equal n(h(html)), n(m(md))
  end

  # H1: body text starting with "# " should NOT be stripped (a known asymmetry
  # is accepted here — strip_markdown still removes it, but only at line start)
  # The realistic case is tested: a heading in markdown matches plain text in HTML.
  def test_heading_matches_plain_text
    assert_equal n(h("<h1>Overskrift</h1>")), n(m("# Overskrift"))
  end

  # H2: ZWSP should be removed the same way on both sides
  def test_zwsp_stripped_from_html
    refute_includes h("a\u{200B}b"), "\u{200B}"
  end

  def test_zwsp_stripped_from_markdown
    refute_includes m("a\u{200B}b"), "\u{200B}"
  end

  # Bidi control characters (LRE/RLE/PDF/LRO/RLO/LRI/RLI/FSI/PDI) should be removed
  def test_bidi_controls_stripped_from_html
    s = "a\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}b"
    assert_equal "ab", n(h("<div>#{s}</div>"))
  end

  def test_bidi_controls_stripped_from_markdown
    s = "a\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}b"
    assert_equal "ab", n(m(s))
  end

  # Character test: special characters should be symmetric
  def test_special_characters_symmetric
    chars = %q{!¡"#$%'()*+,-./:;<=>¿?@[]^_{|}~}
    html = "<div>Tegntest: #{chars}</div>"
    md   = "Tegntest: #{chars}"
    assert_equal n(h(html)), n(m(md))
  end

  def test_backtick_symmetric
    assert_equal n(h("<div>`code`</div>")), n(m("`code`"))
  end

  def test_backslash_escape_symmetric
    assert_equal n(h("<div>a\\]b</div>")), n(m('a\]b'))
  end

  # Pandoc escapes `_` in URLs — markdown must be normalized to the same as HTML
  def test_escaped_underscore_in_url_symmetric
    html = '<div>https://example.com/foo_bar_baz</div>'
    md   = 'https://example.com/foo\_bar\_baz'
    assert_equal n(h(html)), n(m(md))
  end

  # Frontmatter with CRLF should also be removed (M8)
  def test_frontmatter_with_crlf_stripped
    md = "---\r\nfoo: bar\r\n---\r\ninnhold"
    assert_equal "innhold", n(m(md))
  end

  def test_frontmatter_with_lf_stripped
    md = "---\nfoo: bar\n---\ninnhold"
    assert_equal "innhold", n(m(md))
  end

  # List markers should be removed on both sides
  def test_list_marker_symmetric
    assert_equal n(h("<ul><li>punkt</li></ul>")), n(m("- punkt"))
  end

  def test_numbered_list_symmetric
    assert_equal n(h("<ol><li>første</li></ol>")), n(m("1. første"))
  end

  # Literal hyphens the user has written (not list markers) should be kept
  # symmetrically on both sides, so verify does not flag a false text mismatch.
  def test_bare_dash_lines_symmetric
    html = "<div>Mot</div><div>- </div><div>- </div><div>DNB</div>"
    md   = "Mot\n-\n-\nDNB"
    assert_equal n(h(html)), n(m(md))
  end

  # Bold/italic markdown
  def test_bold_symmetric
    assert_equal n(h("<b>fet</b>")), n(m("**fet**"))
  end

  def test_italic_symmetric
    assert_equal n(h("<i>kursiv</i>")), n(m("*kursiv*"))
  end

  # Apple Notes styles links as colored+underlined text without <a href>.
  # transform_html should wrap such bare URLs in <a> so pandoc creates real links.
  def test_bare_url_in_u_font_wrapped_as_link
    html = '<u><font color="#E4AF0A">http://example.com/subscribe</font></u>'
    out  = NotesCommon.transform_html(html)
    assert_includes out, '<a href="http://example.com/subscribe">http://example.com/subscribe</a>'
  end

  def test_bare_url_in_font_color_wrapped_as_link
    html = '<font color="#E4AF0A"><span style="font-size: 10px">http://example.org/foo</span></font>'
    out  = NotesCommon.transform_html(html)
    assert_includes out, '<a href="http://example.org/foo">http://example.org/foo</a>'
  end

  def test_url_already_in_anchor_not_double_wrapped
    html = '<a href="http://example.com">http://example.com</a>'
    out  = NotesCommon.transform_html(html)
    refute_match %r{<a[^>]*><a }, out
  end

  # Apple Notes sometimes wraps the URL in <a> itself around colored text.
  # The URL wrap must not double-wrap URLs that are already inside <a>...</a>.
  def test_url_inside_existing_anchor_not_wrapped
    html = '<a href="http://example.com"><font color="#E4AF0A">http://example.com</font></a>'
    out  = NotesCommon.transform_html(html)
    # Should not have two <a> tags wrapped around the same URL
    assert_equal 1, out.scan(/<a /).size, "expected only one <a> wrap, got: #{out.inspect}"
  end

  # HTML entities (&quot;, &oslash; etc.) that survive Nokogiri.text must be
  # decoded on both sides, otherwise verify fails on text and URL.
  def test_named_entity_quot_symmetric
    html = "<div>foo&quot;bar</div>"
    md   = 'foo"bar'
    assert_equal n(h(html)), n(m(md))
  end

  def test_named_entity_oslash_in_url_symmetric
    html = '<a href="https://example.com/bel&oslash;nning">https://example.com/bel&oslash;nning</a>'
    md   = '[https://example.com/belønning](https://example.com/belønning)'
    assert_equal n(h(html)), n(m(md))
  end

  # MD URL extraction must stop at ] (otherwise the regex eats [url](url) as one)
  def test_verify_md_url_extraction_stops_at_bracket
    raw_html = '<a href="https://example.com/x">https://example.com/x</a>'
    md       = '[https://example.com/x](https://example.com/x)'
    result = NotesCommon.verify(raw_html, md)
    assert_empty result[:missing_urls], "missing_urls=#{result[:missing_urls].inspect}"
  end
end

# --- Regression: scenarios found against real cache files in May 2026.
#     Each test makes sure a specific conversion bug does not come back.

class NotesRegressionTest < Minitest::Test
  def html2md(html)
    md, _, _ = NotesCommon.html_to_markdown(html)
    md
  end

  def verify(html)
    md, raw_html, _ = NotesCommon.html_to_markdown(html)
    NotesCommon.verify(raw_html, md)
  end

  # 1. Courier font (Apple Notes' code marking) should become inline <code> so
  #    pandoc writes backticks. Otherwise code lines starting with `#` are
  #    read as headings by the next markdown reader.
  def test_courier_becomes_inline_code
    html = '<div><font face="Courier"># Load DSL</font></div>'
    md = html2md(html)
    assert_match(/\\# Load DSL/, md)
    refute_match(/`/, md)
  end

  # 1c. URLs inside <font face="Courier"> should not be wrapped as markdown links —
  #     they are code text and should be kept as plain text inside the code block.
  def test_url_in_courier_not_autolinked
    html = '<div><font face="Courier">url = \'http://example.com/x\'</font></div>'
    md = html2md(html)
    refute_match(/\[http:\/\/example\.com\/x\]\(http:\/\/example\.com\/x\)/, md)
    assert_match(/http:\/\/example\.com\/x/, md)
  end

  # 1d. URLs inside <code>...</code> should not be wrapped as markdown links.
  def test_url_in_code_not_autolinked
    html = '<div><code>http://example.com/x</code></div>'
    md = html2md(html)
    refute_match(/\[http:\/\/example\.com\/x\]\(http:\/\/example\.com\/x\)/, md)
  end

  # 2. A manual `# text` written in Apple Notes (not a heading) should be escaped
  #    as `\# text` so it is not rendered as H1.
  def test_literal_hash_escaped
    html = "<div># 256GB minne</div>"
    assert_match(/^\\# 256GB minne/, html2md(html))
  end

  # 3. Apple Notes-internal C0 control characters (FS, GS, etc.) should be removed
  #    from the export — they are invisible in Notes and should not pollute markdown.
  def test_c0_control_chars_stripped
    html = "<div>før\u{001C}\u{001D}etter</div>"
    md = html2md(html)
    refute_match(/[\u{0000}-\u{0008}\u{000B}\u{000C}\u{000E}-\u{001F}]/, md)
  end

  # 4. Named entities that CGI.unescapeHTML does not cover (`&aring;`, `&oslash;`)
  #    should be decoded via the Nokogiri fallback.
  def test_named_entities_decoded
    html = "<div>p&amparing; ogs&amparing;</div>"
    md = html2md(html)
    refute_match(/&aring;/, md)
    assert_match(/på/, md)
    assert_match(/også/, md)
  end

  # 5. Encoded HTML tags in a <div> (code example) should be wrapped in <code>.

  # 6. URLs inside <font face="Courier"> or <code> are code text, not real
  #    links, and should not be flagged as "missing" in verify.
  def test_url_in_courier_not_flagged_missing
    html = '<font face="Courier">http://puma.example</font>'
    r = verify(html)
    assert_empty r[:missing_urls]
  end

  # 7. An indented numbered list should be stripped at line start with any
   #   leading whitespace, so strip_markdown and strip_html compare equally.
  def test_indented_numbered_list_strip_handles_leading_whitespace
    md = "    1.  første\n    2.  andre\n"
    stripped = NotesCommon.strip_markdown(md)
    refute_match(/\d+\./, stripped, "innrykket '1.' overlevde strip_markdown")
  end

  # 8. Pandoc 3.8.3+ eats `"` after `\` (the sequence `\"` becomes just `\`).
  #    Pre-processing should keep the quote — whether or not the backslash
  #    remains, `"` should survive the pandoc conversion.
  def test_backslash_quote_preserves_quote_through_pandoc
    html = '<div>han skrev \\"hei\\" til meg</div>'
    md = html2md(html)
    assert_match(/"hei"/, md, "quotes around 'hei' were lost in pandoc")
  end

  # 9. Empty <li> and the resulting empty <ul> should be removed — pandoc 3.8.3+
  #    renders an empty <ul> as "-" in markdown.
  def test_empty_nested_lists_removed
    html = '<div>tekst</div><ul><ul><li><br></li><li><br></li></ul></ul>'
    md = html2md(html)
    refute_match(/^-\s*$/, md, "tomme <li>/<ul> ga hengende '-'")
  end

  # 9a. Apple Notes sometimes closes <ul> in the middle of a sequence of <li>s.
  #     Empty <li>s that end up outside the ul context should also be stripped.
  def test_empty_li_outside_ul_removed
    html = '<ul><li>a</li></ul><li>b</li><li><br></li><li>c</li>'
    md = html2md(html)
    refute_match(/^-\s*$/, md, "tom <li> utenfor <ul> ga hengende '-'")
  end

  # 9b. Empty <li>s inside <ol> should NOT be stripped — they hold their place in
  #     the numbering (a user who skipped a number would otherwise lose the
  #     match between the following numbers and the original).
  def test_empty_li_in_ol_preserved
    html = '<ol><li>a</li><li> </li><li> </li><li>d</li></ol>'
    md = html2md(html)
    assert_match(/^4\.  ?d/, md, "empty <li> in <ol> was stripped — expected '4. d', got:\n#{md}")
  end

  # 9c. Items with content should be kept — whether they are in <ul>,
  #     outside <ul>, or among empty siblings. Makes sure the li stripping does
  #     not eat text.
  def test_nonempty_li_preserved_in_ul
    html = '<ul><li>første</li><li>andre</li><li>tredje</li></ul>'
    md = html2md(html)
    %w[første andre tredje].each { |w| assert_includes md, w, "lost '#{w}' in ul" }
  end

  def test_nonempty_li_preserved_outside_ul
    html = '<ul><li>a</li></ul><li>b</li><li>c</li>'
    md = html2md(html)
    %w[a b c].each { |w| assert_includes md, w, "mistet '#{w}' utenfor ul" }
  end

  def test_nonempty_li_preserved_among_empty_siblings
    html = '<ul><li><br></li><li>innhold</li><li> </li></ul>'
    md = html2md(html)
    assert_includes md, "innhold", "lost 'innhold' among empty siblings"
  end

  # 9d. An li with only formatted text (b/strong/font/span) should be kept — only
  #     completely empty lis should be removed.
  def test_li_with_formatted_text_preserved
    html = '<ul><li><b>fet</b></li><li><font face="X">tekst</font></li></ul>'
    md = html2md(html)
    assert_includes md, "fet"
    assert_includes md, "tekst"
  end

  # 9e. A nested ul with content should keep all levels.
  def test_nested_ul_content_preserved
    html = '<ul><li>ytre<ul><li>indre</li></ul></li></ul>'
    md = html2md(html)
    assert_includes md, "ytre"
    assert_includes md, "indre"
  end

  # 9f. A long <ol> with empty placeholders should keep both the content and the
  #     numbering for all non-empty elements.
  def test_long_ol_preserves_content_and_numbering
    html = '<ol><li>a</li><li> </li><li>c</li><li> </li><li>e</li></ol>'
    md = html2md(html)
    assert_match(/^1\.\s+a/, md)
    assert_match(/^3\.\s+c/, md)
    assert_match(/^5\.\s+e/, md)
  end

  # 10. `___` (three underscores) written literally in text should compare
  #     symmetrically — strip_html must remove it the same way as strip_markdown.
  def test_inline_underscores_symmetric
    html = '<div>etter ___ Rutine</div>'
    md, raw_html, _ = NotesCommon.html_to_markdown(html)
    assert NotesCommon.verify(raw_html, md)[:text_match]
  end

  # 11. Pandoc 3.8 loses `]` after `\` in markdown_strict. The ZWSP workaround
  #     should make sure `[\]` survives the conversion.
  def test_backslash_in_brackets_preserved
    html = '<div>tegn [\\] her</div>'
    md = html2md(html)
    assert_match(/\[\\\]/, md, "[\\] mistet ']' gjennom pandoc")
  end

  # 12. Apple Notes sometimes creates `<a href=(null)>...</a>` for empty url
  #     attachments. These should be removed so pandoc does not render `(null)` as text.
  def test_null_anchor_removed
    html = '<div>før<a href=(null) class="x">link</a>etter</div>'
    md = html2md(html)
    refute_match(/null/, md)
    refute_match(/link/, md)
  end

  # 13. Embedded base64 images (<img src="data:...">) should be removed — they are
  #     huge and pandoc renders them as ![](data:…), which pollutes the md file.
  def test_data_uri_images_removed
    html = '<div>før<img src="data:image/png;base64,iVBOR...">etter</div>'
    md = html2md(html)
    refute_match(/data:image/, md)
    refute_match(/base64/, md)
  end

  # 14. `<b><h1>title</h1></b>` should become a plain `# title` (bold wrapping around
  #     a heading is an Apple Notes artefact and must be removed).
  def test_bold_around_heading_flattened
    html = '<div><b><h1>Tittel</h1></b></div>'
    md = html2md(html)
    assert_match(/^# Tittel/, md)
    refute_match(/\*\*/, md)
  end

  # 15. Apple Notes often splits one heading over several <hN> tags.
  #     transform_html should merge them before pandoc.
  def test_split_heading_merged
    html = '<h1>Krav til</h1><h1>ventilasjon</h1>'
    md = html2md(html)
    assert_match(/^# Krav tilventilasjon/, md, "split heading was not merged")
  end

  # 15b. Headings should not have trailing whitespace after the text.
  #      Apple Notes can produce `<h1>Title </h1>`, which becomes `# Title ` —
  #      the trailing whitespace must be stripped so the markdown is clean.
  def test_heading_trailing_whitespace_stripped
    html = '<h1>Tittel </h1><div>brødtekst</div>'
    md = html2md(html)
    assert_match(/^# Tittel$/, md, "trailing whitespace after heading was not removed")
  end

  def test_heading_trailing_nbsp_stripped
    html = '<h1>Tittel&nbsp;</h1><div>x</div>'
    md = html2md(html)
    assert_match(/^# Tittel$/, md, "trailing &nbsp; after heading was not removed")
  end

  def test_heading_trailing_br_stripped
    html = '<h1>Tittel<br></h1><div>x</div>'
    md = html2md(html)
    assert_match(/^# Tittel$/, md, "trailing <br> after heading was not removed")
  end

  def test_heading_trailing_whitespace_stripped_all_levels
    html = '<h2>Nivå2&nbsp;</h2><h3>Nivå3<br></h3><div>x</div>'
    md = html2md(html)
    assert_match(/^## Nivå2$/, md)
    assert_match(/^### Nivå3$/, md)
  end

  # 16. <span style="..."> is used by Apple Notes for inline styling and should
  #     be removed without losing the content.
  def test_span_style_unwrapped
    html = '<div>tekst <span style="color:red">rød</span> mer</div>'
    md = html2md(html)
    assert_match(/tekst rød mer/, md)
    refute_match(/<span/, md)
  end

  # 17. <u>...</u> (underline) should be removed — markdown has no syntax
  #     for underline, but the content should be kept.
  def test_underline_unwrapped
    html = '<div>tekst <u>understreket</u> mer</div>'
    md = html2md(html)
    assert_match(/tekst understreket mer/, md)
  end

  # 18. </div><div> without <br> in between should give a line break, not joined
  #     text. Without the <br> conversion the result would be "linje1linje2".
  def test_consecutive_divs_get_linebreak
    html = '<div>linje1</div><div>linje2</div>'
    md = html2md(html)
    refute_match(/linje1linje2/, md)
  end

  # 19. Tables are flattened to line-separated content (Apple Notes tables
   #   render badly as markdown tables, so they are split into lines).
  def test_table_flattened_to_lines
    html = '<table><tr><td>celle1</td><td>celle2</td></tr></table>'
    md = html2md(html)
    assert_match(/celle1/, md)
    assert_match(/celle2/, md)
  end

  # 20. fix_entities adds ; after `&lt`/`&gt`/`&amp`/`&quot` without ;.
  def test_fix_entities_adds_semicolon
    fixed = NotesCommon.fix_entities('&ltfoo&gt og &amp og &quot')
    assert_equal '&lt;foo&gt; og &amp; og &quot;', fixed
  end

  # 21. A bare URL in colored/underlined text (without <a>) should be wrapped in <a>
  #     so pandoc creates a real markdown link (autolink or [text](url)).
  def test_bare_url_wrapped_in_anchor
    html = '<u><font color="red">https://example.com/foo</font></u>'
    md = html2md(html)
    # Pandoc can render it as <https://...> (autolink) or [url](url)
    assert_match(/<https:\/\/example\.com\/foo>|\[https:\/\/example\.com\/foo\]\(https:\/\/example\.com\/foo\)/, md)
  end

  # 23. safe_filename slugifies note titles safely for the file system.
  def test_safe_filename_basic
    assert_equal "tittel-på-notat", NotesCommon.safe_filename("Tittel på notat")
  end

  def test_safe_filename_strips_dangerous_chars
    assert_equal "navn", NotesCommon.safe_filename('na/vn:*?"<>|#[](),')
    refute_match(/[\/\\:*?"<>|#\[\]\(\),]/, NotesCommon.safe_filename('a/b\\c:d*e?f"g<h>i|j#k[l]m(n)o,p'))
  end

  def test_safe_filename_collapses_whitespace_and_dashes
    assert_equal "a-b-c", NotesCommon.safe_filename("a   b---c")
    assert_equal "a-b", NotesCommon.safe_filename("a -- b")
  end

  def test_safe_filename_lowercase
    assert_equal "abc", NotesCommon.safe_filename("ABC")
    assert_equal "norsk-tegn-æøå", NotesCommon.safe_filename("Norsk Tegn ÆØÅ")
  end

  def test_safe_filename_truncates_skjermbilde_suffix
    assert_equal "skjermbilde-2024-03-15",
      NotesCommon.safe_filename("Skjermbilde 2024-03-15 kl. 14.30.45")
  end

  # safe_note_filename keeps spaces between words (used for md filenames).
  def test_safe_filename_strips_leading_dots
    assert_equal "skjult", NotesCommon.safe_filename(".skjult")
    assert_equal "skjult-mappe", NotesCommon.safe_filename("... skjult mappe")
    assert_equal "a.b", NotesCommon.safe_filename("a.b")
  end

  def test_safe_note_filename_strips_leading_dots
    assert_equal "tittel", NotesCommon.safe_note_filename(".tittel")
    assert_equal "tittel her", NotesCommon.safe_note_filename(". . tittel her")
    assert_equal "a.b", NotesCommon.safe_note_filename("a.b")
  end

  def test_safe_note_filename_keeps_spaces
    assert_equal "tittel på notat", NotesCommon.safe_note_filename("Tittel på notat")
  end

  def test_safe_note_filename_strips_dangerous_chars
    assert_equal "navn", NotesCommon.safe_note_filename('na/vn:*?"<>|#[](),')
  end

  def test_safe_note_filename_collapses_whitespace_only
    assert_equal "a b c", NotesCommon.safe_note_filename("a   b   c")
  end

  def test_safe_note_filename_preserves_internal_dashes
    assert_equal "a-b c-d", NotesCommon.safe_note_filename("a-b c-d")
  end

  def test_safe_note_filename_lowercase
    assert_equal "norsk tegn æøå", NotesCommon.safe_note_filename("Norsk Tegn ÆØÅ")
  end

  def test_safe_note_filename_truncates_skjermbilde_suffix
    assert_equal "skjermbilde 2024-03-15",
      NotesCommon.safe_note_filename("Skjermbilde 2024-03-15 kl. 14.30.45")
  end

  # R3: … is removed from note names
  def test_safe_note_filename_strips_ellipsis
    assert_equal "notat med slutt", NotesCommon.safe_note_filename("Notat med slutt…")
    assert_equal "a b", NotesCommon.safe_note_filename("a… b")
  end

  # note_basename: filename without .md for a new md file from title and created_at
  def b(title, created = "2025-01-02"); NotesCommon.note_basename(title, created); end

  def test_note_basename_plain_title_gets_created_at
    assert_equal "2025-01-02 handleliste", b("Handleliste")
  end

  # R1: a title that is only a date
  def test_note_basename_numeric_date_same_as_created
    assert_equal "2025-01-02", b("02.01.2025")
  end

  def test_note_basename_title_date_wins_over_created
    assert_equal "2025-01-03", b("03.01.2025")
  end

  def test_note_basename_numeric_date_with_slash_dash_and_single_digits
    assert_equal "2025-01-03", b("3/1/2025")
    assert_equal "2025-01-03", b("03-01-2025")
  end

  def test_note_basename_norwegian_text_date
    assert_equal "2025-01-02", b("2. januar 2025")
    assert_equal "2025-01-02", b("2. Januar 2025")
    assert_equal "2025-03-05", b("5 mars 2025")
  end

  def test_note_basename_iso_date_in_title
    assert_equal "2025-01-02 møte", b("2025-01-02 møte", "2025-01-05")
  end

  # R1: a title starting with a date, the rest is kept
  def test_note_basename_date_then_rest
    assert_equal "2025-02-04 💤", b("04.02.2025 💤", "2025-02-04")
  end

  def test_note_basename_weekday_before_date_kept_after_date
    assert_equal "2018-05-01 onsdag møte", b("Onsdag 1. mai 2018 møte", "2018-04-30")
    assert_equal "2018-05-01 onsdag", b("onsdag 1. mai 2018", "2018-04-30")
  end

  def test_note_basename_weekday_without_date_is_plain_title
    assert_equal "2025-01-02 mandag møte", b("Mandag møte")
  end

  # R2: a placeholder title gives only the date
  def test_note_basename_placeholder_titles
    assert_equal "2018-02-22", b("untitled", "2018-02-22")
    assert_equal "2018-02-22", b("Untitled snapshot 2", "2018-02-22")
    assert_equal "2018-02-22", b("untitled text note", "2018-02-22")
    assert_equal "2018-02-22", b("Notat 35", "2018-02-22")
    assert_equal "2018-02-22", b("2 notat", "2018-02-22")
  end

  def test_note_basename_placeholder_after_date
    assert_equal "2025-01-02", b("02.01.2025 notat")
  end

  def test_note_basename_placeholder_word_inside_title_kept
    assert_equal "2025-01-02 notat om bil", b("Notat om bil")
  end

  # R3 in the name
  def test_note_basename_strips_ellipsis
    assert_equal "2025-01-02 venter", b("Venter…")
  end

  # Not a date: stays as it is
  def test_note_basename_invalid_date_kept
    assert_equal "2025-01-02 31.02.2025 x", b("31.02.2025 x")
  end

  def test_note_basename_date_without_year_kept
    assert_equal "2024-04-28 1. mai tekst", b("1. mai tekst", "2024-04-28")
  end

  def test_note_basename_date_glued_to_text_kept
    assert_equal "2025-01-02 02.01.2025abc", b("02.01.2025abc")
  end

  # 25. core_data_to_local_date converts Apple Notes timestamps faithfully,
  #     in the time zone from TZ. The tests set TZ=Europe/Oslo.
  def with_oslo_tz
    saved = ENV["TZ"]
    ENV["TZ"] = "Europe/Oslo"
    yield
  ensure
    ENV["TZ"] = saved
  end

  # Core Data epoch 2001-01-01 00:00:00 UTC = 2001-01-01 01:00:00 Oslo (CET)
  def test_cd_epoch_is_jan_1_2001_oslo
    with_oslo_tz do
      assert_equal "2001-01-01", NotesCommon.core_data_to_local_date(0)
    end
  end

  # 23:30 UTC 31 December = 00:30 Oslo 1 January — the date should be 1 Jan
  def test_cd_late_dec_utc_becomes_jan_oslo
    with_oslo_tz do
      # 2024-12-31 23:30 UTC = 757373400 sec since the CD epoch
      cd = Time.utc(2024, 12, 31, 23, 30, 0).to_i - 978307200
      assert_equal "2025-01-01", NotesCommon.core_data_to_local_date(cd)
    end
  end

  # 00:30 UTC 1 January (winter) = 01:30 Oslo (CET) — the date is still 1 Jan
  def test_cd_early_jan_utc_stays_jan_oslo
    with_oslo_tz do
      cd = Time.utc(2025, 1, 1, 0, 30, 0).to_i - 978307200
      assert_equal "2025-01-01", NotesCommon.core_data_to_local_date(cd)
    end
  end

  # DST change: 30 March 2025 22:30 UTC = 00:30 Oslo 31 March (CEST, +02)
  def test_cd_summer_time_offset
    with_oslo_tz do
      cd = Time.utc(2025, 3, 30, 22, 30, 0).to_i - 978307200
      assert_equal "2025-03-31", NotesCommon.core_data_to_local_date(cd)
    end
  end

  # Winter (CET, +01): 22:30 UTC = 23:30 Oslo, still the same day
  def test_cd_winter_time_offset
    with_oslo_tz do
      cd = Time.utc(2025, 1, 15, 22, 30, 0).to_i - 978307200
      assert_equal "2025-01-15", NotesCommon.core_data_to_local_date(cd)
    end
  end

  # 23:30 UTC in summer: should follow the Oslo date, not UTC
  def test_cd_late_evening_utc_summer
    with_oslo_tz do
      # 2025-06-15 23:30 UTC = 01:30 Oslo 16 June (CEST)
      cd = Time.utc(2025, 6, 15, 23, 30, 0).to_i - 978307200
      assert_equal "2025-06-16", NotesCommon.core_data_to_local_date(cd)
    end
  end

  # Float input (Apple Notes stores it as REAL in SQLite)
  def test_cd_accepts_float
    with_oslo_tz do
      cd_float = (Time.utc(2024, 3, 15, 12, 0, 0).to_i - 978307200).to_f + 0.5
      assert_equal "2024-03-15", NotesCommon.core_data_to_local_date(cd_float)
    end
  end

  # The date follows TZ: the same moment gives 31 Dec in UTC and 1 Jan in Oslo.
  def test_cd_oslo_overrides_utc_server_tz
    saved = ENV["TZ"]
    ENV["TZ"] = "UTC"
    cd = Time.utc(2024, 12, 31, 23, 30, 0).to_i - 978307200
    iso_utc = NotesCommon.core_data_to_local_date(cd)
    ENV["TZ"] = "Europe/Oslo"
    iso_oslo = NotesCommon.core_data_to_local_date(cd)
    assert_equal "2024-12-31", iso_utc, "with TZ=UTC the date should be 31 Dec"
    assert_equal "2025-01-01", iso_oslo, "with TZ=Oslo the date should be 1 Jan"
  ensure
    ENV["TZ"] = saved
  end

  # 26. Pandoc writes `1.  text` (two spaces) in ordered lists, but
  #     html_to_markdown normalizes it to `1. text` (one space).
  def test_ordered_list_double_space_normalized
    html = '<ol><li>første</li><li>andre</li></ol>'
    md = html2md(html)
    refute_match(/^\d+\.  /, md, "ordered list has a double space")
    assert_match(/^1\. første/, md)
  end

  # 27. Three or more blank lines collapse to two (one empty line).
  def test_excessive_blank_lines_collapsed
    html = '<div>linje1</div><div><br></div><div><br></div><div><br></div><div>linje2</div>'
    md = html2md(html)
    refute_match(/\n{3,}/, md, "three or more newlines still in the output")
  end

  def test_empty_div_with_self_closing_br_keeps_blank_line
    assert_equal "a\n\nb", html2md('<div>a</div><div><br/></div><div>b</div>')
    assert_equal "a\n\nb", html2md('<div>a</div><div><br /></div><div>b</div>')
  end

  # 28. <s>/<strike>/<del> are kept as markdown ~~...~~ (pandoc +strikeout).
  def test_strikethrough_s_tag_becomes_tilde
    html = '<div>før <s>fjernet</s> etter</div>'
    md = html2md(html)
    assert_match(/~~fjernet~~/, md)
  end

  def test_strikethrough_strike_tag_becomes_tilde
    html = '<div>før <strike>fjernet</strike> etter</div>'
    md = html2md(html)
    assert_match(/~~fjernet~~/, md)
  end

  def test_strikethrough_del_tag_becomes_tilde
    html = '<div>før <del>fjernet</del> etter</div>'
    md = html2md(html)
    assert_match(/~~fjernet~~/, md)
  end

  # A book list where each line is wrapped in <strike> (finished tasks).
  # The strikethrough should be kept as ~~...~~ on each line, not lost.
  def test_strikethrough_on_consecutive_list_lines
    html = '<div><strike>linje en</strike></div>' \
           '<div><strike>linje to</strike></div>'
    md = html2md(html)
    assert_match(/~~linje en~~/, md)
    assert_match(/~~linje to~~/, md)
  end

  # An empty <strike> (only <br>/whitespace) should not produce ~~~~ in markdown.
  def test_empty_strikethrough_br_dropped
    html = '<div>linje1 <strike><br></strike></div><div>linje2</div>'
    md = html2md(html)
    refute_match(/~~/, md, "an empty strike should not give ~~ in the output")
  end

  def test_empty_strikethrough_whitespace_dropped
    html = '<div>x <strike>   </strike> y</div>'
    md = html2md(html)
    refute_match(/~~/, md)
  end

  def test_empty_s_tag_dropped
    html = '<div>a <s></s> b</div>'
    md = html2md(html)
    refute_match(/~~/, md)
  end

  def test_empty_del_tag_dropped
    html = '<div>a <del><br></del> b</div>'
    md = html2md(html)
    refute_match(/~~/, md)
  end

  # Empty bold lines in Notes should not give `****` in markdown, not even when
  # they follow each other (merged into <b><br><br></b>) or have
  # <font>/<span> around <br>.
  def test_adjacent_empty_bold_lines_dropped
    html = "<div><h1>Bibel </h1><b><h1>Juni</h1></b></div>\n<div><b><br></b><b><br></b></div>\n<div><br></div>\n<div><h2>Lese</h2></div>\n"
    assert_equal "# Bibel Juni\n\n## Lese", html2md(html)
  end

  # NOTES_BOLD_LINE_AS_HEADING=1: a line that is only bold text becomes a ## heading.
  def with_bold_headings
    ENV["NOTES_BOLD_LINE_AS_HEADING"] = "1"
    yield
  ensure
    ENV.delete("NOTES_BOLD_LINE_AS_HEADING")
  end

  def test_no_blank_line_after_heading
    assert_equal "## Under\ntekst", html2md("<h2>Under</h2><div><br></div><div>tekst</div>")
  end

  def test_no_blank_line_after_h3
    assert_equal "## A\n\n### Under\ntekst", html2md("<h2>A</h2><h3>Under</h3><div><br></div><div>tekst</div>")
  end

  # Ufravikelig: tom linje foran enhver overskrift, # til ######, uansett hva
  # som står foran.
  HEADING_LINE = /\A {0,3}\#{1,6}(\s|\z)/
  BEFORE_HEADING = ["<div>tekst</div>", "<ul><li>a</li></ul>", "<ol><li>a</li></ol>",
                    "<table><tr><td>x</td></tr></table>", "<div><b>fet</b></div>",
                    "<div>&nbsp;</div>", "<div>⁠</div>", "<blockquote>sitat</blockquote>",
                    "<pre>kode</pre>", *(1..6).map { |n| "<h#{n}>Forrige</h#{n}>" }]

  def assert_blank_line_before_every_heading(md)
    lines = md.split("\n", -1)
    lines.each_with_index do |line, i|
      next unless i > 0 && line.match?(HEADING_LINE)
      assert_equal "", lines[i - 1], "no blank line before line #{i + 1}: #{md.inspect}"
    end
  end

  def test_blank_line_before_every_heading_all_levels
    (1..6).each do |n|
      BEFORE_HEADING.each do |before|
        md = html2md("#{before}<h#{n}>Tittel</h#{n}><div>etter</div>")
        assert_includes md, "Tittel"
        assert_blank_line_before_every_heading(md)
      end
    end
  end

  def test_blank_line_before_bold_line_heading
    ENV["NOTES_BOLD_LINE_AS_HEADING"] = "1"
    BEFORE_HEADING.each do |before|
      assert_blank_line_before_every_heading(html2md("#{before}<div><b>Fet tittel</b></div><div>etter</div>"))
    end
  ensure
    ENV.delete("NOTES_BOLD_LINE_AS_HEADING")
  end

  def test_one_blank_line_before_heading
    assert_equal "tekst\n\n## A\nmer", html2md("<div>tekst</div><div><br></div><div><br></div><h2>A</h2><div>mer</div>")
  end

  def test_no_blank_line_after_heading_before_heading
    assert_equal "## A\n\n## B\ntekst", html2md("<h2>A</h2><div><br></div><h2>B</h2><div>tekst</div>")
  end

  def test_no_invisible_line_after_heading
    assert_equal "## A\ntekst", html2md("<h2>A</h2><div>\u00A0</div><div>tekst</div>")
  end

  def test_invisible_line_before_heading
    assert_equal "a\n\n## B\nc", html2md("<div>a</div><div>&nbsp;</div><h2>B</h2><div>c</div>")
    assert_equal "a\n\n## B", html2md("<div>a</div><div>\u200D</div><h2>B</h2>")
    assert_equal "a\n\n# B\n\nc", html2md("<div>a</div><div>&nbsp;</div><div>&nbsp;</div><h1>B</h1><div>c</div>")
  end

  def test_invisible_line_after_h1
    assert_equal "# B\n\nc", html2md("<h1>B</h1><div>&nbsp;</div><div>c</div>")
    assert_equal "# A\n\n## B", html2md("<h1>A</h1><div>&nbsp;</div><h2>B</h2>")
  end

  def test_h1_right_before_h2
    assert_equal "# A\n\n## B\nc", html2md("<h1>A</h1><h2>B</h2><div>c</div>")
  end

  def test_h2_right_before_h1
    assert_equal "## A\n\n# B", html2md("<h2>A</h2><h1>B</h1>")
  end

  def test_word_joiner_line_after_heading
    assert_equal "## A\ntekst", html2md("<h2>A</h2><div>\u2060</div><div>tekst</div>")
  end

  def test_invisible_lines_at_start_and_end
    assert_equal "## Under", html2md("<div>tekst</div><h2>Under</h2><div>&nbsp;</div>").sub("tekst\n\n", "")
    assert_equal "## A\nb", html2md("<div>&nbsp;</div><h2>A</h2><div>b</div>")
  end

  def test_always_blank_line_after_h1
    assert_equal "# Tittel\n\ntekst", html2md("<h1>Tittel</h1><div>tekst</div>")
  end

  def test_bold_line_stays_bold_by_default
    assert_equal "**Det er noe her**\ntekst", html2md("<div><b>Det er noe her</b></div><div>tekst</div>")
  end

  def test_bold_line_becomes_heading_with_bold_headings
    with_bold_headings do
      assert_equal "## Det er noe her\ntekst", html2md("<div><b>Det er noe her</b></div><div>tekst</div>")
    end
  end

  def test_bold_headings_leaves_partly_bold_line
    with_bold_headings do
      assert_equal "**Navn:** Ola", html2md("<div><b>Navn:</b> Ola</div>")
    end
  end

  def test_bold_headings_leaves_bold_list_item
    with_bold_headings do
      assert_match(/\A-\s+\*\*Melk\*\*\z/, html2md("<ul><li><b>Melk</b></li></ul>"))
    end
  end

  def test_bold_headings_keeps_h3_to_h2_rule_unchanged
    with_bold_headings do
      assert_equal "# Tittel\n\n## Under\n\n## Fet", html2md("<h1>Tittel</h1><h3>Under</h3><div><b>Fet</b></div>")
    end
  end

  def test_adjacent_empty_italic_lines_dropped
    assert_equal "a\n\nb", html2md('<div>a</div><div><i><br></i><i><br></i></div><div>b</div>')
  end

  def test_empty_bold_with_font_dropped
    assert_equal "a\n\nb", html2md('<div>a</div><div><b><font color="#000000"><br></font></b></div><div>b</div>')
  end

  def test_empty_bold_with_span_dropped
    assert_equal "a\n\nb", html2md('<div>a</div><div><b><span style="font-size: 14px"><br></span></b></div><div>b</div>')
  end

  def test_empty_bold_with_italic_dropped
    assert_equal "a\n\nb", html2md('<div>a</div><div><b><i><br></i></b></div><div>b</div>')
  end

  def test_empty_bold_with_self_closing_br_dropped
    refute_match(/\*\*/, html2md('<div>a</div><div><b><br/></b></div><div>b</div>'))
  end

  def test_empty_bold_with_font_and_span_dropped
    assert_equal "a\n\nb", html2md('<div>a</div><div><b><font color="#000000"><span style="font-size: 14px"><br></span></font></b></div><div>b</div>')
  end

  # The md files are the source of truth and may be edited: the attachment
  # section may have no blank line in front.
  def test_verify_ignores_attachment_section_without_blank_line
    md = "---\nnote_id: x\n---\n\nHei\n## Attachments\n\n![x.png](assets/x.png)\n"
    assert NotesCommon.verify("<div>Hei</div>", md)[:text_match]
  end

  def test_verify_ignores_norwegian_attachment_section
    md = "---\nnote_id: x\n---\n\nHei\n\n## Vedlegg\n![x.png](assets/x.png)\n"
    assert NotesCommon.verify("<div>Hei</div>", md)[:text_match]
  end

  # Code pasted from the web has its word breaks in separate <font>/<span>.
  def test_space_only_font_keeps_word_separator
    f = ->(t) { %(<font face="CourierNewPSMT" color="#333333"><span style="font-size: 14px">#{t}</span></font>) }
    assert_equal "if @client.save", html2md("<div>#{f.('if')}#{f.(' ')}#{f.('@client')}#{f.('.save')}</div>")
  end

  def test_space_only_bold_font_keeps_word_separator
    assert_equal "ord ord", html2md('<div>ord<b><font color="#000000"> </font></b>ord</div>')
  end

  # 29. Heading promotion: if the file has h1 and h3 but no h2, h3 is
  #     promoted to h2 so the hierarchy is continuous.
  def test_heading_h3_promoted_to_h2_when_h2_missing
    html = '<h1>Tittel</h1><h3>Underseksjon</h3>'
    md = html2md(html)
    assert_match(/^# Tittel/, md)
    assert_match(/^## Underseksjon/, md)
    refute_match(/^### Underseksjon/, md)
  end

  def test_heading_h3_kept_when_h2_present
    html = '<h1>Tittel</h1><h2>Seksjon</h2><h3>Underseksjon</h3>'
    md = html2md(html)
    assert_match(/^### Underseksjon/, md)
  end

  # 30. Markdown autolink syntax `<https://...>` should compare equal
  #     to a plain URL in strip_markdown.
  def test_autolink_in_markdown_stripped
    md = '<https://example.com/x>'
    assert_match(/https:\/\/example\.com\/x/, NotesCommon.strip_markdown(md))
    refute_match(/^</, NotesCommon.strip_markdown(md))
  end

  # 31. Markdown links `[text](url)` are reduced to the link text in strip.
  def test_markdown_link_reduces_to_text_in_strip
    md = "Klikk [her](https://x.com) for mer"
    out = NotesCommon.normalize(NotesCommon.strip_markdown(md))
    assert_equal "Klikk her for mer", out
  end

  # 32. The quote prefix `> ` is stripped at line start.
  def test_quote_marker_stripped
    md = "> Sitert tekst"
    out = NotesCommon.normalize(NotesCommon.strip_markdown(md))
    assert_equal "Sitert tekst", out
  end

  # 33. A code fence ```line at line start is stripped.
  def test_code_fence_stripped
    md = "```ruby\nkode\n```"
    out = NotesCommon.strip_markdown(md)
    refute_match(/^```/, out)
    assert_match(/kode/, out)
  end

  # 34. broken_refs flags internal references if the file does not exist on disk.
  def test_broken_refs_flagged_with_export_dir
    Dir.mktmpdir do |dir|
      md = "Se [bilde](assets/finnes-ikke.png)."
      result = NotesCommon.verify("<div>Se bilde.</div>", md, export_dir: dir)
      refute_empty result[:broken_refs]
      assert_includes result[:broken_refs], "assets/finnes-ikke.png"
    end
  end

  def test_broken_refs_passes_when_file_exists
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p File.join(dir, "assets")
      File.write(File.join(dir, "assets/finnes.png"), "x")
      md = "Se [bilde](assets/finnes.png)."
      result = NotesCommon.verify("<div>Se bilde.</div>", md, export_dir: dir)
      assert_empty result[:broken_refs]
    end
  end

  def test_broken_refs_skipped_without_export_dir
    md = "Se [bilde](assets/finnes-ikke.png)."
    result = NotesCommon.verify("<div>Se bilde.</div>", md)
    assert_empty result[:broken_refs]
  end

  # 35. The URL trim removes trailing entities that survive Nokogiri parsing.
  def test_url_trim_removes_trailing_entities
    html = '<div>Sjekk <a href="https://example.com/x">https://example.com/x</a>&quot;</div>'
    _, raw, _ = NotesCommon.html_to_markdown(html)
    md_with_url = "Sjekk [https://example.com/x](https://example.com/x)"
    r = NotesCommon.verify(raw, md_with_url)
    assert_empty r[:missing_urls], "URL trim failed: #{r[:missing_urls]}"
  end

  # Parentheses inside a URL are part of it, both bare and as link target.
  def test_url_with_parentheses_not_flagged_missing
    url = "http://example.no/(abc123)/generator.aspx?PID=1&amp;M=0"
    wiki = "https://no.wikipedia.org/wiki/Merkur_(planet)"
    ["<div>#{url}</div>", %Q{<div><a href="#{url}">lenke</a></div>},
     "<div>#{wiki}</div>", %Q{<div><a href="#{wiki}">Merkur</a> og mer</div>},
     "<div>(se #{wiki})</div>"].each do |html|
      md, raw, _ = NotesCommon.html_to_markdown(html)
      assert_empty NotesCommon.verify(raw, md)[:missing_urls], md
    end
  end

  # A bare URL keeps a closing ) that belongs to it, and drops one that does not.
  def test_bare_url_keeps_balanced_parenthesis
    wiki = "https://no.wikipedia.org/wiki/Merkur_(planet)"
    assert_equal "<#{wiki}>", html2md("<div>#{wiki}</div>")
    assert_equal "(se <#{wiki}>)", html2md("<div>(se #{wiki})</div>")
    assert_equal "(se <https://x.no>)", html2md("<div>(se https://x.no)</div>")
  end

  # A URL that really is missing from md is still reported.
  def test_url_with_parentheses_missing_is_flagged
    _, raw, _ = NotesCommon.html_to_markdown("<div>http://example.no/(abc)/side</div>")
    assert_equal ["http://example.no/(abc)/side"], NotesCommon.verify(raw, "http://example.no/(abc)")[:missing_urls]
  end

  # 36. URLs inside <code>...</code> are excluded from the missing check.
  def test_url_in_code_block_not_flagged_missing
    html = '<code>http://localhost:3000</code>'
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_empty r[:missing_urls]
  end

  # Apple Notes often splits one heading over several <hN> tags at the same
  # level. transform_html should merge them before pandoc, otherwise the result
  # is fragmented headings ("K", "rav", "til venti", "lasjon" → "Krav til
  # ventilasjon").
  def test_consecutive_same_level_headings_merge
    html = '<h1>K</h1><h1>rav </h1><h1>til venti</h1><h1>lasjon</h1>'
    merged = NotesCommon.transform_html(html)
    refute_match(%r{</h1>\s*<h1>}, merged, "adjacent h1s should be merged")

    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    assert_match(/^# Krav til ventilasjon\s*$/, md)
  end

  # Web clips often store <li> with only whitespace/tabs as visual padding.
  # Pandoc renders these as empty "-" markers in markdown, while
  # strip_html sees them as empty — the pipeline diverges. transform_html
  # should remove them.
  def test_whitespace_only_li_stripped_from_ul
    html = "<ul><li>Ekte</li><li>\t\t</li><li>Annen</li></ul>"
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    refute_match(/^-\s*$/, md, "empty list marker in markdown")
  end

  # Apple Notes wraps empty web clip lines in <font>/<span> around <br>.
  # After the span/font stripping the <li> is really empty and must be removed —
  # this needs iterative stripping because the first pass leaves tags behind.
  def test_li_with_only_font_wrapped_br_stripped
    html = '<ul><li>Reell</li><li><font face="A"><span>		</span></font><font face="B"><span><br></span></font></li></ul>'
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    refute_match(/^-\s*$/, md, "empty list marker in markdown")
  end

  # Apple Notes often styles links as colored text in <font>/<u> without <a>.
  # When the URL comes right before a non-URL character like a typographic quote,
  # pandoc does not auto-detect the link — markdown gets "http://...”" as plain
  # text, while verify() sees "http://..." on the HTML side, and they diverge.
  # The URL wrap pass wraps the URL in <a href> before pandoc sees it.
  def test_bare_url_before_typographic_quote_gets_wrapped
    html = '<div>tekst <u><font color="#E4AF0A">http://example.com/subscribe</font></u><font>”</font> etter</div>'
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    assert_empty r[:missing_urls]
  end

  # Users sometimes write `# Skjerm` as tag-like text (not a heading).
  # The pipeline must make sure `#` at line start is escaped so pandoc/markdown
  # does not turn it into a heading.
  def test_manual_hash_text_not_treated_as_heading
    html = '<div># Skjerm</div><div># Fingeravtrykkleser</div>'
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    refute_match(/^#\s/, md, "a raw # at line start would become a heading")
    assert_match(/\\# Skjerm/, md)
  end

  # Apple Notes stores invisible C0 control characters (FS, GS, RS, US) as internal
  # separators. They have no visible form but pollute markdown and diverge
  # from the stripped HTML text. The pipeline should remove them.
  def test_c0_control_chars_stripped_from_markdown
    html = "<div>før\u{001C}etter\u{001D}slutt</div>"
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    refute_match(/[\u{001C}\u{001D}\u{001E}\u{001F}]/, md, "C0 control characters still in markdown")
  end

  # Named entities like `&aring;` are not decoded by CGI.unescapeHTML alone.
  # The pipeline uses Nokogiri on entity tokens to decode them to the right
  # Unicode character ("å"), otherwise they remain as raw entity text.
  def test_named_html_entity_decoded_to_unicode
    html = '<div>p&aring; gata</div>'
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    assert_includes md, "på"
    refute_match(/&aring;/, md, "the named entity should be decoded")
  end

  # Code examples in Apple Notes are stored with encoded tags (`&lt;script&gt;`).
  # Pandoc decodes them to real HTML and autolinks URLs inside — breaking the
  # example. transform_html wraps such <div>s in <code> so they are kept
  # as inline code, and URLs inside are not flagged as missing.
  def test_encoded_html_tag_preserved_as_code
    html = '<div>&lt;script src=&quot;https://example.com/x.js&quot;&gt;&lt;/script&gt;</div>'
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    assert_empty r[:missing_urls]
    assert_match(/`<script[^`]*<\/script>`/, md, "the encoded tag should be kept as inline code")
  end

  # Empty <li>s are stripped to avoid "- - -" noise in markdown, but in an <ol>
  # they hold their place in the numbering. The strip rule must mask ol blocks
  # before it runs, so "1. ... 2. ... 3. ..." is kept when no. 2 is empty.
  def test_empty_li_in_ol_preserves_numbering
    html = '<ol><li>første</li><li></li><li>tredje</li></ol>'
    md, raw, _ = NotesCommon.html_to_markdown(html)
    r = NotesCommon.verify(raw, md)
    assert_equal "pass", r[:status]
    assert_match(/^1\. første/, md)
    assert_match(/^2\.\s*$/, md, "an empty second element should keep its number")
    assert_match(/^3\. tredje/, md)
  end
end


# === From notes_refresh_all_test.rb ===
# --- Unit tests for the refresh-all helper functions ----------------------

class RefreshCompareTest < Minitest::Test
  def fm(body: "innhold")
    "---\ncreated_at: 2024-03-15\nfolder: claude\n---\n\n#{body}\n"
  end

  def test_identical_files_are_identical
    a = fm
    b = fm
    assert_equal :identical, NotesCommon.refresh_compare(a, b)
  end

  def test_body_difference_is_differ
    a = fm(body: "gammelt")
    b = fm(body: "nytt")
    assert_equal :differ, NotesCommon.refresh_compare(a, b)
  end

  def test_other_frontmatter_difference_is_differ
    a = fm.sub("folder: claude", "folder: claude\ntag: [a]")
    b = fm
    assert_equal :differ, NotesCommon.refresh_compare(a, b)
  end
end

class WriteAtomicTest < Minitest::Test
  def test_writes_content
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fil.md")
      NotesCommon.write_atomic(path, "innhold")
      assert_equal "innhold", File.read(path)
    end
  end

  def test_overwrites_existing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fil.md")
      File.write(path, "gammelt")
      NotesCommon.write_atomic(path, "nytt")
      assert_equal "nytt", File.read(path)
    end
  end

  def test_no_tmp_file_left_behind
    Dir.mktmpdir do |dir|
      path = File.join(dir, "fil.md")
      NotesCommon.write_atomic(path, "innhold")
      tmps = Dir.glob(File.join(dir, "*.tmp.*"))
      assert_empty tmps, "tmp file was left behind: #{tmps}"
    end
  end
end

class FrontmatterTest < Minitest::Test
  def fm(text)
    NotesCommon.frontmatter(text)
  end

  def test_reads_fields
    assert_equal({ "created_at" => "2024-03-15", "export" => "pass" }, fm("---\ncreated_at: 2024-03-15\nexport: pass\n---\n\nbody\n"))
  end

  def test_strips_quotes_and_whitespace
    assert_equal({ "note_id" => "abc", "a" => "x" }, fm("---\nnote_id: \"abc\"\na:   x  \n---\n"))
  end

  def test_empty_value
    assert_equal({ "hint" => "" }, fm("---\nhint: \n---\n"))
  end

  def test_key_with_norwegian_letters_and_digits
    assert_equal({ "møtes" => "3", "v2" => "ja" }, fm("---\nmøtes: 3\nv2: ja\n---\n"))
  end

  def test_inline_list_kept_as_text
    assert_equal "[mat, reexport]", fm("---\ntag: [mat, reexport]\n---\n")["tag"]
  end

  def test_ignores_body
    assert_equal({ "a" => "1" }, fm("---\na: 1\n---\n\nexport: pass i body\n"))
  end

  def test_without_frontmatter_is_empty
    assert_equal({}, fm("note_id: abc\n"))
  end

  def test_unclosed_frontmatter_is_empty
    assert_equal({}, fm("---\nnote_id: abc\n"))
  end
end

# --- Checkboxes from NoteStore (formerly notes_box) ---------------------

class CheckboxTest < Minitest::Test
  FM = "---\ncreated_at: 2024-01-01\nnote_id: x\n---\n\n"

  # Returns [body after frontmatter, problems].
  def box(items, body, alt = {})
    text, problems = NotesCommon.apply_checkboxes(FM + body, Proto.zdata(items), ->(id) { alt[id] })
    [text.delete_prefix(FM), problems.join("\n")]
  end

  def test_sets_checked_and_unchecked
    body, _ = box([["Handleliste", :plain], ["Melk", :done], ["Brød", :check]], "Handleliste\n\n-   Melk\n-   Brød\n")
    assert_equal "Handleliste\n\n- [x] Melk\n- [ ] Brød\n", body
  end

  def test_frontmatter_untouched
    text, _ = NotesCommon.apply_checkboxes(FM + "- Melk\n", Proto.zdata([["Melk", :done]]), ->(_) {})
    assert text.start_with?(FM)
  end

  def test_keeps_indentation
    body, _ = box([["Topp", :check], ["Under", :done]], "-   Topp\n    -   Under\n")
    assert_equal "- [ ] Topp\n    - [x] Under\n", body
  end

  def test_already_correct_is_unchanged
    body, problems = box([["Melk", :done]], "- [x] Melk\n")
    assert_equal "- [x] Melk\n", body
    assert_equal "", problems
  end

  def test_wrong_box_is_corrected
    body, _ = box([["Melk", :check], ["Brød", :done]], "- [x] Melk\n- [ ] Brød\n")
    assert_equal "- [ ] Melk\n- [x] Brød\n", body
  end

  def test_note_without_checklist_is_unchanged
    body, problems = box([["Tittel", :plain], ["punkt", :dash]], "Tittel\n\n- punkt\n")
    assert_equal "Tittel\n\n- punkt\n", body
    assert_equal "", problems
  end

  def test_dash_list_items_stay_plain
    body, _ = box([["Melk", :done], ["vanlig", :dash]], "- Melk\n- vanlig\n")
    assert_equal "- [x] Melk\n- vanlig\n", body
  end

  def test_item_not_in_md_is_reported_rest_fixed
    body, problems = box([["Melk", :done], ["Egg", :check]], "- Melk\n- Smør\n")
    assert_equal "- [x] Melk\n- Smør\n", body
    assert_includes problems, "not found in md: Egg"
  end

  def test_item_as_plain_paragraph_is_not_matched
    body, problems = box([["Melk", :done]], "Melk\n")
    assert_equal "Melk\n", body
    assert_match(/not found/i, problems)
  end

  def test_duplicate_texts_matched_in_order
    body, _ = box([["Melk", :done], ["Melk", :check]], "- Melk\n- Melk\n")
    assert_equal "- [x] Melk\n- [ ] Melk\n", body
  end

  def test_reordered_items_still_found
    body, _ = box([["Melk", :done], ["Brød", :check]], "- Brød\n- Melk\n")
    assert_equal "- [ ] Brød\n- [x] Melk\n", body
  end

  def test_markdown_formatting_matches
    body, _ = box([["Les boka", :done], ["fet tekst", :check], ["1+1*2", :done], ["strøket", :done]],
                  "- Les [boka](https://example.com)\n- **fet** tekst\n- 1+1\\*2\n- ~~strøket~~\n")
    assert_equal "- [x] Les [boka](https://example.com)\n- [ ] **fet** tekst\n- [x] 1+1\\*2\n- [x] ~~strøket~~\n", body
  end

  def test_emoji_offsets_utf16
    body, _ = box([["😀 glad", :check], ["Neste", :done], ["Siste", :check]], "- 😀 glad\n- Neste\n- Siste\n")
    assert_equal "- [ ] 😀 glad\n- [x] Neste\n- [ ] Siste\n", body
  end

  def test_inline_attachment_is_wildcard
    body, _ = box([["Kjøp melk \u{FFFC}", :done]], "- Kjøp melk #handel\n")
    assert_equal "- [x] Kjøp melk #handel\n", body
  end

  def test_whitespace_and_nfd_differences_match
    body, _ = box([["Blåbær  syltetøy ", :done]], "- #{"Blåbær syltetøy".unicode_normalize(:nfd)}\n")
    assert_match(/\A- \[x\] /, body)
  end

  def test_empty_checklist_item_ignored
    body, problems = box([["", :check], ["Melk", :done]], "- Melk\n")
    assert_equal "- [x] Melk\n", body
    assert_equal "", problems
  end

  def test_sections_after_body_untouched
    body, problems = box([["x → y", :done]], "Tekst\n\n## Internal links\n\n- x → y\n")
    assert_equal "Tekst\n\n## Internal links\n\n- x → y\n", body
    assert_match(/not found/i, problems)
  end

  def test_star_marker_kept
    body, _ = box([["Melk", :done]], "* Melk\n")
    assert_equal "* [x] Melk\n", body
  end

  def test_run_without_paragraph_style
    body, _ = box([["Tittel", :bare], ["Melk", :done]], "Tittel\n\n- Melk\n")
    assert_equal "Tittel\n\n- [x] Melk\n", body
  end

  def test_item_text_starting_like_list_marker
    body, problems = box([["1. 20% ", :done], ["2. 15% kl 23:30 (00:30)", :check], ["> sitat", :done], ["# ikke overskrift", :done]],
                         "-   1. 20%\n-   2. 15% kl 23:30 (00:30)\n-   > sitat\n-   # ikke overskrift\n")
    assert_equal "", problems
    assert_equal "- [x] 1. 20%\n- [ ] 2. 15% kl 23:30 (00:30)\n- [x] > sitat\n- [x] # ikke overskrift\n", body
  end

  def test_item_with_line_break_matches_continuation_lines
    body, problems = box([["Første\u{2028}fortsatt", :done], ["Andre", :check], ["Tredje\u{2028}a\u{2028}b", :check]],
                         "## Mål\n\n-   Første\n    *fortsatt*\n-   Andre\n-   Tredje\n    a\n    b\n")
    assert_equal "", problems
    assert_equal "## Mål\n\n- [x] Første\n    *fortsatt*\n- [ ] Andre\n- [ ] Tredje\n    a\n    b\n", body
  end

  def test_continuation_must_match_too
    body, problems = box([["Første\u{2028}fortsatt", :done]], "- Første\n    noe annet\n")
    assert_match(/not found/i, problems)
    refute_includes body, "[x]"
  end

  def test_space_lost_between_merged_italics_matches
    body, problems = box([["Rydde - lyktes ikke.", :done]], "-   Rydde *-lyktes ikke.*\n")
    assert_equal "", problems
    assert_equal "- [x] Rydde *-lyktes ikke.*\n", body
  end

  def test_checklist_items_in_numbered_list
    body, problems = box([["Programmering", :plain], ["Tuning av girkassa", :plain], ["Slå av start stopp", :done], ["Justere trinnene", :check]],
                         "## Programmering\n1. Tuning av girkassa\n2. Slå av start stopp\n3.  Justere trinnene\n")
    assert_equal "", problems
    assert_equal "## Programmering\n1. Tuning av girkassa\n- [x] Slå av start stopp\n- [ ] Justere trinnene\n", body
  end

  def test_not_found_shows_notes_text_and_closest_md_line
    _, problems = box([["Kjøp\u{00A0}melk\u{2028}i dag", :done]], "Tittel\n\n- Egg\n- Kjøp melk\n    i går\n")
    assert_includes problems, %q{notes: "Kjøp\u00A0melk\u2028i dag"}
    assert_includes problems, %q{md 9:  "- Kjøp melk"}
  end

  def test_link_only_items_boxed_in_internal_links
    alt = { "AAAA-1" => "9 finn arbeidsklær", "BBBB-2" => "9 bestille nye klær" }
    body, problems = box([["Pakke", :plain], ["\u{FFFC}", :check, "AAAA-1"], ["\u{FFFC}", :done, "BBBB-2"]],
                         "## Pakke\n## Internal links\n- 9 finn arbeidsklær → applenotes:note/a\n- 9 bestille nye klær → applenotes:note/b\n", alt)
    assert_equal "", problems
    assert_includes body, "## Internal links\n- [ ] 9 finn arbeidsklær → applenotes:note/a\n- [x] 9 bestille nye klær → applenotes:note/b\n"
  end

  def test_link_only_item_missing_in_internal_links_is_reported
    _, problems = box([["\u{FFFC}", :check, "AAAA-1"]], "## Pakke\n", { "AAAA-1" => "9 finn arbeidsklær" })
    assert_includes problems, "not found in md: 9 finn arbeidsklær"
  end

  # The sections are recognised in every language in lang.yml, so a file
  # exported in Norwegian is handled the same way with NOTES_LANG=en.
  def test_link_only_items_boxed_in_norwegian_internal_links
    alt = { "AAAA-1" => "9 finn arbeidsklær" }
    body, problems = box([["Pakke", :plain], ["\u{FFFC}", :check, "AAAA-1"]],
                         "## Pakke\n## Interne lenker\n- 9 finn arbeidsklær → applenotes:note/a\n", alt)
    assert_equal "", problems
    assert_includes body, "## Interne lenker\n- [ ] 9 finn arbeidsklær → applenotes:note/a\n"
  end

  def test_body_list_line_with_same_text_as_link_untouched
    body, _ = box([["\u{FFFC}", :done, "AAAA-1"]], "- Melk\n\n## Internal links\n- Melk → applenotes:note/a\n", { "AAAA-1" => "Melk" })
    assert_equal "- Melk\n\n## Internal links\n- [x] Melk → applenotes:note/a\n", body
  end

  def test_attachment_only_item_without_id_does_not_match_any_line
    body, problems = box([["\u{FFFC}", :done]], "- Melk\n")
    assert_match(/not found/i, problems)
    refute_includes body, "[x]"
  end
end

class FolderPathsTest < Minitest::Test
  def db_with(rows)
    db = SQLite3::Database.new(":memory:")
    db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, ZTITLE1 TEXT, ZTITLE2 TEXT, ZPARENT INTEGER, ZFOLDERTYPE INTEGER)"
    rows.each { |r| db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZPARENT, ZFOLDERTYPE) VALUES (?, ?, ?, ?)", r }
    db
  end

  def test_top_folder
    assert_equal({ 1 => "Journal" }, NotesCommon.folder_paths(db_with([[1, "Journal", nil, 0]])))
  end

  def test_nested_two_levels_keeps_case
    paths = NotesCommon.folder_paths(db_with([[3, "Juni", 2, 0], [2, "2024", 1, 0], [1, "Journal", nil, 0]]))
    assert_equal "Journal/2024/Juni", paths[3]
    assert_equal "Journal/2024", paths[2]
  end

  def test_recently_deleted_left_out
    paths = NotesCommon.folder_paths(db_with([[1, "Journal", nil, 0], [2, "Nylig slettet", nil, 1]]))
    assert_equal({ 1 => "Journal" }, paths)
  end

  def test_notes_are_not_folders
    db = db_with([[1, "Journal", nil, 0]])
    db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE1) VALUES (10, 'notat')"
    assert_equal({ 1 => "Journal" }, NotesCommon.folder_paths(db))
  end
end

class ActiveNotesTest < Minitest::Test
  def setup
    @db = SQLite3::Database.new(":memory:")
    @db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZTITLE1 TEXT, ZTITLE2 TEXT, " \
                "ZFOLDER INTEGER, ZFOLDERTYPE INTEGER, ZMARKEDFORDELETION INTEGER, ZCREATIONDATE3 REAL)"
    @db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZTITLE2, ZFOLDERTYPE) VALUES (1, 'Journal', 0), (2, 'Nylig slettet', 1)"
  end

  def note(pk, uuid, title, folder, deleted = 0)
    @db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZTITLE1, ZFOLDER, ZMARKEDFORDELETION, ZCREATIONDATE3) " \
                "VALUES (?, ?, ?, ?, ?, 536500000.0)", [pk, uuid, title, folder, deleted]
  end

  def test_fields_and_lowercase_uuid
    note(10, "AB-CD", "Tittel", 1)
    assert_equal [NotesCommon::Note.new(10, "ab-cd", "Tittel", 1, 536500000.0)], NotesCommon.active_notes(@db)
  end

  def test_recently_deleted_left_out
    note(10, "A", "a", 1)
    note(11, "B", "b", 2)
    assert_equal ["a"], NotesCommon.active_notes(@db).map(&:uuid)
  end

  def test_marked_for_deletion_left_out
    note(10, "A", "a", 1, 1)
    assert_empty NotesCommon.active_notes(@db)
  end

  def test_folders_and_untitled_left_out
    @db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFOLDER, ZMARKEDFORDELETION) VALUES (10, 'A', 1, 0)"
    assert_empty NotesCommon.active_notes(@db)
  end
end

class NoteZdataTest < Minitest::Test
  def setup
    @db = SQLite3::Database.new(":memory:")
    @db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, ZIDENTIFIER TEXT, ZISPASSWORDPROTECTED INTEGER)"
    @db.execute "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)"
    @db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (10, 'AB-CD', NULL), (11, 'EF-01', 1)"
    @db.execute "INSERT INTO ZICNOTEDATA (ZNOTE, ZDATA) VALUES (10, 'data'), (11, 'kryptert')"
  end

  def test_found_by_uuid_case_insensitive
    assert_equal "data", NotesCommon.note_zdata(@db, "ab-cd")
  end

  def test_locked_note_is_nil
    assert_nil NotesCommon.note_zdata(@db, "ef-01")
  end

  def test_unknown_note_is_nil
    assert_nil NotesCommon.note_zdata(@db, "finnes-ikke")
  end
end

class NotesPathsTest < Minitest::Test
  def paths(env)
    code = "require #{File.expand_path('../notes_common', __dir__).dump}; " \
           "puts NotesCommon::NOTES_ROOT, NotesCommon::RAW_CACHE_DIR, NotesCommon::IMPORT_DIR, NotesCommon::DB_PATH, NotesCommon.open_db.readonly?"
    out, status = Open3.capture2e({ "HOME" => "/h", "NOTES_ROOT" => nil, "NOTES_RAW_CACHE" => nil, "NOTES_IMPORT" => nil, "NOTES_DB" => nil }.merge(env),
                                  "ruby", "-e", code)
    assert status.success?, out
    out.lines.map(&:chomp)
  end

  def test_defaults
    Dir.mktmpdir do |dir|
      db = File.join(dir, "n.sqlite")
      SQLite3::Database.new(db).close
      root, raw, import, db_path, _ = paths("NOTES_DB" => db)
      assert_equal "/h/notes", root
      assert_equal "/h/notes/apple_notes.raw", raw
      assert_equal "/h/notes/import", import
      assert_equal db, db_path
    end
  end

  def test_env_overrides_and_db_is_readonly
    Dir.mktmpdir do |dir|
      db = File.join(dir, "n.sqlite")
      SQLite3::Database.new(db).close
      assert_equal ["/r", "/c", "/i", db, "true"],
                   paths("NOTES_ROOT" => "/r", "NOTES_RAW_CACHE" => "/c", "NOTES_IMPORT" => "/i", "NOTES_DB" => db)
    end
  end

  def test_default_db_path
    out, _ = Open3.capture2e({ "HOME" => "/h", "NOTES_DB" => nil }, "ruby", "-e",
                             "require #{File.expand_path('../notes_common', __dir__).dump}; puts NotesCommon::DB_PATH")
    assert_equal "/h/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite\n", out
  end
end

class AttachmentTest < Minitest::Test
  def test_asset_name_is_uuid_with_lowercase_extension
    assert_equal "ABC-1.png", NotesCommon.asset_name("ABC-1", "/m/x/Bilde 1.PNG")
    assert_equal "ABC-1.pdf", NotesCommon.asset_name("ABC-1", "/m/x/a.b.pdf")
    assert_equal "ABC-1", NotesCommon.asset_name("ABC-1", "/m/x/fil")
  end

  def test_asset_data_adds_charset_to_html
    Dir.mktmpdir do |dir|
      path = File.join(dir, "side.HTML")
      File.write(path, "<html><body>æ</body></html>")
      assert_equal '<html><head><meta charset="utf-8"></head><body>æ</body></html>', NotesCommon.asset_data(path)
    end
  end

  def test_asset_data_keeps_html_with_charset
    Dir.mktmpdir do |dir|
      path = File.join(dir, "side.html")
      File.write(path, '<html><meta charset="latin1"></html>')
      assert_equal '<html><meta charset="latin1"></html>', NotesCommon.asset_data(path)
    end
  end

  def test_asset_data_is_raw_bytes_for_other_files
    Dir.mktmpdir do |dir|
      path = File.join(dir, "foto.jpg")
      File.binwrite(path, "\xFF\xD8<html>".b)
      assert_equal "\xFF\xD8<html>".b, NotesCommon.asset_data(path)
    end
  end

  def test_attachment_sources_gives_one_file_per_attachment
    Dir.mktmpdir do |dir|
      db = SQLite3::Database.new(File.join(dir, "n.sqlite"))
      db.execute "CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZIDENTIFIER TEXT, ZNOTE INTEGER, ZMEDIA INTEGER, ZACCOUNT1 INTEGER, ZFILENAME TEXT)"
      db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, ZIDENTIFIER, ZFILENAME) VALUES (1, 'KONTO', NULL), (2, 'M1', 'a.png'), (3, 'M2', 'b.pdf')"
      db.execute "INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNOTE, ZMEDIA, ZACCOUNT1) VALUES (4, 5, 10, 2, 1), (5, 5, 10, 3, 1), (6, 5, 11, 2, 1)"
      media = File.join(dir, "Library", "Group Containers", "group.com.apple.notes", "Accounts", "KONTO", "Media")
      FileUtils.mkdir_p File.join(media, "M1", "x")
      File.write(File.join(media, "M1", "x", "a.png"), "a")
      File.write(File.join(media, "M1", "x", "annen.png"), "b")
      home = ENV["HOME"]
      ENV["HOME"] = dir
      assert_equal [["M1", File.join(media, "M1", "x", "a.png")], ["M2", nil]], NotesCommon.attachment_sources(db, 10)
    ensure
      ENV["HOME"] = home
      db&.close
    end
  end

  def media_tree(files)
    Dir.mktmpdir do |dir|
      files.each do |rel, content|
        path = File.join(dir, rel)
        FileUtils.mkdir_p File.dirname(path)
        content == :dir ? FileUtils.mkdir_p(path) : File.write(path, content)
      end
      yield dir
    end
  end

  def test_attachment_file_is_zfilename_at_level_two
    media_tree("x/a.png" => "a", "y/b.png" => "b") do |dir|
      assert_equal File.join(dir, "x/a.png"), NotesCommon.attachment_file(dir, "a.png")
    end
  end

  def test_attachment_file_ignores_other_levels
    media_tree("a.png" => "a", "x/y/a.png" => "a") do |dir|
      assert_nil NotesCommon.attachment_file(dir, "a.png")
    end
  end

  def test_attachment_file_is_zip_when_zfilename_is_folder
    media_tree("x/Mappe/a.png" => "a", "x/Mappe.zip" => "zip") do |dir|
      assert_equal File.join(dir, "x/Mappe.zip"), NotesCommon.attachment_file(dir, "Mappe")
    end
  end

  def test_attachment_file_is_nil_for_folder_without_zip
    media_tree("x/Mappe/a.png" => "a") do |dir|
      assert_nil NotesCommon.attachment_file(dir, "Mappe")
    end
  end

  def test_attachment_file_matches_nfd_on_disk
    media_tree("x/#{'blåbær.png'.unicode_normalize(:nfd)}" => "a") do |dir|
      assert_equal File.join(dir, "x/#{'blåbær.png'.unicode_normalize(:nfd)}"), NotesCommon.attachment_file(dir, "blåbær.png")
    end
  end

  def test_attachment_file_without_zfilename_or_media_dir
    media_tree("x/a.png" => "a") do |dir|
      assert_nil NotesCommon.attachment_file(dir, nil)
      assert_nil NotesCommon.attachment_file(File.join(dir, "finnes-ikke"), "a.png")
    end
  end
end

