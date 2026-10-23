require 'fileutils'
require 'json'
require 'open3'
require 'set'
require_relative 'notes_common'

# Syncs the raw cache with Notes: shows every difference and asks before
# anything is fetched or deleted; if everything is in sync, nothing happens.
# Fetching goes through AppleScript in batches of 10 with killall + sleep in
# between to keep Notes responsive. Used by `apple-notes sync` and as step 1
# of `apple-notes export`.
module NotesSync
  module_function

  NOTE_DELIM = "---NOTE_DELIM_#{$$}---"

  JXA_PROGRESS = <<~'JXAP'
    ObjC.import('Foundation');
    const _stderr = $.NSFileHandle.fileHandleWithStandardError;
    function progress(current, total, label) {
      const w = 30;
      const filled = Math.round(current / total * w);
      const bar = "=".repeat(filled) + " ".repeat(w - filled);
      const prefix = label ? label + " " : "";
      const msg = `\r${prefix}[${bar}] ${current}/${total}`;
      _stderr.writeData($.NSString.alloc.initWithString(msg).dataUsingEncoding($.NSUTF8StringEncoding));
      if (current === total) _stderr.writeData($.NSString.alloc.initWithString("\n").dataUsingEncoding($.NSUTF8StringEncoding));
    }
  JXAP

  JXA_FMT_DATE = <<~'JXAD'
    function fmtDate(d) {
      const y = d.getFullYear();
      const m = String(d.getMonth() + 1).padStart(2, "0");
      const day = String(d.getDate()).padStart(2, "0");
      return y + "-" + m + "-" + day;
    }
  JXAD

  def run_jxa(script)
    stdout = err_output = ""
    status = nil
    Open3.popen3("osascript", "-l", "JavaScript", "-e", script) do |_in, out, err, thr|
      _in.close
      err_thread = Thread.new { err.each_char { |c| $stderr.print c; err_output << c } rescue IOError }
      stdout = out.read
      err_thread.join
      status = thr.value
    end
    [stdout, err_output, status]
  end

  def write_cache_atomic(uuid, body, plaintext)
    FileUtils.mkdir_p NotesCommon::RAW_CACHE_DIR
    [["html", body], ["txt", plaintext]].each do |ext, content|
      next if content.nil?
      final = File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.#{ext}")
      tmp = "#{final}.tmp.#{$$}"
      File.write(tmp, content)
      File.rename(tmp, final)
    end
  end

  def fetch_by_uuids(db, uuids)
    store_uuid = db.get_first_value "SELECT Z_UUID FROM Z_METADATA LIMIT 1"
    placeholders = uuids.map { "?" }.join(",")
    pks = db.execute("SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE lower(ZIDENTIFIER) IN (#{placeholders})", uuids.map(&:downcase)).flatten
    jxa_ids = pks.map { |pk| "x-coredata://#{store_uuid}/ICNote/p#{pk}" }

    jxa_ids_js = jxa_ids.map(&:to_json).join(",")
    jxa = JXA_PROGRESS + JXA_FMT_DATE + <<~JXA
      const app = Application("Notes");
      const ids = [#{jxa_ids_js}];
      const delim = #{NOTE_DELIM.to_json};
      const parts = [String(ids.length)];
      let ok = 0, failed = 0;
      for (let j = 0; j < ids.length; j++) {
        progress(j + 1, ids.length);
        try {
          const n = app.notes.byId(ids[j]);
          const blob = n.name() + "\\n" + fmtDate(n.creationDate()) + "\\n" + fmtDate(n.modificationDate()) + "\\n" + n.id() + "\\n---BODY---\\n" + n.body() + "\\n---PLAINTEXT---\\n" + n.plaintext();
          parts.push(blob);
          ok++;
        } catch (e) {
          failed++;
          _stderr.writeData($.NSString.alloc.initWithString("\\nDEBUG byId failed for " + ids[j] + ": " + e.message + "\\n").dataUsingEncoding($.NSUTF8StringEncoding));
        }
      }
      parts.join(delim);
    JXA
    stdout, stderr, status = run_jxa(jxa)
    abort "AppleScript error: #{stderr.strip}" unless status.success?
    all_notes_raw = stdout.split(NOTE_DELIM)
    note_count = all_notes_raw.shift.strip.to_i
    [all_notes_raw, note_count]
  end

  def sync(db, folder_paths)
    limit_folder = ENV["NOTES_LIMIT_FOLDER"]
    if limit_folder
      norm = ->(s) { s.to_s.unicode_normalize(:nfc).downcase }
      folder_pk = nil
      db.execute("SELECT Z_PK, ZTITLE2 FROM ZICCLOUDSYNCINGOBJECT WHERE ZTITLE2 IS NOT NULL").each do |pk, title|
        if norm.call(title) == norm.call(limit_folder)
          folder_pk = pk
          break
        end
      end
      abort "Folder not found: #{limit_folder}" unless folder_pk
    end

    all_notes = NotesCommon.active_notes(db)
    notes = limit_folder ? all_notes.select { |n| n.folder == folder_pk } : all_notes
    modified = db.execute("SELECT lower(ZIDENTIFIER), ZMODIFICATIONDATE1 FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER IS NOT NULL").to_h
    locked = db.execute("SELECT lower(ZIDENTIFIER) FROM ZICCLOUDSYNCINGOBJECT WHERE ZISPASSWORDPROTECTED = 1").flatten.to_set
    cache_file = ->(uuid, ext) { File.join(NotesCommon::RAW_CACHE_DIR, "#{uuid}.#{ext}") }

    # Notes to fetch, per difference.
    fetch = Hash.new { |h, k| h[k] = [] }
    notes.each do |n|
      has_html = File.exist?(cache_file.(n.uuid, "html"))
      has_txt = File.exist?(cache_file.(n.uuid, "txt"))
      group =
        if !has_html && !has_txt then "Missing from cache"
        elsif !has_html || !has_txt then "Partial cache"
        elsif modified[n.uuid] && Time.at(modified[n.uuid] + 978_307_200) > File.mtime(cache_file.(n.uuid, "html"))
          "Changed in Notes"
        end
      next unless group
      group = "Locked – unlock in Notes first" if locked.include?(n.uuid)
      fetch[group] << ["#{folder_paths[n.folder]}  #{n.title}", n.uuid]
    end

    # Cache to delete: notes in "Recently Deleted" or gone from Notes.
    active = all_notes.map(&:uuid).to_set
    trashed = db.execute(
      "SELECT lower(n.ZIDENTIFIER), f.ZTITLE2, n.ZTITLE1 FROM ZICCLOUDSYNCINGOBJECT n " \
      "JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER WHERE f.ZFOLDERTYPE = 1"
    ).to_h { |uuid, folder, title| [uuid, "#{folder}  #{title}"] }
    # Cached text for a note (txt, otherwise html).
    cached_text = ->(uuid) {
      path = [cache_file.(uuid, "txt"), cache_file.(uuid, "html")].find { |p| File.exist?(p) }
      File.read(path, encoding: "UTF-8")
    }
    remove = Hash.new { |h, k| h[k] = [] }
    Dir.glob(File.join(NotesCommon::RAW_CACHE_DIR, "*.{html,txt}")).map { |f| File.basename(f).sub(/\.(html|txt)\z/, "") }.uniq.each do |uuid|
      next if active.include?(uuid)
      if trashed[uuid]
        remove["In \"Recently Deleted\" – removed from cache"] << [trashed[uuid], uuid]
      else
        remove["Not in Notes – removed from cache"] << ["#{uuid}  #{cached_text.(uuid).lines.first.to_s.strip}", uuid]
      end
    end

    return if fetch.empty? && remove.empty?

    ["Missing from cache", "Partial cache", "Changed in Notes", "Locked – unlock in Notes first",
     "In \"Recently Deleted\" – removed from cache", "Not in Notes – removed from cache"].each do |group|
      rows = fetch.key?(group) ? fetch[group] : remove.fetch(group, nil)
      next unless rows
      puts "#{group}: #{rows.size}"
      rows.sort.each { |label, _| puts "  #{label}" }
    end
    # v shows the content of the notes being removed from the cache, and asks again.
    choices = remove.empty? ? "[y/N]" : "[y/N/v]"
    answer = nil
    loop do
      print "Sync the cache? #{choices} "
      answer = $stdin.gets&.strip&.downcase
      break unless answer == "v" && !remove.empty?
      remove.values.flatten(1).sort.each do |_, uuid|
        puts "── #{uuid} ──"
        puts cached_text.(uuid)
      end
    end
    return unless answer == "y"

    remove.values.flatten(1).each { |_, uuid| FileUtils.rm_f([cache_file.(uuid, "html"), cache_file.(uuid, "txt")]) }

    missing_uuids = fetch.values.flatten(1).map(&:last)
    return if missing_uuids.empty?

    interrupt_requested = false
    Signal.trap("INT") {
      if interrupt_requested
        warn "\nForced interrupt."
        exit 1
      end
      interrupt_requested = true
      warn "\nStopping after this batch... (Ctrl-C again to force)"
    }

    batch_size = 10
    total_batches = (missing_uuids.size.to_f / batch_size).ceil
    cached_count = 0
    global_batch = 0
    batch_times = []

    missing_uuids.each_slice(batch_size) do |batch|
      if interrupt_requested
        puts "\nInterrupted before batch #{global_batch + 1}/#{total_batches}"
        break
      end
      if global_batch > 0
        system "killall", "Notes", out: File::NULL, err: File::NULL
        sleep 2
      end
      t0 = Time.now
      all_notes_raw, _ = fetch_by_uuids(db, batch)
      all_notes_raw.each do |raw_note|
        parts = raw_note.split("---BODY---\n", 2)
        header_lines = parts[0].split("\n")
        note_id_str = header_lines[3]
        body_and_text = parts[1].to_s.split("\n---PLAINTEXT---\n", 2)
        body = body_and_text[0].to_s
        plaintext = body_and_text[1].to_s
        note_pk = note_id_str[/ICNote\/p(\d+)/, 1]
        next unless note_pk
        row = db.get_first_row("SELECT ZIDENTIFIER FROM ZICCLOUDSYNCINGOBJECT WHERE Z_PK=?", note_pk)
        next unless row
        uuid = row[0].downcase
        write_cache_atomic(uuid, body, plaintext)
        cached_count += 1
      end
      batch_times << (Time.now - t0)
      global_batch += 1
      remaining = total_batches - global_batch
      if remaining > 0 && batch_times.size > 0
        avg = batch_times.sum / batch_times.size
        eta_h = (avg * remaining / 3600).round(1)
        $stderr.puts "  Batch #{global_batch}/#{total_batches}, ~#{eta_h}h remaining"
      end
    end

    if interrupt_requested
      puts "\nStopped: #{cached_count} cached, #{missing_uuids.size - cached_count} remaining"
      exit 130
    end
    failed = missing_uuids.size - cached_count
    warn "Could not fetch #{failed} notes from Notes" if failed > 0
  end
end
