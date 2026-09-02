# PR #32: CRM 2026-09-01 todo — overview redesign, honest filter strips, company-anchored interactions (V05)

**Author**: @mdon (merge `08a3e30`, branch `mdon/main`, 3 commits: `4e40667`, `e108994`, `28cca07`)
**Reviewer**: Claude, single pass — full diff read line-by-line with surrounding context, source-of-truth cross-checks (`PartyRole.roles/0`, `Company.statuses/0`, `Contact.statuses/0`, the party-roles unique index, the V01 FK cascade definitions, core's `layout_wrapper` `page_action` contract), plus real execution of the project's gate (`mix quality.ci` = `format --check-formatted` + `credo --strict` + `dialyzer`) and `mix test` against a local `phoenix_kit` core checkout and a live Postgres instance
**Date**: 2026-09-02
**URL**: https://github.com/BeamLabEU/phoenix_kit_crm/pull/32

## Context

Three strands in one PR, 41 files, +4752/-1840 (about half of that regenerated gettext):

1. **V05 — the interaction ANCHOR.** `phoenix_kit_crm_interactions` gains a
   `company_uuid` arm; `contact_uuid` loses `NOT NULL`; a DB CHECK
   (`num_nonnulls(contact_uuid, company_uuid) = 1`) pins exactly one anchor.
   The anchor is immutable after create — `Interaction.changeset/2` is now
   create-only (the only one that casts anchor fields) and
   `Interaction.update_changeset/2` is its edit twin. `CompanyInteractionsComponent`
   (a read-only member rollup) is deleted and `InteractionsComponent` becomes
   dual-anchor: it serves the contact page and the company page, with an
   `All | Company | People` scope filter in company mode.
2. **Honest filter strips.** Both index pages default to `all` instead of a tab
   labelled "Active" that actually meant "not trashed". Every tab carries a
   search-independent count from one grouped query; tabs render only when they
   have results (or are the current filter); a tab click resets search.
3. **Overview redesign.** `CRMLive` drops the four count cards and the "Portal
   access" role list (moved to the settings page, where the counts and portal
   links now live) for hero cards, a by-role band, a conditional
   needs-attention row (`?filter=no-contacts`), and a recent-interactions feed.

Supporting work: cascade cleanup for hard-deleted parents (the FK CASCADE
bypassed the media purge + deletion broadcast), a company interaction-feed
PubSub topic, `set_enabled/3` activity logging, three duplicated private
helpers hoisted into `InteractionHelpers`, and two rescue clauses made loud.

## Findings

### Verified correct — the parts most likely to be wrong, and why they are not

These are the checks the diff invites, done against the producing code rather
than the PR description. Recording them because each one is a place a future
change can silently break, and the reasoning is not obvious from the diff.

1. **The anchor rule is enforced in all three layers, and they agree.**
   Changeset `validate_anchor/1` (errors land on `:contact_uuid` and
   `:company_uuid`, both visible form fields) → `check_constraint` naming
   `phoenix_kit_crm_interactions_anchor_xor` → the DB CHECK itself. The
   constraint name in `interaction.ex:79` matches the one
   `migrations.ex:v5_statements/2` creates. `update_changeset/2` casts
   `@castable -- @anchor_fields`, so an edit cannot retarget a row.
   `change_interaction/2` dispatches on `uuid: nil` so a form never gets the
   wrong one.

2. **No query inner-joins `contact` any more** — the failure mode AGENTS.md
   now warns about, which would silently drop every company-anchored row.
   `list_involving/1`, `list_recent/1` and `list_for_company/2` all LEFT JOIN.
   Their `WHERE` clauses are correct under SQL three-valued logic: in
   `list_recent/1`, `(contact_uuid IS NOT NULL AND c.status <> 'trashed') OR
   (company_uuid IS NOT NULL AND co.status <> 'trashed')` evaluates to the
   intended boolean for each of the four anchor/status combinations, because
   the `IS NOT NULL` guard short-circuits the `NULL` comparison on the arm
   that is not in play.

