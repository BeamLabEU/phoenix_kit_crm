# PR #40: Run on core's shared toolkits: media on ResourceFolders, column choices on ViewPrefs (V7), actor and activity through core

**Author**: @mdon (merge `4f00ee5`, 19 commits)
**Reviewer**: Claude, single pass. Read the diff of the data layer (`SoftDelete`, `ServerOwnedMetadata`, migration V7, `Activity`, `ColumnConfig`), `Attachments` against core 2.38's `Storage.ResourceFolders` (`ensure/4`, `attach/2`, `detach/2`, `point_at/6`, `clear_pointer_if/4`), and the LiveView column-picker rewiring (`ColumnManagement`, `RoleView`, `OrganizationsView`, `MediaComponent`). Cross-checked V7 against core V201's `phoenix_kit_user_view_prefs` DDL, core's `phoenix_kit_settings` DDL, and the deleted `UserRoleView.scope_to_string/1`. Ran `mix precommit` and `mix test` against a live Postgres.
**Date**: 2026-09-25
**URL**: https://github.com/BeamLabEU/phoenix_kit_crm/pull/40

## Context

68 files, +4056 / −4930. CRM drops its own copies of what core 2.38 now
ships: folder-scoped media on `ResourceFolders`, per-user column choices on
`ViewPrefs` / `TableColumns` (with a one-time V7 copy out of
`phoenix_kit_crm_user_role_view`), the actor through `PhoenixKitWeb.Actor`,
and activity through `PhoenixKit.Activity.log/3`. Soft delete becomes a
single row-reading `UPDATE`, and `ServerOwnedMetadata` keeps `avatar_uuid` /
`trashed_from_status` out of the public changesets.

What checks out:

- **V7** — the key mapping `'crm.' || replace(scope, ':', '.')` produces
  exactly `ColumnConfig.view_key/1` for both old scope encodings
  (`organizations`, `role:<uuid>`); empty lists are skipped (CRM read them
  as "defaults", core reads them as "all hidden"); `ON CONFLICT DO NOTHING`
  lets an existing core choice win; the settings-row guard makes a replay a
  no-op; the settings insert supplies every NOT NULL column without a default.
  The JOIN on `phoenix_kit_users` avoids an FK failure for a user deleted
  since.
- **SoftDelete** — the status guard in the `WHERE` makes two concurrent trashes
  resolve to one `{:ok, _}` and one `{:error, :already_trashed}`, and
  `RETURNING` hands back the post-update row.
- **ServerOwnedMetadata** — merges against the row re-read `FOR UPDATE`
  inside `prepare_changes`, i.e. inside the write's transaction; strips both
  atom and string spellings.
- **LiveViews** — no new queries in `mount/3`; the column state is loaded in
  `handle_params/3` on connect; `RoleView` overrides `columns_saved/1` so the
  CRM-contact map is re-derived when the column set changes.
- **Media** — `set_avatar/3` checks-and-writes in one step and re-checks the
  record's status afterwards; removing an image clears the avatar only while
  it is still that image.

## Findings

### 1. BUG - MEDIUM — trash / restore stopped bumping `updated_at`

The old path was `SoftDelete.trash_changeset/2 |> repo().update()`, and
`Repo.update/1` on a schema with `timestamps()` sets `updated_at`. The new
`update_all` sets only `status` and `metadata`, so trashing or restoring a
contact or company left `updated_at` at its last edit. Nothing in `lib/`
sorts by it today, but it is the record's audit timestamp and hosts may read it.

**Fixed**: both queries now also `SET updated_at` (UTC, second precision to
match `:utc_datetime`), `RETURNING` it, and the struct handed back carries
it. Two tests in `soft_delete_test.exs` pin the bump for trash and restore.

### 2. NITPICK — `ResourceFolders.point_at/6` / `clear_pointer_if/4` do not bump `updated_at` either

Setting or clearing an avatar is an in-place JSON write in core, so the
record's `updated_at` does not move. Left as is: that is core's write path
and the avatar is media, not a record edit; noted so the asymmetry with
soft delete is on record.
