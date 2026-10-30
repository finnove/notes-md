# notes-md

@README.md

## Rules

- The md files are the source of truth; differences from a fresh conversion are expected, not bugs.
- Never suggest an export that overwrites edited md files.
- Never run `notes` against the user's notes; the user runs export and baseline.
- Keep work in the cache step; never move it back to AppleScript.
- Never write hidden files or folders.
- English everywhere, including output and commit messages; prompts use `[y/N]`.

## Standard

- De facto standard and best practice guide the choices; say so when deviating.
- Tests first (Minitest). Never real API calls in tests.
- Never secrets in plain text in the repo.
- Short and concise: bullet lists, no repeating the README or the code.

## Tests

- Also run against the latest pandoc release (Linux tarball in a temp dir, first in `PATH`).
- Newer pandoc drops the character after a backslash before punctuation; `common.rb` works around it.

## Commit

- After a conversion change: rebuild only the `export: fail` notes in memory (`build_md`) first.
- Then the user runs `notes baseline`.
- Commit only when the fail count has not risen and the diff shows only the intended change.

## Release

- Tag `vX.Y.Z` with the `notes-md-release` skill.
- No Homebrew files here; the formula lives in the tap repo.
