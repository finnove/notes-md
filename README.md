# Apple Notes to Markdown

Exports Apple Notes to markdown files with YAML frontmatter. The md files are
the source of truth and live in a git repo; the export creates files for new
notes, updates the ones you have not edited, and rebuilds marked ones.

## Why use it

I experienced data loss using Apple Notes built in export.
Notes with same titles were overwritten. And data was corrupted. 
Many duplicate lines were generated. It could not be trusted.

- **Notes quality are verified** After every build the formatting is
  stripped from both the note and the md file, and the remaining text must be
  identical, word for word. URLs and attachment links are checked too. The
  result is written to the file as `export: pass` or `export: fail`.
- **You can export again, and your edits are safe.** Each file gets a checksum
  of its text, `note_sum`. A later export updates the notes you have not
  touched and skips every file you have edited by hand.
- **Errors are fixed once, for every note.** Fix the code, see what the fix
  does to every note with `notes baseline`, and rebuild only the affected
  notes with `notes export --marked`.
- **No note overwrites another.** Files are tied to their note by `note_id`,
  not by filename, so you can rename and move them. Notes with the same title
  get their own files (`title.md`, `title 2.md`).
- **Attachments and checkboxes are kept.** Attachments are copied next to the
  md file; checked state is read from `NoteStore.sqlite`.
- **The metadata comes along.** Creation date, folders, hashtags as `tags`,
  links between notes, and a date in the title as the filename date.
- **It is careful with your data.** It asks before writing, warns about large
  changes, skips "Recently Deleted", and stops safely on Ctrl-C.

## How it fits together

```
Apple Notes  ──(AppleScript)──▶  cache  ──(pandoc)──▶  md files
NoteStore.sqlite                 apple_notes.raw/  │    ~/notes/**/*.md
                                                   └──▶ baseline
                                                        ~/notes.baseline/<uuid>.md
```

1. **Cache.** `notes sync` fetches new and changed notes as HTML, so the
   conversion runs offline.
2. **md files.** `notes export` syncs, builds md files for new notes and
   updates the ones you have not edited. New notes land in `~/notes/import`,
   sorted by folder in Notes.
3. **Baseline.** `notes baseline` builds every note exactly as the export would,
   into `~/notes.baseline`, without touching `~/notes`. `git diff` there shows what
   a code change does before the real files are rebuilt, and the last line how
   many notes fail the check, now and before.

## The md files

```markdown
---
created_at: 2024-03-01
export: pass
note_id: 3f2a…
note_sum: 9c1e…
tags: [travel, food]
---

Content converted from Notes …

## Attachments
![image.png](assets/<media_uuid>.png)

## Internal links
- Other note → applenotes:note/…
```

- Filename: `YYYY-MM-DD title.md`, lowercase.
- Frontmatter fields you add yourself are kept on rebuild.
- Tables are deliberately not markdown tables: each cell gets its own line,
  with a blank line between the rows. A table with the rows Fruit/Price and
  Apple/10 becomes:

  ```
  Fruit
  Price

  Apple
  10
  ```
- `lang: nb` in the settings gives the headings `## Vedlegg` and `## Interne lenker`.

| `export` | Meaning                                              |
|----------|------------------------------------------------------|
| `pass`   | The content matches Notes                            |
| `fail`   | Text, URLs or attachments are missing                |
| `true`   | Marked for rebuild; becomes `pass`/`fail` when built |

## Commands

`notes` lists the commands; `notes <command> --help` shows the options.

| Command          | What it does                                                   |
|------------------|----------------------------------------------------------------|
| `notes export`   | Build new notes, update the ones you have not edited           |
| `--marked`       | Rebuild files with `export: true`                              |
| `--failed`       | Rebuild files with `export: fail`                              |
| `--assets`       | Rewrite only the attachment section, also in edited files      |
| `notes sync`     | Update the local cache of notes (export runs it first)         |
| `notes compare`  | Check, per folder, that every note in Notes has an md file     |
| `notes health`   | Find broken, orphaned and shared attachments, duplicate notes  |
| `notes prune`    | Delete the notes in Notes that you deleted from `~/notes`      |
| `notes baseline` | Convert every note to `~/notes.baseline` to test a code change |
| `notes report`   | Report the notes with `export: fail`, text masked, for an issue |
| `--baseline`     | The notes that fail in `~/notes.baseline` instead           |
| `notes config`   | Show the settings; the first time, create the config file      |

