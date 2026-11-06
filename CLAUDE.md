This repository owns TapeUp, a macOS menu-bar recorder that captures computer
audio and the default microphone together and saves each recording as a
self-describing folder for agents to process later. It is built with agents and
will be public under MIT; everything committed here must be safe to publish.

`_docs/SYSTEM.md` is the design authority for purpose, boundaries,
architecture, invariants, and decisions. This file is its lean operational
projection and loses on disagreement.

After this file, read `_docs/STATE.md`, then any active artifact it names, in
full. Never proceed from a mid-session summary alone when a project document
exists; summaries are lossy and settled state is on disk.

## Public repository, private notes

Never commit people's names, personal context, private paths, or the
maintainer's private discussions. Those live in the maintainer's private
notes. On the maintainer's machines an uncommitted `CLAUDE.local.md` points to
them; read it when present, and keep anything derived from it out of commits
unless it is public-safe.

## Verification

Run `make verify-fast` after source changes. It covers the hook activation
check, `swift format lint`, the debug build and the unit tests.

After any change to the app's interface or recording flow, run
`make uitest` on the Mac and look at the pictures it saves in `tmp/uitest`.
It drives the real panel through every flow, records a few seconds for real,
and fails on a panel that is cut off, see-through or jumping. Add a step to
`Sources/TapeUp/App/UITest.swift` for every new flow.

Run `make verify-full` before declaring work complete. It includes fast
verification plus the signed app bundle build and the osv-scanner dependency
audit.

## Git

Use Conventional Commits: `<type>(optional-scope): imperative summary`.
Standard types are `feat`, `fix`, `docs`, `refactor`, `test`, `chore`,
`build`, `ci`, `perf`, `style`, and `revert`. Project-specific commit types or
scope rules override this default.

Before any forceful or destructive operation, inspect exactly what would be
lost. Treat unrelated modified, deleted, or untracked paths as intentional;
stage only current-task changes.

This repository syncs by default: after relevant verification passes, commit
and push coherent current-task changes without asking again. An uncommitted
change is an unprotected change.

## Skills

Skills are declared in `.claude/skills.manifest.yaml`. If the `kk-skills`
command exists, run `kk-skills sync` at session start and follow its `NEXT:`
line; otherwise skip this. Linked skills are local state and never committed.

The `mattpocock-*` skills supply technique, never layout. Where one names a
glossary (`GLOSSARY.md`, `CONTEXT.md`), read `_docs/SYSTEM.md` § Glossary if
it exists. Where one names ADRs or `docs/adr/`, the decisions are
`_docs/SYSTEM.md` and `_docs/_discussions/`. Where one names an issue
tracker, a spec, `.scratch/`, or `docs/agents/issue-tracker.md`, the work
record is `_docs/STATE.md`, `_docs/_discussions/`, and the commit and PR
history; take specs from there instead of running setup. Never create
`GLOSSARY.md`, `CONTEXT.md`, `docs/adr/`, `docs/agents/`, or `.scratch/`.

## Artifact Rules

Every hand-authored Markdown artifact must place all six fields below in one
contiguous opening metadata block. Optional YAML frontmatter and one H1 may
precede the block; prose and H2 sections may not. Use `None` when a
relationship was checked and does not exist.

**Status**: draft | design | ready-for-impl | implemented | superseded
**Prior art**: [link] — description; [link] — description | None
**Supersedes**: [link] — what this replaces and why; [link] — ... | None
**Implements**: [link] — the design or vision this executes; [link] — ... | None
**Extends**: [link] — what this builds on; [link] — ... | None
**Related**: [link] — relationship description; [link] — ... | None

Every hand-authored artifact must end with `## How to update this document`
(forward-looking update guidance, never a changelog) followed by
`## Open Questions` (`None currently` when empty). When one supersedes another,
update both sides of the lineage. Backfill missing fields or sections when an
artifact is encountered.

Generated files, upstream-owned files, licensed non-editable files, and
finished output documents are exempt. Raw source captures are also exempt:
preserve them verbatim and add
`> Raw source material — exempt from artifact rules; consumed by: <link(s)>`
when a consuming artifact exists.

Design discussions live in `_docs/_discussions/` with
`YYYY-MM-DD-<topic>.md` names, or a same-named folder when supporting material
must travel with the discussion. When architecture, invariants, or design
decisions change, update `_docs/SYSTEM.md` in the same change.

Each fact has one canonical home. Operational files may carry a deliberately
sized projection with an explicit precedence pointer; they must not become an
unmarked second authority.

## Working files and outputs

- Use a system temporary directory or the repository's ignored `tmp/`
  directory for disposable intermediates, including test recordings.
- Put durable evidence and supporting artifacts for bounded design or research
  work beside the discussion that owns them, usually under
  `_docs/_discussions/<YYYY-MM-DD-topic>/`. Audio evidence stays out of Git.
- Put generated deliverables meant to be inspected or retained, but which are
  not canonical project documentation, under `_output/<skill-or-tool>/`.
  `_output/` is local by default; commit an output only when it is itself a
  requested repository artifact.

## Nested folder instructions

Before creating folder-level orientation or instructions, inspect the inherited
instruction chain. A child folder does not become a standalone workspace merely
because it exists. If the parent rules already cover the work, create neither a
nested instruction pair nor a README/index as substitute orientation.

If a future agent will need to maintain a folder or the documents in it, give
that folder its own `CLAUDE.md` plus an `AGENTS.md` symlink. The harness loads
the instruction when an agent works with files in that folder; a README or
index helps only when the agent already knows to open it. Keep the instruction
to folder-specific rules and pointers, update it as the folder's needs change,
and never copy root instructions downward.

Before writing a nested instruction, simulate that agent's cold start. The
agent receives the root instruction and every intermediate instruction along
with the nested file, so write only what is new at this level. If a rule is
missing from the outer layers but applies more broadly, add it at the broadest
scope where it is true instead of duplicating it here.

## How to update this document

Keep this file limited to instructions and orientation needed on every run.
Put design rationale in `_docs/SYSTEM.md`, current activity in
`_docs/STATE.md`, and folder-specific rules in nested `CLAUDE.md` files.
Re-project canonical blocks from their named sources rather than editing them
independently.

## Open Questions

None currently.
