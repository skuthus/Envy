# Envy agent guide

Instructions that teach an AI agent how to work with an Envy vault — read,
search, create, and edit notes as plain Markdown files, following Envy's
conventions (`[[wiki-links]]`, `#tags`, `@due-dates`, `![[embeds]]`, the Inbox)
and leaving Envy's reserved folders alone. Envy has no API, so it's all ordinary
file work on the `.md` files in your Index.

## How it reaches "any agent"

There's no single standard every agent auto-loads, so the guide lives **with the
notes** instead of inside one tool's private config: it's written as
**`AGENTS.md` at the root of your vault.** Any agent that works on your notes is,
by definition, working in that folder — so it finds the guide there.
AGENTS.md-aware tools (Codex, Cursor, Zed, Amp, …) read it automatically; any
other agent sees a plainly-named file the moment it lists the folder. Envy keeps
this `AGENTS.md` out of your notes list, so it never shows up as a note.

## Install it from Envy (recommended)

In the app: **File → Install Agent Guide…**. That writes:

- `AGENTS.md` into your vault (the universal copy above), and
- `~/.claude/skills/envy-notes/SKILL.md`, a Claude Code skill, so Claude Code
  also auto-surfaces it with zero setup.

## Install it manually

The same two files live in this folder:

- `AGENTS.md` — copy into the root of your Envy vault.
  ```bash
  cp agent-skill/AGENTS.md "$(defaults read com.skylerschoos.envy indexPath)/AGENTS.md"
  ```
- `envy-notes/SKILL.md` — the Claude Code form; copy into your skills dir.
  ```bash
  mkdir -p ~/.claude/skills && cp -R agent-skill/envy-notes ~/.claude/skills/
  ```

## Any other agent

The guide is a single self-contained Markdown file (`AGENTS.md`). Point your
agent at it, or paste its contents in as instructions — it needs nothing but the
ability to read files and run shell commands.