3. **`PartyRoles.role_counts/1` really does agree with the index it links to.**
   The docstring claims each number matches the no-options
   `count_companies_with_role/2`. It does: both apply `in_force/1` and exclude
   trashed holders, and `count(pr.uuid)` cannot double-count a roleable because
   migration V04 added `UNIQUE (roleable_uuid, role) WHERE is_active`. Without
   that partial index the grouped count and the uuid-set count would diverge
   for any roleable holding two in-force rows for one role.

4. **The two lists that must stay in sync do.** `CRMLive.role_defs/0` names
   `supplier`/`manufacturer`/`customer`/`partner` and reads them back with
   `Map.fetch!/2` (a raise, not a silent zero) against `PartyRole.roles/0` =
   `~w(supplier customer partner manufacturer)`. The strip's "All" count is
   `active + inactive`, which equals "everything not trashed" exactly because
   `Company.statuses/0` and `Contact.statuses/0` are both `~w(active inactive)`
   — if a third status is ever added, `status_counts/0` will return it but the
   "All" label will under-count. Worth remembering; not wrong today.

5. **`page_action` and `row_link` exist in the *released* core**, not just the
   local checkout. `deps/phoenix_kit` (2.13.18) carries both
   `layout_wrapper.ex`'s `page_action` attr and
   `components/core/row_link.ex`. Removing `CompanyShowLive`'s in-body header
   band therefore does not strand the Edit affordance on a published install.

6. **`delete_interaction` got strictly stricter.** It was one gate (row is in
   this feed); it is now two (row is in this feed AND this page is its anchor).
   A contact page can no longer delete an interaction it merely appears in as
   a party, and a company page cannot delete a member's own. The
   `Ecto.StaleEntryError` rescue covers the two-sessions-race.

7. **Uploads.** `known_upload_accept/0` filters `@upload_accept` through
   `MIME.has_type?/1` — every entry begins with `"."` so the `fn "." <> ext`
   clause is total. `maybe_allow_upload/1` is idempotent across re-`update/2`
   via `uploads_allowed?/1`, so `allow_upload` is never called twice for
   `:attachments`. Every `@uploads.attachments` reference in the template
   (including the two new `upload_errors/1,2` sites) sits inside the
   `:if={@can_attach}` block, and HEEx `:if` does not evaluate its children —
   no `KeyError` when Storage is off.

8. **Cascade cleanup is ordered correctly.** `collect_for_cascade/2` runs
   inside the transaction *before* `repo().delete`, with `:parties` preloaded
   so the post-commit `broadcast_interaction/2` can still reach every involved
   contact after the rows are gone. `interaction_parties.contact_uuid` is
   `ON DELETE SET NULL`, so deleting a contact leaves the party rows renderable
   via their frozen `raw_name` — no orphaned-render path.

9. **Activity routing follows the anchor.** `log_interaction/3` writes
   `resource_type: "crm_company"` for company-anchored rows, and
   `CompanyShowLive` mounts `EventsComponent` with exactly that
   `resource_type` — so the entries land on a tab that queries for them,
   rather than being written somewhere nothing reads.

### IMPROVEMENT — MEDIUM (documented, not fixed)

10. **`SettingsLive.mount/3` does its DB reads in `mount/3`, and this PR added
    a third.** `PhoenixKitCRM.enabled?/0`, `RoleSettings.list_eligible_roles/0`,
    `enabled_role_uuids/0` and the new `role_user_counts/0` all run in `mount`,
    which LiveView calls twice (dead render + WebSocket connect) — so the dead
    render pays for four queries and throws the result away. `CRMLive`, in this
    same PR, does it the other way and says so in a comment: all reads live in
    `handle_params/3` behind `connected?/1`. The fix is mechanical (default
    assigns in `mount`, loads in `handle_params`), but it changes what the dead
    render puts on screen and touches a lifecycle the PR only extended by one
    line, so it is left on record rather than applied here. Impact is small in
    practice — an admin settings page, four cheap queries, loaded rarely.

