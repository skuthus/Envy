# Roadmap

Features under consideration, not yet started. Deliberately holding off on implementation to use Envy day-to-day for a while first and see what actually comes up in practice, rather than building ahead of real need.

## Planned

- **Browse the Trash** — a real list/table of everything currently deleted, so any of it can be restored, not just the most recent delete action (today's `⌘⇧⌫` only undoes the last delete).
- **Note merging** — combine two (or more) notes into one, for the "oops, I made a duplicate" case.
- **Backlinks panel** — a panel showing which notes link *to* the currently-open note. Envy already resolves `[[wiki-links]]` outward; this is the missing inward direction.

## Why these three

Landed on this list after surveying the NV lineage (nvALT, nvUltra, FSNotes, nvPY, Simplenote) and modern note apps (Obsidian, Logseq, Zettlr, Joplin, Standard Notes, Bear, iA Writer, Ulysses, Typora, Quiver). All three show up repeatedly across competitors, address a real gap in Envy today, and fit its flat-file/keyboard-first philosophy without requiring an architecture change (unlike, say, a plugin system or graph view).
