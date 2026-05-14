# `docs/`

Implementation history for the sandbox itself. None of these files are required to build or use the image — they document how it got here.

## `docs/superpowers/`

The `superpowers` Claude Code plugin offers a `/superpowers:writing-plans` workflow that produces structured spec + plan documents before any code is touched. The repo uses that workflow for non-trivial sandbox changes; the resulting markdown is checked in so future contributors (human or AI) can see the reasoning trail.

| Subdirectory | Contents |
|--------------|----------|
| `specs/`     | Design documents — what is being built and why, with constraints and alternatives considered. |
| `plans/`     | Step-by-step execution plans derived from a spec — what gets edited, in what order, with verification gates. |

File naming convention: `YYYY-MM-DD-<topic>-<kind>.md` (e.g. `2026-05-13-bake-claude-plugins-and-openspec-design.md`).

Treat these as historical artifacts, not API contracts. They are not regenerated when the code changes; if a spec or plan diverges from the current implementation, the current implementation wins. They are useful for "why did this end up this way?" questions, not for "what does this do today?" — for the latter, read the code or `CLAUDE.md`.