## Typical workflow

```
notes export               # 1. build new notes, update the ones you have not edited
                           # 2. mark files to rebuild: export: true in the frontmatter
notes export --marked      # 3. rebuild the marked files
git diff                   # 4. see what changed, then commit or discard
notes health               # 5. check that everything fits together
```

Commit `~/notes` before exporting, so everything can be rolled back. A git UI
such as [lazygit](https://github.com/jesseduffield/lazygit) makes it easy to
keep the changes you want and discard the rest. The same goes for
`~/notes.baseline`: `notes baseline` stops until the previous one is committed
or discarded.

### Example: fixing a conversion error

Pasted code lost its spaces: `if @client.save` became `if@client.save`. You fix
`lib/notes_md/common.rb` and check the fix on every note before any real file changes:

```
notes baseline
git -C ~/notes.baseline diff
```

Only the intended change? Commit it there, then rebuild the affected notes:

```
rg -l 'if@client' ~/notes | xargs perl -pi -e 's/^export: (pass|fail)$/export: true/'
notes export --marked
git -C ~/notes diff
```

A file you have edited by hand is left alone:

```
1 file(s) edited by hand since the export, not rebuilt.
```

## Installation

Requires macOS with Apple Notes, Ruby 3.0+, `pandoc` and `git`. A missing gem
or `pandoc` stops `notes` with one line saying what to install.

```
git clone https://github.com/finnove/notes-md.git ~/notes-md
cd ~/notes-md
brew install pandoc
bundle install
export PATH="$HOME/notes-md/bin:$PATH"        # also in ~/.zshrc
notes export                                  # creates ~/notes as a git repo the first time
```

The first time, macOS asks whether the terminal may control Notes; answer OK.
If reading `NoteStore.sqlite` fails, give the terminal Full Disk Access in
System Settings → Privacy & Security.

## Settings

`notes config` creates `~/.config/notes-md/config.yml` with every setting
commented out, and shows the settings that apply and where each comes from.
An environment variable changes a setting for one run.

| Setting                | Variable                     | Default                                    |
|------------------------|------------------------------|--------------------------------------------|
| `root`                 | `NOTES_ROOT`                 | `~/notes`                                  |
| `raw_cache`            | `NOTES_RAW_CACHE`            | `apple_notes.raw` in root                  |
| `import`               | `NOTES_IMPORT`               | `import` in root                           |
| `baseline`             | `NOTES_BASELINE`             | `~/notes.baseline`                         |
| `db`                   | `NOTES_DB`                   | the database of Apple Notes                |
| `lang`                 | `NOTES_LANG`                 | `en`; `nb` for Norwegian section headings  |
| `bold_line_as_heading` | `NOTES_BOLD_LINE_AS_HEADING` | `false`; `true`: a bold line becomes `##`  |
|                        | `NOTES_LIMIT_FOLDER`         | sync only this folder in Notes             |
| the file itself        | `NOTES_CONFIG`               | `notes-md/config.yml` in `$XDG_CONFIG_HOME` or `~/.config` |

## Tests

```
ruby test/export_test.rb
```

The tests use their own database and temporary folders, never real notes.

## Known behaviour

- The pandoc version affects the result; after an upgrade, run `notes baseline`.
- Locked notes must be unlocked in Notes before they can be fetched.
- Dates follow the machine's time zone. Set `TZ` (e.g. `TZ=Europe/Oslo`) to
  change it.
- Dates in titles are recognised with Norwegian month and weekday names
  ("2. januar 2025", "mandag").

## Reporting a note that fails

Run `notes report` and paste the output into a new issue. It has no text from
your notes: letters become `a`, digits `0`. Notes that fail in the baseline:
`notes report --baseline`.

## License

GPL-3.0, see `LICENSE`. Copyright (c) 2026 Finn-Ove Lium.

## Credits

Co-authored by Claude (Claude Opus 5.5), written with
[Claude Code](https://claude.com/claude-code).
