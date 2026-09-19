---
name: envy-notes
description: >-
  Read, search, create, and edit notes in an Envy vault (the macOS notes app at
  envynote.app) — a local folder of plain Markdown files. Use whenever the user
  wants to work with their Envy notes: capture a thought, find or update a note,
  add or follow links, tag or set due dates, or file notes into folders.
---


# Working with an Envy vault

This file is the guide for AI agents working with an **Envy** vault (the macOS
notes app at envynote.app). An Envy vault is a plain folder of Markdown files —
there is **no API, URL scheme, or CLI**; you work directly with the `.md` files.
One note is one `.md` file, and the **filename (without `.md`) is the note's
title**. Files are plain UTF-8 Markdown with **no YAML frontmatter** — never add
any.

Envy watches the folder, so notes you create or edit appear in the app live, and
edits made while it's open are picked up automatically. Everything here is
ordinary file work.

## Where the notes are

If you are reading this as `AGENTS.md`, **the folder this file sits in is the
vault** — work relative to it.

Otherwise (e.g. you loaded this as a global skill), find the vault on the user's
Mac with:

```bash
defaults read com.skylerschoos.envy indexPath
```

That prints the vault's absolute path. If it errors or is empty, ask the user
where their Envy notes live rather than guessing. (Some users keep several
folders in `notesDirectoryPaths`, newline-separated; prefer `indexPath`.)

## Folders to leave alone

These folder names at the vault root are **reserved** — Envy manages them and
they are not ordinary notes. Never scan them for content, and never create notes
in them (except `Inbox`, on purpose):

- `Templates/` — note templates
- `Trash/` — deleted notes awaiting sweep
- `Attachments/` — image/file attachments
- `Envy Data/` — Envy's own bookkeeping
- `Inbox/` — fleeting/unfiled captures (you may add here deliberately)

Also skip dot-files and dot-folders. (This `AGENTS.md` guide is itself hidden
from the notes list by Envy.)

## Reading and searching

- **Read a note:** read `<vault>/<Title>.md` (or `<vault>/<Folder>/<Title>.md`).
- **Search content:** grep/ripgrep under the vault, excluding reserved folders:
  ```bash
  rg -l --glob '!{Templates,Trash,Attachments,Envy Data}/**' 'search terms' "<vault>"
  ```
- **Find by title:** list `*.md` filenames.
- **Tags** are `#word` inline in a note's text. **Due dates** are `@2026-04-16`
  or `@04-16-26` inline. **A note's folder is its category** — no metadata file;
  the containing directory is the whole truth.

## Creating a note

Write a new `.md` file; the filename is the title.

- Vault root: `<vault>/Meeting notes.md`
- Into a folder (created if missing): `<vault>/Work/Q3 plan.md`
- **Capture as a fleeting note** to triage later: `<vault>/Inbox/<title>.md`

Keep the body plain Markdown; don't add a title heading unless asked — the
filename is already the title.

## Editing a note

Edit the `.md` in place, preserving the user's Markdown; change only what was
asked. Standard syntax renders live: `**bold**`, `*italic*`, `# headings`,
`- lists`, `- [ ] tasks`, `> quotes`, fenced code, and pipe tables (which render
as an editable grid in the app).

## Links, embeds, tags, due dates

- **Link to a note:** `[[Note Title]]` (resolves by title); `[[Note Title|shown
  words]]` to display different text. A link to a not-yet-existing note is fine
  — Envy shows it dimmed until created.
- **Embed a note inline:** `![[Note Title]]` on its own line, blank line after.
- **Embed an image:** `![[picture.png]]` (files live in `Attachments/`).
- **Tag:** `#tag` anywhere in the text.  **Due date:** `@2026-04-16` anywhere.
- **Footnote:** `text[^1]` with `[^1]: definition` elsewhere in the note.

## Renaming or moving — update links yourself

Envy rewrites `[[links]]` and `![[embeds]]` automatically **only for renames
done inside the app.** If you rename or move a `.md` file on disk:

1. Change the file (rename, or move to another folder).
2. Search the whole vault for `[[Old Title]]` and `![[Old Title]]` and rewrite
   them to the new title, **preserving any `|alias`**.

Moving between folders doesn't change the title, so links keep resolving — only
a title change needs the rewrite.

## Don't

- Don't add YAML frontmatter or any metadata block — notes are pure Markdown;
  the folder is the category and tags are inline.
- Don't write folder/tag colors into files; those are Envy preferences.
- Don't touch reserved folders' contents.
- Don't hard-delete by unlinking unless asked; prefer moving to `Trash/` so the
  user can restore from the app, or just ask.
