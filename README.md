# daily-digest

A small, dependency-light generator that writes a structured morning digest
into an Obsidian vault. Each day it drops a markdown note containing:

- Current weather (wttr.in, with retry + plain-text fallback)
- Quote of the day (zenquotes.io, falling back to a local quotes file)
- Git activity across configured repo folders (last 24h)
- Open GitHub PRs you authored, and those awaiting your review
- News headlines from any RSS/Atom feeds you configure
- Placeholder sections for tasks and calendar (wire up as you like)

Idempotent per day — safe to re-run.

## Requirements

- `bash` (4+)
- `curl`, `jq`, `git`, `find`, `sed`, `grep`, `date`
- `python3` (stdlib only — used to parse RSS/Atom feeds for the News section)
- [`gh`](https://cli.github.com/) CLI, authenticated, for the PR section
- An Obsidian vault (or any directory; the script just writes markdown)

## Install

From the repo root:

```bash
./install.sh              # symlinks ~/bin/daily-digest -> this repo
./install.sh copy         # or copy it instead
```

This also scaffolds `~/.config/daily-digest/config.env` from the example if
one doesn't exist yet. Edit it before the first real run.

## Configuration

All settings live in `~/.config/daily-digest/config.env` (respects
`$XDG_CONFIG_HOME`). See [`config.env.example`](config.env.example) for
the full list. At minimum you need:

- `VAULT` — absolute path to your Obsidian vault
- `LOCATION` — city name for weather
- `GH_USER` — GitHub username for PR searches

Point `DAILY_DIGEST_CONFIG` at a different file to use an alternate config.

## Scheduling

The script isn't self-scheduling. A 5am cron entry:

```cron
0 5 * * * $HOME/bin/daily-digest >> $HOME/.local/share/daily-digest.log 2>&1
```

If the machine isn't awake at 5am, the script can safely be run manually
later — it will detect that today's file already exists and exit cleanly.

## Output shape

Writes to `$VAULT/$DAILY_SUBDIR/YYYY-MM-DD.md` (default
`10-Daily/YYYY-MM-DD.md`). Includes YAML frontmatter (`date`, `tags`,
`generated` timestamp). The script is idempotent per day — it will not
overwrite a file that was already written today.

## Design notes

- **Atomic writes.** The script renders to a temp file and moves it into
  place, so Obsidian never observes a half-rendered digest.
- **Graceful degradation.** Each section handles its own failure (network
  errors, missing auth, absent config) with a human-readable placeholder
  rather than aborting the whole run.
- **Pluggable surfaces.** News is config-driven (`NEWS_FEEDS` in
  `config.env`) so you can swap sources without editing the script. Tasks
  and calendar are still placeholders — wire them up to whatever source
  you use.

## License

MIT. See [LICENSE](LICENSE).