11. **`list_involving/1` guards the company anchor for trashed, but not the
    contact anchor.** A company-anchored row disappears from a party contact's
    feed once the company is trashed (new, and matched by a broadcast so open
    pages update). A *contact*-anchored row reached through the same party arm
    stays visible when its anchor contact is trashed — while `list_recent/1`,
    added in this same PR, excludes it. The two functions serve different
    purposes (a person's own history vs. a directory-wide digest), and hiding
    shared history from the other participant is a product decision nobody
    asked for, so this is recorded rather than changed. Flagging it because the
    `list_involving/1` docstring now says "the same visibility rule every
    roster and feed applies", which is true only of the company arm.

### NITPICK

12. **`Interactions.list_for_contacts/2`'s docstring is now stale.** It says it
    "remains the member-rollup primitive other consumers call with explicit
    uuids", but this PR removed both of its in-repo callers —
    `CompanyInteractionsComponent` was deleted and `ProjectClientLive` switched
    to `list_for_company/2`. Only the test suite calls it now. Keeping the
    function is right (it is public API of a library module and a sibling
    package may consume it); the sentence just no longer describes this repo.

13. **`upload_error_label(:too_large)` reads "File is larger than 25 MB"** while
    `@max_upload_size` is `26_214_400` — 25 MiB, i.e. 26.2 MB. Colloquially
    fine; exact only in the binary reading.

14. **`PartyRoles.role_counts/1` has no fallback clause**, so
    `role_counts("staff")` is a `FunctionClauseError` rather than `%{}`. Both
    call sites pass literals, and a loud failure on an unknown roleable type is
    arguably the better default — noted only so the asymmetry with
    `count_*_with_role/2` (which take the type implicitly) is on record.

15. **`Interaction.update_changeset/2` carries neither `validate_anchor/1` nor
    the `check_constraint`.** Safe today: it cannot cast an anchor, and every
    caller hands it a persisted struct. If it were ever pointed at a fresh
    `%Interaction{}` the DB CHECK would raise instead of returning a changeset
    error. The `change_interaction/2` `uuid: nil` dispatch is what keeps that
    from happening.

## Not defects (considered and ruled out)

- **`feed_scope` reset after a company-anchored save under the People scope.**
  `save_interaction` flips `feed_scope` to `:all` and calls
  `load_interactions/1` without updating `loaded_key`, so the next host
  `send_update` re-queries. That is one redundant query on a path that was
  already about to re-query off the create broadcast — not a correctness issue.
- **The `no-contacts` tab renders only while it is the active filter**, and
  `no_contacts_count` is only queried then. Deliberate and documented: the
  overview's needs-attention row is the way in, and the count is not paid on
  every other view.
- **V05 migration replay safety.** Every statement is `IF NOT EXISTS` or a
  guarded `DO $$` block; the FK gets its own existence guard (an
  `ADD COLUMN IF NOT EXISTS ... REFERENCES` would not re-guard the FK when the
  column already exists); the CHECK is added `NOT VALID` and validated
  separately, and — correctly — *before* `contact_uuid` loses `NOT NULL`, so a
  concurrently-replayed chain cannot briefly admit an anchorless row. No data
  migration is needed because every pre-V05 row has a contact and no company.
- **The `~r/^...$/` → `~r/\A...\z/` prefix-guard tightening** is right (`$`
  also matches before a trailing newline) and nothing exploitable followed from
  the old form, as the comment says — the newline landed inside a quoted
  literal.
- **`Map.fetch!/2` on the role-count maps in `CRMLive`** looks like a crash
  waiting to happen but is the safer choice: `role_counts/1` builds its map
  from `PartyRole.roles/0`, so a `fetch!` miss means the two lists have drifted
  and should fail loudly rather than render a silent zero.

## Gate status

Run against a local `phoenix_kit` core checkout (`PHOENIX_KIT_PATH=../phoenix_kit`)
and a live Postgres instance. No changes were needed to reach this.

```
mix format --check-formatted       clean
mix credo --strict                 clean
mix dialyzer                       clean (passed successfully; 5 errors, all 5
                                    skipped by .dialyzer_ignore.exs)
mix test                           725 passed, 8 failed
```

The 8 failures are `schema_owner_guard_test.exs` (7) and
`schema_owner_guard_wiring_test.exs` (1) — the same environment limitation
recorded in the PR #28 review. They open an admin connection to the `postgres`
maintenance database to create and drop scratch databases; this sandbox's
Postgres role cannot, so they fail in `setup` with
`DBConnection.ConnectionError` before touching any assertion. Neither file is
touched by this PR, and both fail identically in isolation.
