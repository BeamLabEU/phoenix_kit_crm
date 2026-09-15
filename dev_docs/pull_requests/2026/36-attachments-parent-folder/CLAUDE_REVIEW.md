# PR #36: Attachment folders under a host-configured parent

**Author**: @timujinne (merge `c09bf2c`, branch `timujinne/feat/attachments-parent-folder`, 2 commits: `1c1b641` failing tests, `da579c0` implementation)
**Reviewer**: Claude, single pass. Read the full diff with surrounding context and every `PhoenixKitCRM.Attachments` call site (`MediaComponent`, `ContactShowLive` / `CompanyShowLive` avatar pickers, `Interactions` attach/purge, `InteractionsComponent` timeline). Checked core's `Storage.create_folder/2`, the `Folder` schema and the `phoenix_kit_media_folders_name_parent_idx` unique index. Ran the gate and `mix test` against a live Postgres.
**Date**: 2026-09-15
**URL**: https://github.com/BeamLabEU/phoenix_kit_crm/pull/36

## Context

3 files, +269/-20. Before this PR every CRM attachment folder
(`crm-contact-<uuid>`, `crm-company-<uuid>`, `crm-interaction-<uuid>`) lived at
the storage root. The PR adds
`config :phoenix_kit_crm, :attachments_parent_folder, {mod, fun}`. The hook is
called as `fun(kind, actor_uuid, subject)` (or `/2`) and returns
`{:ok, parent_uuid} | nil`, so new folders can be grouped under per-type
containers. Lookups check the configured parent first and then the root, so
folders created before the setting are still found.

The goal and the "never adopt, never twin" rule are sound. Four problems were
fixed after merge.

## Findings

### 1. BUG - HIGH — a host's root-level `Images` folder was used as every record's Images folder

The PR changed the private `get_folder(name, parent_uuid)` so that, for a
non-nil parent, it falls back to the **storage root**:
`get_folder_under(name, parent) || get_folder_under(name, nil)`. The fallback
was meant for the record folders, whose names are unique. But
`ensure_folder(_, _, :images, _)` uses the same helper for its
`find_or_create("Images", record_root, actor)` call. `Images` is a
common, non-unique name. If the host media library has its own top-level
`Images` folder, and the record's own subfolder doesn't exist yet (every
record's first image upload, or opening its avatar picker):

- `ensure_folder(:images)` returns the **host's** `Images` folder, and no subfolder is ever created.
- `MediaComponent` assigns it as `folder_uuid`, so the picker uploads into the
  host folder. The tab then lists the host folder's images, and **Remove**
  runs `detach/2` against it, which soft-trashes a sole-owner file. So a CRM
  user could trash the host's own media from a company's Images tab.
- On the next render `folder_uuid(:images)` resolves strictly (`get_folder_under`) → `nil`, so the uploads disappear from the tab and `set_avatar/3` rejects them with `:not_record_image`.

This is not tied to the new setting. The fallback runs for any non-nil parent,
so hosts that never configure the hook are affected too.

**Fixed.** `find_or_create/4` now takes its lookup function. Record folders use
the name-based resolver. The `Images` subfolder uses `get_folder_under/2`,
which only looks inside the record folder, both for the lookup and for the
re-lookup after a lost create race. Test: *"a host's own root-level Images
folder is never used as a record's Images folder"* (fails on the PR's code).

### 2. BUG - MEDIUM — lookups ignored the parent a folder was actually created under

The hook receives `actor_uuid`, and `ensure_folder/4` /
`ensure_interaction_folder/2` pass the real actor. Every read path passes
`nil`: `folder_uuid/3` from `MediaComponent.update/2`, `avatar_candidate?/3`,
`purge_media/2`, `interaction_folder_uuid/1`, `list_files_by_interaction/1`
and `purge_interaction_media/1`. A hook whose answer depends on the actor is
exactly what that argument invites (per-user containers, or `nil` when there
is no actor). With such a hook, a folder is created under `parent(actor)` but
looked for under `parent(nil)` and then the root:

- The Media tab showed nothing after a successful upload.
- `set_avatar/3` returned `{:error, :not_record_image}` for the record's own images.
- A permanent delete did not find the folder, so its whole subtree leaked.
- A second actor with a different parent created a twin, breaking the PR's own "no twin ever created" promise.

The same stranding happens with an actor-independent hook whenever the parent
changes after folders exist: the host points at a different container, or an
admin moves a record folder in `/admin/media`. Folders are now far more
likely to be moved, because containers exist.

**Fixed.** The parent now only decides where a **new** folder is created. A
record folder is resolved by its deterministic name wherever it lives, in one
query ordered by preference: under the configured parent, then at the root,
then the oldest elsewhere (`prefer_parent/2`). This keeps the PR's rule that a
nested folder beats a root twin, and the existing twin test still passes. Test:
*"an actor-dependent parent: reads without an actor find the folder, no actor
twins it"*, which also covers purge (fails on the PR's code).

### 3. BUG - MEDIUM — the timeline started ignoring trashed folders, but the composer still wrote into them

`list_files_by_interaction/1` gained `is_nil(f.trashed_at)`. The single-folder
resolver that `ensure_interaction_folder/2` uses has no such filter (neither
before nor after the PR). If an interaction folder was trashed in
`/admin/media`, files attached on a later interaction edit went into that
trashed folder and then never showed on the timeline. Before the PR both paths
ignored `trashed_at`.

**Fixed.** The batch listing now uses the same resolution and ordering as the
single resolver (`DISTINCT ON (name)` plus `prefer_parent/2`), so the timeline
and the composer always agree on the folder. That restores the pre-PR handling
of trashed folders. Whether a trashed CRM folder should be skipped entirely,
with a fresh one created, is a separate decision for both paths at once. It is
not made here.

### 4. IMPROVEMENT - MEDIUM — `subject` was documented but never passed

The moduledoc and the `/3` arity promise a `subject` argument, but no call
site passed one, so it was always `nil`. **Fixed:** every per-record call now
passes the record's uuid (`interaction_uuid` for interactions). The batch
timeline listing makes a single subject-less call, because it covers many
interactions. That is harmless now that resolution does not depend on the
hook's answer (finding 2). The moduledoc says so, and adds that the hook runs
on reads too, so it must be cheap.

### 5. NITPICK — a stale parent uuid breaks uploads (not fixed)

If the hook returns the uuid of a folder that no longer exists, for example a
container deleted in `/admin/media`, `Storage.create_folder/1` fails
`foreign_key_constraint(:parent_uuid)`. The re-lookup finds nothing, and
`ensure_folder` returns `{:error, :folder_unavailable}`, so the picker flashes
"Could not prepare the media folder." Existing folders still resolve (deleting
the container sets their `parent_uuid` to NULL). Silently falling back to the
root would hide the host's misconfiguration and scatter new folders, so the
loud failure is left as is. The hook owns its container's lifecycle.

### 6. NITPICK — CHANGELOG entry under `## Unreleased`

This is fine for a feature PR (the repo's rule: versions land with the release
commit). It was folded into the release entry.

## Verification

- New tests fail on the PR's `attachments.ex` (2 failures) and pass on the fix. The PR's six tests still pass unchanged.
- `mix precommit` and the full `mix test` pass (see the release commit).
