# PR #37: Media reorganizer source for contacts, companies and interactions

**Author**: @timujinne (merge `d84a51a`, branch `timujinne/feat/media-reorganizer`, 10 commits, five review rounds already folded in)
**Reviewer**: Claude, single pass. Read the full diff with surrounding context and checked it against the contract it implements, as shipped in core 2.24.0 (now in `mix.lock`): `PhoenixKit.Modules.Storage.Reorganizer.Source` (the rules in its moduledoc), `Reorganizer.Action.new!/1` / `noop?/1`, the engine's `collect/3` error isolation, and `ModuleRegistry.all_media_reorganizers/0`. Also cross-checked `PhoenixKitCRM.Attachments` (the hook call and by-name lookup the plan has to agree with) and the column nullability in `PhoenixKitCRM.Migrations`. Ran the gate and `mix test` against a live Postgres.
**Date**: 2026-09-16
**URL**: https://github.com/BeamLabEU/phoenix_kit_crm/pull/37

## Context

3 files, +1913. Adds `PhoenixKitCRM.MediaReorganizer.plan/2` and registers it
through `PhoenixKitCRM.media_reorganizer/0`. The plan produces `:move` actions
for contacts, companies and interactions whose legacy `crm-*-<uuid>` folder is
not yet under the host's `:attachments_parent_folder` parent. It produces
`:report` actions for duplicates, relocated copies, hook failures,
`nil`-answer suppressions and orphans.

The Source contract checks out: no hook configured means reports only; the
hook is called only for candidates; hook answers are cast and downcased; an
uncallable config is a `:hook_error`; a `nil` answer never pulls a folder to
root; orphan scope is root plus the parents successful hook calls returned;
by-name lookups skip trashed folders; counts include every file row; queries
are batched, with none run per record; ordering is deterministic. The hook
receives only the record uuid, never the struct, so the contract's
"reload the full row before calling the hook" rule does not apply. Every
action key is one `Action` knows about. One real bug was found.

## Findings

### 1. BUG - MEDIUM — a contact or company with a NULL `name` produced an invalid action

`record_label/1` returned `c.name` as-is for contacts and companies. Only the
changeset requires `name`: the `phoenix_kit_crm_contacts.name` and
`phoenix_kit_crm_companies.name` columns are nullable (`VARCHAR(255)` with no
`NOT NULL`), so rows written outside the changeset, such as older core-era
data or raw imports, can have `name IS NULL`. Core's `Action.new!/1` raises
unless `label` is a binary. The engine isolates the raise, but the record's
`:move` (or `:duplicate` / `:relocated` report) becomes an `:invalid_action`
report, and that folder is never reorganized. The interaction clause already
fell back to the uuid when `subject` was blank.

**Fixed.** All three kinds now go through `label_or_uuid/2`, so a `nil` or `""`
name/subject falls back to the record's uuid. Tests added: a nameless contact
and company are labeled by uuid; every action a mixed plan produces (moves plus
an orphan) passes core's `Action.new!/1` with no unknown keys.

### 2. NITPICK — comments still said core does not ship the engine

The moduledoc and the `media_reorganizer/0` comment said "today's hex core
(2.23.x) does not ship the engine yet" and that the only follow-up was adding
`@behaviour`/`@impl`. Core 2.24.0 ships it and is what the lock resolves.

**Fixed (comments only).** `@behaviour`/`@impl` are still deliberately left off:
the `:phoenix_kit` requirement is `~> 2.0`, so a host can resolve an older core
where neither the behaviour module nor the callback exists and the annotations
would warn. This is the same reasoning already used for `js_sources/0`. They
can be added once the requirement is raised to `~> 2.24`.

### 3. NITPICK — a `nil` hook answer with copies at root and elsewhere is a `:duplicate`, not root-current plus `:relocated`

When the hook answers `nil` (root), the contract's pointer-less rule reads as
follows: a copy at root is the current folder, and any copy elsewhere is
reported `:relocated`. `resolve_entry_nil_hook/2` instead reports every live
copy as one `:duplicate` whenever more than one exists.

**Not fixed, deliberately.** Nothing moves either way. The PR documents this
choice in the moduledoc (F1): with no pointer and a `nil` answer, which copy
is current is not clear. A `:duplicate` asks a human to decide, which is the
safer report.
