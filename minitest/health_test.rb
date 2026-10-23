# encoding: utf-8
require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'securerandom'

Encoding.default_external = "UTF-8"

SCRIPT = File.expand_path("../libexec/health", __dir__)

def run_script(dir, extra_args = [])
  args = extra_args.dup
  # If no mode flag is given, use --multi to trigger the multi-ref report
  mode_flags = %w[--multi --orphans --broken]
  args.unshift("--multi") unless args.any? { |a| mode_flags.include?(a) }
  args.unshift("--verbose") unless args.include?("--verbose")
  out = `ruby #{SCRIPT} -s #{dir} #{args.join(" ")} 2>&1`
  [out, $?.exitstatus]
end

def write(path, content)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, content, encoding: "UTF-8")
  path
end

# Returns markdown content pointing to the asset relative to the md file's folder
def md_with_note_id(asset_rel)
  <<~MD
    ---
    note_id: "#{SecureRandom.uuid}"
    ---
    Innhold [bilde](#{asset_rel})
  MD
end

class NotesHealthMultiRefTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @import_dir = File.join(@dir, "import")
    FileUtils.mkdir_p(@import_dir)
  end

  def teardown
    FileUtils.remove_entry @dir
  end

  # No cross-references — reports 0
  def test_no_multi_references
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, "bilde.png"), "data")

    write(File.join(@dir, "a.md"), md_with_note_id("assets/bilde.png"))

    out, _ = run_script(@dir)
    assert_match(/Referenced by more than one file:.*?0/, out)
  end

  # Two files in the same folder point to the same asset — reported
  def test_detects_shared_asset
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, "bilde.png"), "data")

    write(File.join(@dir, "a.md"), md_with_note_id("assets/bilde.png"))
    write(File.join(@dir, "b.md"), md_with_note_id("assets/bilde.png"))

    out, _ = run_script(@dir)
    assert_match(/Referenced by more than one file:.*?1/, out)
    assert_match(/bilde\.png/, out)
  end

  # --orphans reports assets without a reference
  def test_orphans_reports_unreferenced_asset
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    referenced = File.join(assets_dir, "brukt.png")
    orphan     = File.join(assets_dir, "ubrukt.png")
    File.write(referenced, "data")
    File.write(orphan, "data")

    write(File.join(@dir, "a.md"), md_with_note_id("assets/brukt.png"))

    out, _ = run_script(@dir, ["--orphans"])
    assert_match(/ubrukt\.png/, out)
    # check that brukt.png is not listed as an orphan (it can occur in the path of ubrukt.png)
    refute_match(/\bubrukt\.png.*brukt\.png\b/m, out)
    lines = out.lines.select { |l| l =~ /Without reference|\.png/ }
    refute lines.any? { |l| l =~ /brukt\.png/ && l !~ /ubrukt/ }, "brukt.png should not be listed as an orphan"
  end

  # --orphans reports 0 when all assets are in use
  def test_orphans_none_when_all_referenced
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, "brukt.png"), "data")

    write(File.join(@dir, "a.md"), md_with_note_id("assets/brukt.png"))

    out, _ = run_script(@dir, ["--orphans"])
    assert_match(/Without reference.*?0/, out)
  end

  # --broken reports files pointing to missing assets
  def test_broken_reports_missing_asset
    write(File.join(@dir, "a.md"), md_with_note_id("assets/finnes_ikke.png"))

    out, _ = run_script(@dir, ["--broken"])
    assert_match(/finnes_ikke\.png/, out)
    assert_match(/a\.md/, out)
  end

  # --broken reports nothing when all assets exist
  def test_broken_none_when_all_assets_exist
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, "bilde.png"), "data")

    write(File.join(@dir, "a.md"), md_with_note_id("assets/bilde.png"))

    out, _ = run_script(@dir, ["--broken"])
    assert_match(/Files referring to missing assets:.*?0/, out)
  end

  # Without a category, multi, orphans and broken run together
  def test_all_runs_multi_orphans_and_broken
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, "delt.png"), "data")
    File.write(File.join(assets_dir, "ubrukt.png"), "data")

    write(File.join(@dir, "a.md"), md_with_note_id("assets/delt.png"))
    write(File.join(@dir, "b.md"), md_with_note_id("assets/delt.png"))
    write(File.join(@dir, "c.md"), md_with_note_id("assets/finnes_ikke.png"))

    out, _ = `ruby #{SCRIPT} -s #{@dir} 2>&1`.then { |o| [o, $?.exitstatus] }
    assert_match(/--multi: \e\[\d+m\e\[1m1\b/, out)
    assert_match(/--orphans: \e\[\d+m\e\[1m1\b/, out)
    assert_match(/--broken: \e\[\d+m\e\[1m1\b/, out)
  end

  # --created flags an md file without created_at in the frontmatter
  def test_missing_created_at_flags_file_without_key
    write(File.join(@dir, "a.md"), <<~MD)
      ---
      note_id: "#{SecureRandom.uuid}"
      ---
      Innhold
    MD

    out, status = run_with_input(["--created", "--verbose"], "n\n").then { |o| [o, $?.exitstatus] }
    assert_match(/(Missing created_at|created_at in frontmatter):.*?1/, out)
    assert_match(/a\.md/, out)
    assert_equal 1, status
  end

  # --created reports 0 when all files have created_at
  def test_missing_created_at_none_when_all_present
    write(File.join(@dir, "a.md"), <<~MD)
      ---
      created_at: 2024-01-01
      note_id: "#{SecureRandom.uuid}"
      ---
      Innhold
    MD

    out, status = run_with_input(["--created", "--verbose"], "n\n").then { |o| [o, $?.exitstatus] }
    assert_match(/(Missing created_at|created_at in frontmatter):.*?0/, out)
    assert_equal 0, status
  end

  # --created flags a file with no frontmatter at all
  def test_missing_created_at_flags_file_without_frontmatter
    write(File.join(@dir, "a.md"), "Bare innhold, ingen frontmatter\n")

    out, _ = run_with_input(["--created", "--verbose"], "n\n").then { |o| [o, $?.exitstatus] }
    assert_match(/(Missing created_at|created_at in frontmatter):.*?1/, out)
  end

  # Without a category, missing created_at is included
  def test_all_includes_missing_created_at
    write(File.join(@dir, "a.md"), <<~MD)
      ---
      note_id: "#{SecureRandom.uuid}"
      ---
      Innhold
    MD

    out, _ = `ruby #{SCRIPT} -s #{@dir} 2>&1`.then { |o| [o, $?.exitstatus] }
    assert_match(/--created: \e\[\d+m\e\[1m1\b/, out)
  end

  # --created checks only .md files
  def test_missing_created_at_ignores_file_without_md_extension
    write(File.join(@dir, "notat"), "Vanlig tekstinnhold\n")

    out, status = run_with_input(["--created", "--verbose"], "n\n").then { |o| [o, $?.exitstatus] }
    refute_match(/notat/, out)
    assert_equal 0, status
  end

  # --created ignores binary files without an extension
  def test_missing_created_at_ignores_binary_file_without_extension
    write(File.join(@dir, "binærfil"), "\x00\x01\x02data")

    out, _ = run_with_input(["--created", "--verbose"], "n\n").then { |o| [o, $?.exitstatus] }
    refute_match(/binærfil/, out)
  end

  # --created ignores files under assets/
  def test_missing_created_at_ignores_assets_dir
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    write(File.join(assets_dir, "vedlegg"), "tekstvedlegg\n")

    out, _ = run_with_input(["--created", "--verbose"], "n\n").then { |o| [o, $?.exitstatus] }
    refute_match(/vedlegg/, out)
  end

  # --created ignores files with a dot in the name (other extension)
  def test_missing_created_at_ignores_files_with_other_extension
    write(File.join(@dir, "skript.sh"), "#!/bin/bash\necho hei\n")

    out, _ = run_with_input(["--created", "--verbose"], "n\n").then { |o| [o, $?.exitstatus] }
    refute_match(/skript\.sh/, out)
  end

  # --broken does not rewrite to ../assets/ (that folder layout no longer exists)
  def test_broken_does_not_remap_to_parent_assets
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, "bilde.png"), "data")
    md = write(File.join(@dir, "sub", "a.md"), md_with_note_id("assets/bilde.png"))

    run_with_input(["--broken"], "y\n")
    assert_includes File.read(md), "](assets/bilde.png)"
  end

  # --broken leaves the reference when the asset does not exist one level up
  def test_remap_leaves_reference_when_not_found_above
    md = write(File.join(@dir, "sub", "a.md"), md_with_note_id("assets/bilde.png"))

    run_with_input(["--broken"], "y\n")
    assert_includes File.read(md), "](assets/bilde.png)"
  end

  # A remapped reference counts as a reference, not as an orphan
  def test_remapped_reference_is_not_orphan
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, "bilde.png"), "data")
    write(File.join(@dir, "sub", "a.md"), md_with_note_id("../assets/bilde.png"))

    out, _ = run_script(@dir, ["--orphans"])
    refute_match(/bilde\.png/, out)
  end

  # --orphans --rm deletes orphaned assets, but not referenced ones
  def test_orphans_rm_deletes_unreferenced_asset
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    used   = File.join(assets_dir, "brukt.png")
    orphan = File.join(assets_dir, "ubrukt.png")
    File.write(used, "data")
    File.write(orphan, "data")
    write(File.join(@dir, "a.md"), md_with_note_id("assets/brukt.png"))

    `ruby #{SCRIPT} -s #{@dir} --orphans --rm 2>&1`
    refute File.exist?(orphan)
    assert File.exist?(used)
  end

  # --rm only together with --orphans alone; otherwise exit 1 and nothing is deleted
  def test_rm_rejected_without_orphans_alone
    assets_dir = File.join(@dir, "assets")
    FileUtils.mkdir_p(assets_dir)
    orphan = File.join(assets_dir, "ubrukt.png")
    File.write(orphan, "data")

    [[], ["--broken"], ["--orphans", "--broken"]].each do |args|
      `ruby #{SCRIPT} -s #{@dir} #{args.join(" ")} --rm 2>&1`
      assert_equal 1, $?.exitstatus, args.inspect
      assert File.exist?(orphan)
    end
  end

  # --all is gone: running without a category does the same
  def test_all_option_is_rejected
    out = `ruby #{SCRIPT} -s #{@dir} --all 2>&1`
    assert_equal 1, $?.exitstatus
    assert_match(/invalid option: --all/, out)
  end

  # --fix is gone: --broken offers the moves itself
  def test_fix_option_is_rejected
    out = `ruby #{SCRIPT} -s #{@dir} --broken --fix 2>&1`
    assert_equal 1, $?.exitstatus
    assert_match(/invalid option: --fix/, out)
  end

  def run_with_input(args, input)
    IO.popen(["ruby", SCRIPT, "-s", @dir, *args], "r+", err: [:child, :out]) do |io|
      io.write(input)
      io.close_write
      io.read
    end
  end

  # --broken: md file moved without its asset — y moves the asset to the md file's assets/
  def test_broken_moves_asset_on_yes
    md = setup_sibling_match
    run_with_input(["--broken"], "y\n")
    refute File.exist?(@src)
    assert File.exist?(@dst)
    assert_includes File.read(md), "](assets/1.jpg)"
  end

  # An empty line is yes
  def test_broken_moves_asset_default_yes
    setup_sibling_match
    run_with_input(["--broken"], "\n")
    assert File.exist?(@dst)
  end

  # n leaves the asset where it is
  def test_broken_keeps_asset_on_no
    setup_sibling_match
    run_with_input(["--broken"], "n\n")
    assert File.exist?(@src)
    refute File.exist?(@dst)
  end

  # No assets/ next to the md file: say so, do not ask, do not move
  def test_broken_reports_missing_assets_dir
    md = setup_sibling_match(target_dir: false)
    out = run_with_input(["--broken"], "y\n").gsub(/\e\[\d+m/, "")
    assert_match(/asset folder missing:.*logg\/assets/, out)
    refute_match(/\[Y\/n\]/, out)
    assert File.exist?(@src)
    refute File.directory?(File.dirname(@dst))
    assert_includes File.read(md), "](assets/1.jpg)"
  end

  # Several orphans with the same name are ambiguous — no suggestion
  def test_remap_ambiguous_orphans_not_offered
    %w[b c].each do |d|
      FileUtils.mkdir_p(File.join(@dir, d, "assets"))
      File.write(File.join(@dir, d, "assets", "1.jpg"), "data")
    end
    FileUtils.mkdir_p(File.join(@dir, "a", "assets"))
    md = write(File.join(@dir, "a", "x.md"), md_with_note_id("assets/1.jpg"))

    out = run_with_input(["--broken"], "y\n")
    assert_includes File.read(md), "](assets/1.jpg)"
    refute_match(/\[Y\/n\]/, out)
    refute File.exist?(File.join(@dir, "a", "assets", "1.jpg"))
  end

  # Several broken references with the same name are ambiguous — no suggestion
  def test_remap_ambiguous_broken_refs_not_offered
    FileUtils.mkdir_p(File.join(@dir, "b", "assets"))
    File.write(File.join(@dir, "b", "assets", "1.jpg"), "data")
    md1 = write(File.join(@dir, "a", "x.md"), md_with_note_id("assets/1.jpg"))
    md2 = write(File.join(@dir, "c", "y.md"), md_with_note_id("assets/1.jpg"))

    out = run_with_input(["--broken"], "y\ny\n")
    assert_includes File.read(md1), "](assets/1.jpg)"
    assert_includes File.read(md2), "](assets/1.jpg)"
    refute_match(/\[Y\/n\]/, out)
  end

  # A reference to assets in another folder counts as a reference
  def test_reference_to_sibling_assets_is_not_orphan
    FileUtils.mkdir_p(File.join(@dir, "b", "assets"))
    File.write(File.join(@dir, "b", "assets", "1.jpg"), "data")
    write(File.join(@dir, "a", "x.md"), md_with_note_id("../b/assets/1.jpg"))

    out, _ = run_script(@dir, ["--orphans"])
    refute_match(/1\.jpg/, out)
  end

  def test_reference_nfd_matches_nfc_file
    FileUtils.mkdir_p(File.join(@dir, "assets"))
    File.write(File.join(@dir, "assets", "kafé.png".unicode_normalize(:nfc)), "data")
    write(File.join(@dir, "a.md"), md_with_note_id("assets/#{'kafé.png'.unicode_normalize(:nfd)}"))

    out, _ = run_script(@dir, ["--broken", "--orphans"])
    refute_match(/kaf/, out)
  end

  def test_url_with_assets_in_path_is_not_asset_reference
    write(File.join(@dir, "a.md"), md_with_note_id("https://example.com/assets/x.png"))

    out, _ = run_script(@dir, ["--broken"])
    refute_match(/x\.png/, out)
  end

  # --orphans --rm refuses to delete as long as there are broken references
  def test_orphans_rm_refuses_when_broken_refs_exist
    FileUtils.mkdir_p(File.join(@dir, "b", "assets"))
    asset = File.join(@dir, "b", "assets", "1.jpg")
    File.write(asset, "data")
    md = write(File.join(@dir, "a", "x.md"), md_with_note_id("assets/1.jpg"))

    out = run_with_input(["--orphans", "--rm"], "y\n")
    assert_equal 1, $?.exitstatus
    assert File.exist?(asset)
    assert_includes File.read(md), "](assets/1.jpg)"
    assert_match(/run notes health --broken first/, out)
  end

  # --orphans shows broken references with the same filename under the orphan
  def test_orphans_shows_broken_refs_with_same_name
    FileUtils.mkdir_p(File.join(@dir, "journal", "assets"))
    File.write(File.join(@dir, "journal", "assets", "1.jpg"), "data")
    write(File.join(@dir, "logg", "j.md"), md_with_note_id("assets/1.jpg"))

    out = run_with_input(["--orphans"], "n\n")
    plain = out.gsub(/\e\[\d+m/, "")
    assert_match(%r{journal/assets/1\.jpg\n\s+--broken: .*logg/j\.md}, plain)
  end

  # --broken shows orphaned assets with the same filename under the missing one
  def test_broken_shows_orphans_with_same_name
    FileUtils.mkdir_p(File.join(@dir, "journal", "assets"))
    File.write(File.join(@dir, "journal", "assets", "1.jpg"), "data")
    write(File.join(@dir, "logg", "j.md"), md_with_note_id("assets/1.jpg"))

    out = run_with_input(["--broken"], "n\n")
    plain = out.gsub(/\e\[\d+m/, "")
    assert_match(%r{missing: .*logg/assets/1\.jpg\n\s+--orphans: .*journal/assets/1\.jpg}, plain)
  end

  def setup_sibling_match(target_dir: true)
    FileUtils.mkdir_p(File.join(@dir, "journal", "assets"))
    FileUtils.mkdir_p(File.join(@dir, "logg", "assets")) if target_dir
    @src = File.join(@dir, "journal", "assets", "1.jpg")
    @dst = File.join(@dir, "logg", "assets", "1.jpg")
    File.write(@src, "data")
    write(File.join(@dir, "logg", "j.md"), md_with_note_id("assets/1.jpg"))
  end

  # --orphans offers a move when there is a solution
  def test_orphans_offers_move_yes
    setup_sibling_match
    run_with_input(["--orphans"], "y\n")
    assert File.exist?(@dst)
  end

  # The question shows which file the reference was found in, not the link
  def test_offer_shows_referencing_file
    setup_sibling_match
    out = run_with_input(["--broken"], "n\n").gsub(/\e\[\d+m/, "")
    assert_match(%r{reference found in: .*logg/j\.md\n\s+move.*journal/assets/1\.jpg → .*logg/assets/1\.jpg \[Y/n\]}, out)
    refute_match(/\[bilde\]/, out)
  end

  # One level up is not offered
  def test_broken_does_not_offer_parent_fix
    FileUtils.mkdir_p(File.join(@dir, "assets"))
    File.write(File.join(@dir, "assets", "1.jpg"), "data")
    md = write(File.join(@dir, "sub", "a.md"), md_with_note_id("assets/1.jpg"))

    out = run_with_input(["--broken"], "y\n")
    assert_includes File.read(md), "](assets/1.jpg)"
    refute_includes out, "../assets/1.jpg"
  end

  # Without a solution nothing is offered
  def test_broken_no_offer_without_solution
    write(File.join(@dir, "a.md"), md_with_note_id("assets/finnes_ikke.png"))
    out = run_with_input(["--broken"], "y\n")
    refute_match(/\[Y\/n\]/, out)
  end

  # Without a category, and with --silent, no fixes are offered
  def test_all_and_silent_do_not_offer_fix
    setup_sibling_match
    [[], ["--broken", "--silent"]].each do |args|
      out = run_with_input(args, "y\n")
      refute_match(/\[Y\/n\]/, out)
      assert File.exist?(@src)
    end
  end

  # --created lists the files and offers nothing: fix is not part of notes
  def test_created_lists_files_without_offering_fix
    content = "---\nnote_id: \"#{SecureRandom.uuid}\"\n---\nInnhold\n"
    md = write(File.join(@dir, "a.md"), content)
    out = run_with_input(["--created"], "y\n").gsub(/\e\[\d+m/, "")
    assert_includes out, "a.md"
    refute_match(/fix|\[Y\/n\]/, out)
    assert_equal content, File.read(md)
  end

  # No question when nothing is missing created_at, or without a category
  def test_created_no_offer_when_none_missing_or_all
    write(File.join(@dir, "a.md"), "---\ncreated_at: 2024-01-01\n---\nInnhold\n")
    refute_match(/fix --created/, run_with_input(["--created"], "y\n"))

    content = "---\nnote_id: \"#{SecureRandom.uuid}\"\n---\nInnhold\n"
    md = write(File.join(@dir, "b.md"), content)
    refute_match(/\[Y\/n\]/, run_with_input([], "y\n"))
    assert_equal content, File.read(md)
  end

  # Without a category, every report runs
  def test_no_category_runs_all
    FileUtils.mkdir_p(File.join(@dir, "assets"))
    File.write(File.join(@dir, "assets", "ubrukt.png"), "data")
    out = run_with_input([], "")
    assert_match(/Notes health/, out)
    assert_match(/--orphans: \e\[\d+m\e\[1m1\b/, out)
    refute_match(/Usage:/, out)
  end

  # Without a category, hidden md files are reported, also in hidden folders
  def test_all_reports_hidden_md_files
    write(File.join(@dir, "synlig.md"), "---\ncreated_at: 2024-01-01\n---\n")
    write(File.join(@dir, ".skjult.md"), "---\ncreated_at: 2024-01-01\n---\n")
    write(File.join(@dir, ".mappe", "fil.md"), "---\ncreated_at: 2024-01-01\n---\n")
    out = `ruby #{SCRIPT} -s #{@dir} 2>&1`
    status = $?.exitstatus
    plain = out.gsub(/\e\[[0-9;]*m/, "")
    assert_match(/Hidden md files: 2$/, plain)
    assert_includes plain, File.join(@dir, ".skjult.md")
    assert_includes plain, File.join(@dir, ".mappe", "fil.md")
    refute_includes plain, File.join(@dir, "synlig.md")
    assert_equal 1, status
  end

  def test_all_without_hidden_md_files_is_quiet
    write(File.join(@dir, "synlig.md"), "---\ncreated_at: 2024-01-01\n---\n")
    out = `ruby #{SCRIPT} -s #{@dir} 2>&1`
    assert_equal 0, $?.exitstatus, out
    refute_match(/Hidden/, out)
  end

  # Statistics show folders above leaf level
  def test_statistics_shows_parent_dirs
    sub = File.join(@dir, "journal", "2024")
    assets_dir = File.join(sub, "assets")
    FileUtils.mkdir_p(assets_dir)
    File.write(File.join(assets_dir, "bilde.png"), "data")

    write(File.join(sub, "a.md"), md_with_note_id("assets/bilde.png"))
    write(File.join(sub, "b.md"), md_with_note_id("assets/bilde.png"))

    out, _ = run_script(@dir)
    assert_match(/Statistics per folder/, out)
    assert_match(/journal/, out)
  end
end

class NotesHealthAllSilentTest < Minitest::Test
  SCRIPT_PATH = File.expand_path("../libexec/health", __dir__)

  def setup
    @dir = Dir.mktmpdir
    write(File.join(@dir, "a.md"), "---\ncreated_at: 2024-01-01\n---\n")
  end

  def teardown
    FileUtils.remove_entry @dir
  end

  def test_all_silent_produces_no_output
    out = IO.popen(
      { "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
      ["ruby", SCRIPT_PATH, "-s", @dir, "--silent"],
      err: [:child, :out],
      &:read
    )
    assert_equal "", out, "expected no output with --silent, got:\n#{out}"
  end

  def test_all_silent_returns_valid_exit_code
    IO.popen(
      { "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
      ["ruby", SCRIPT_PATH, "-s", @dir, "--silent"],
      err: [:child, :out],
      &:read
    )
    assert_includes [0, 1], $?.exitstatus, "exit code should be 0 or 1, got #{$?.exitstatus}"
  end
end

class NotesHealthAllReportTest < Minitest::Test
  SCRIPT_PATH = File.expand_path("../libexec/health", __dir__)
  UUID = "11111111-2222-3333-4444-555555555555"

  def setup
    @dir = Dir.mktmpdir
    write(File.join(@dir, "a.md"), "---\ncreated_at: 2024-01-01\nnote_id: #{UUID}\n---\n")
  end

  def teardown
    FileUtils.remove_entry @dir
  end

  def health(*args)
    out = IO.popen({ "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8" },
                   ["ruby", SCRIPT_PATH, "-s", @dir, *args], err: [:child, :out], &:read)
    [out.gsub(/\e\[[0-9;]*m/, ""), $?.exitstatus]
  end

  def test_all_reports_duplicate_note_id
    write(File.join(@dir, "b.md"), "---\ncreated_at: 2024-01-01\nnote_id: #{UUID}\n---\n")
    out, status = health
    assert_match(/Duplicate note_id: 1$/, out)
    assert_equal 1, status
  end

  def test_all_healthy_is_silent_and_zero
    out, status = health
    assert_equal "", out
    assert_equal 0, status
  end

  def test_all_verbose_shows_green_rows
    out, status = health("--verbose")
    assert_match(/Notes health/, out)
    assert_match(/Duplicate note_id: 0$/, out)
    assert_equal 0, status
  end

  def test_silent_exit_code_reflects_problems
    _, status = health("--silent")
    assert_equal 0, status
    write(File.join(@dir, "b.md"), "---\ncreated_at: 2024-01-01\nnote_id: #{UUID}\n---\n")
    out, status = health("--silent")
    assert_equal "", out
    assert_equal 1, status
  end

  def test_help
    out, status = health("--help")
    assert_equal 0, status
    assert_match(/--orphans/, out)
  end
end
