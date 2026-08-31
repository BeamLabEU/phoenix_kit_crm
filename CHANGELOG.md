# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.9.0 - 2026-08-31

### Added

- **Manufacturers backfill** (#31). `mix
  phoenix_kit_crm.import_manufacturers_from_catalogue` — the twin the supplier
  import shipped without. Dry-run by default, `--apply` writes; idempotent via
  V178's `crm_company_uuid` stamp; matches an existing CRM company by extracted
  email, then by normalized website, otherwise creates one and grants the
  `manufacturer` role. Catalogue manufacturers previously kept feeding the item
  form's dropdown as the old local list while the CRM Companies page's
  Manufacturers filter showed nothing.
- **`PhoenixKitCRM.CatalogueImport`** (#31). The supplier task's machinery
  extracted into one engine parameterized per flow; both mix tasks are thin
  wrappers and the supplier task keeps its public-for-testing surface as
  delegators.

### Fixed

- The backfill wrote a source row's `description` into the company's `metadata`
  map on the premise that a CRM company has no such column. It has one —
  migration V02 added it for these very rows — so the text was invisible to the
  company form and every `Company` consumer. Both flows now write the real
  column (post-merge review of #31).
- Manufacturer `logo_url` was dropped entirely. Migration V03 added
  `phoenix_kit_crm_companies.logo_url` so a company could carry the brand mark
  the catalogue's manufacturer rows held, and `PartyRoles.get_manufacturer/1`
  returns it to the catalogue's pickers — once a local row was hidden behind
  its imported party, every imported manufacturer lost its logo. It is now
  carried across (post-merge review of #31).
- Two source rows matching one CRM party (two brands on a shared domain or
  contact email) granted the role and then raised on the stamp, tripping V178's
  partial unique index and leaving the party listed alongside the still-visible
  unstamped local row — the split-brain that index exists to prevent. Such a row
  is now reported as `claimed-by-other` and left untouched, on the supplier path
  too (post-merge review of #31).

### Changed

- Dependency bump: `phoenix_kit` 2.13.8 → 2.13.17, `phoenix_kit_comments`
  0.4.3 → 0.4.5, plus `hammer`, `leaf` and `oban` lockfile updates.
- `PhoenixKitCRM.Schemas.PartyRole`'s moduledoc no longer states that the
  `manufacturer` role is never granted in bulk — the opt-in backfill above is
  now a sanctioned path. What still holds is that it is never granted
  implicitly or from a form.

## 0.8.1 - 2026-08-25

### Added

- **SchemaOwnerGuard** (#28). When `PGDATABASE` points the test suite at a
  shared Postgres database, `Ecto.Migrator`'s `schema_migrations` bookkeeping
  is keyed only by version number with no package namespace — another
  package's already-applied migration can silently mask this package's
  migration of the same number. The guard stamps an owner marker on
  `schema_migrations` after a successful boot and refuses (with a clear
  error) any future boot that finds a marker naming a different package,
  instead of silently colliding.

### Changed

- Dependency bump: `phoenix_kit` 2.13.7 → 2.13.8, `phoenix_kit_comments`
  0.4.2 → 0.4.3.

## 0.8.0 - 2026-08-24

### Added

- **Live company page** (#27). The Members roster, Interactions rollup, Events
  tab and Catalogue tab follow other sessions without a reload: contacts
  announce join / leave / rename on a per-company topic after commit; the page
  keeps a per-member interaction subscription set in sync with the roster and
  drops the previous company's subscriptions when the uuid changes; the
  Catalogue tab follows the catalogue module on the host PubSub (core's
  internal server never hears those broadcasts).
- **Tab intros** on the contact and company show pages — one line under each
  heading saying what the tab lists and how something gets into it. The
  Members tab's "New contact for this company" link opens the contact form
  with that company preselected.

### Changed

- Mirror resolution rebuilds the contact/company form from the resolved
  record (keeping the operator's unsaved draft on every other field) so Save
  cannot silently undo the choice just made. Organizations view swaps the
  rewritten user into its rows.
- CRM settings remounts after a role toggle so the sidebar re-reads the
  dashboard registry (which broadcasts badge updates only, never
  registrations).
- Role view reloads the user→contact map from `columns_saved/1` when the
  "CRM contact" column is ticked on.

### Fixed

- Contact Files tab's interaction attachment roll-up refreshes when an
  interaction is created or deleted elsewhere.
- List-members locale-apply preview recomputes while the modal is open, so
  the confirm number matches the flash.
- Comparison page: re-expanding a duplicate-email group re-queries both the
  rows and the group list / count badge. A pair that is no longer duplicated
  leaves the page instead of sitting at "2 contacts" over a one-row
  drill-down. Group keys are lowercased so a citext `GROUP BY` cannot flip
  `alice@x` / `ALICE@X` between queries and drop the expanded rows.
- Company Catalogue tab also refreshes on `:category` (a default column of
  the embedded items table). `:supplier` / `:manufacturer` / `:links` were
  already in the follow-up to #27.
- `delete_contact/1` and `set_primary_company/4` read the companies to
  notify inside their transactions under a row lock, so a concurrent
  membership is neither missed nor announced for a page that never showed it.
- Mirror resolution broadcasts the contact change once, after its own
  commit — not from inside the transaction.

## 0.7.2 - 2026-08-22

### Changed

- Contact and company show pages, plus the contacts / companies / lists /
  list-members filter strips, now use core's `<.nav_tabs variant={:border}>`
  instead of hand-rolled `tabs-border` markup (#24). Companion to
  phoenix_kit 2.13.6 (`:patch` passes through verbatim so Paths-prefixed URLs
  are not double-prefixed).
- `mix.lock`: phoenix_kit 2.13.6.

### Fixed

- **Catalogue tab 500 on first load** (#25). `column_picker_available?` and
  `catalogue_column_catalog()` were only computed from the column-picker
  event handlers, never from `handle_params`, so the first render of
  `?tab=catalogue` raised `KeyError` on every company.
- **Raw-binary uuid leaking into company metadata on supplier import** (#26).
  `fetch_suppliers/2` reads catalogue rows with raw SQL, so Postgrex returns
  a `uuid` column as a 16-byte binary; that binary could not encode as JSONB
  and every row that needed a new CRM company failed on INSERT.
  `process_supplier_row/4` now also normalizes uuids, so callers other than
  the mix-task read path cannot reintroduce the same failure.
- The catalogue-presence probe in `test_helper.exs` now releases its sandbox
  owner in `after`, so a failed probe cannot leak a checked-out connection.

### Added

- `{:rustler, ">= 0.0.0", optional: true}` so `MDEX_NATIVE_BUILD=1` can
  compile `mdex_native` from source (same declaration phoenix_kit carries)
  (#25).

## 0.7.1 - 2026-08-21

### Added

- **`manufacturer` party role**, alongside `supplier` / `customer` / `partner`
  (#23). Granted the same way as the others; a company or contact can hold
  `supplier` and `manufacturer` at once — the case the shared role table
  exists for.
- **Roles now carry a validity window.** `valid_from` / `valid_to` used to be
  decorative — every query filtered on `is_active` alone, so a role stamped
  with an expired `valid_to` still resolved as live forever. Every role query
  now goes through `PartyRoles.in_force/1`, so an out-of-window role stops
  resolving even while `is_active` stays true, and re-granting a lapsed role
  starts a fresh tenure instead of silently returning the stale row.
- **Batch party resolution**: `get_suppliers/1`, `get_manufacturers/1`, and
  `list_parties_with_role/2` (with `list_suppliers/1`, `list_manufacturers/1`,
  `list_customers/1` wrappers) resolve many party uuids in one pair of
  queries instead of one call per row — the N+1 a catalogue page rendering
  100 items would otherwise hit.
- **A Catalogue tab on the company page** (#23), shown when the catalogue
  module is installed *and* enabled. Lists items this company supplies or
  manufactures, with a column picker and a warning banner when items still
  reference a role the company no longer holds. Soft-dependency guarded
  (`Code.ensure_loaded?` + `apply/3`) — the CRM has no compile-time
  dependency on the catalogue.
- `Company` gained `description` and `logo_url` — the fields the catalogue's
  own supplier/manufacturer rows used to carry, now that those parties are
  managed here.
- A V04 migration adds a `CHECK` constraint on the role vocabulary and a
  partial unique index (`roleable_uuid`, `role`) `WHERE is_active`, so a
  party can hold at most one active row per role — closing a state
  `get_supplier/1` previously had to defend against with `limit(1)`. Legacy
  `client` rows (pre-rename) are normalized to `customer` first, since
  `ADD CONSTRAINT` validates existing rows.

### Fixed

- **`get_manufacturer/1` and its batch/list counterparts now return
  `logo_url`.** V04's own `description`/`logo_url` addition to `Company` was
  meant to let the catalogue read a manufacturer's brand mark from CRM, but
  none of the federation resolvers included the field — it was captured on
  the company form and reachable by nothing.
- Removed seven `priv/gettext` catalog entries (`"Item"`, `"Their code"`,
  `"Unit cost"`, `"Lead time"`, `"primary"`, `"%{n} d"`, `"SKU"`, with real
  Estonian and Russian translations) that no `gettext/1` call in this repo
  produces.
- `phoenix_kit_crm.import_suppliers_from_catalogue`: raw-SQL uuid parameters
  are now dumped to their 16-byte binary form before use (`Ecto.UUID.dump/1`)
  and uuid columns read back from raw SQL are loaded to text before display
  (`Ecto.UUID.load/1`) — both directions previously raised on a row that had
  actually been linked.

### Changed

- Dependency updates (`mix.lock`): `phoenix_kit` 2.13.4, `phoenix` 1.8.12,
  `phoenix_live_view` 1.2.10, and routine bumps to `ecto`, `bandit`, `swoosh`,
  `req`, `tesla`, and others.

## 0.7.0 - 2026-08-14

### Added

- **Manual two-way mirror between CRM records and system users** (#22).
  Company ↔ organization-user (via a new optional
  `phoenix_kit_crm_companies.user_uuid`) and Contact ↔ person-user (building on
  the existing `contacts.user_uuid`). Every direction is an explicit admin
  action — **Create mirror**, **Link existing**, **Unlink** — available from both
  sides, alongside the existing `allow_login` checkbox rather than replacing it.

  **Nothing is automatic:** no PubSub, no background sync. The form you act from
  is the master, and when a mirrored field diverges a per-field conflict modal
  asks which side to keep instead of silently overwriting; a blank field on the
  target is simply filled from the master. `resolve` recomputes the diff fresh at
  submit time, so a stale selection or an out-of-band edit cannot drive a bad
  write, and every write touching two records runs in one transaction.

  `user_uuid` is never cast from form params on either schema — only through a
  dedicated `link_user_changeset/2`, preserving the invariant `Contact` already
  had.

- **The module now owns its migrations** (`migration_module/0` →
  `PhoenixKitCRM.Migrations`), following the `phoenix_kit_legal` precedent. **V01**
  idempotently adopts the 10 `phoenix_kit_crm_*` tables the core chain
  historically created (`CREATE TABLE IF NOT EXISTS`, shape-identical, a no-op on
  existing installs) and adds the one genuinely new object: `companies.user_uuid`
  (FK → `phoenix_kit_users(uuid)` `ON DELETE SET NULL`) with a **partial** unique
  index, so any number of companies may be unlinked while a linked user maps to
  at most one. Version tracked by a `crm_schema:1` `COMMENT ON TABLE`; `down/1`
  never drops a table, and a committed test pins that.

  Note for hosts: because the column is not in core's manifest,
  `mix phoenix_kit.repair` reports it as an **info-level** `extra_object`. Repair
  takes no action on it — it will not be dropped.

### Changed

- Dependency updates: `phoenix_kit` 2.4.0. The `~> 2.0` pin is unchanged — nothing
  here uses core's new `Slug.put_slug/3`.

## 0.6.1 - 2026-08-11

### Fixed

- **The remaining untranslated Estonian and Russian strings are filled in**
  (#21). A large block of msgids had empty `msgstr` values, so those parts of
  the CRM rendered in English inside an otherwise translated UI.

### Changed

- **The CRM page subtitle now says what the module is.** "Companies, contacts
  and the roles that can reach them" became "Customer relationship management —
  companies, contacts and the roles that can reach them", so the page names
  itself for anyone who has not met the abbreviation.

- Dependency updates (`phoenix_kit` 2.2.0, `phoenix_kit_comments` 0.4.0,
  `phoenix` 1.8.10, `hackney` 4.7.3).

## 0.6.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

- `phoenix_kit_comments` raised to `~> 0.3` in step. Its 0.3.0 is the first
  release requiring core 2.0, so the old `~> 0.2.6` pin could only have resolved
  a comments that still required core 1.7 — an unsatisfiable set alongside
  `phoenix_kit ~> 2.0`. 0.3.0 is also a **security release** (stored XSS in
  comment bodies); see its CHANGELOG.

## [0.5.0] - 2026-08-09

### Added

- **Client tab for the `phoenix_kit_projects` hub.** `PhoenixKitCRM` now
  answers `phoenix_kit_project_extensions/0` — the hub's duck-typed, one-way
  provider contract, so there is no dependency on the projects package in
  either direction. A project links one CRM company through per-instance
  config (`company_uuid`, no FK), and the contributed tab
  (`PhoenixKitCRM.Web.ProjectClientLive`) renders that company, its member
  contacts and their most recent interactions read-only, with link-outs into
  the CRM admin. The extension declares `module_key: "crm"`, so the hub
  requires the CRM permission of anyone who sees the tab, and `[:view]`, so
  the hub hands it no write surface.
- `PhoenixKitCRM.Companies.company_options/0` — untrashed companies as
  `%{value:, label:}` picker options. It backs the extension's company
  select; it is public and stable for any sibling module that wants the same
  picker.
- `Interactions.list_for_contacts/2` accepts a `:limit`. The arity-1 form is
  unchanged for callers that legitimately want the whole rollup.

### Fixed

- The Client tab crashed on any project whose linked company had at least one
  logged interaction: the timeline read `interaction.kind`, and the schema
  field is `interaction_type`, so rendering raised `KeyError`. Because the hub
  renders contributed tabs as nested `live_render`s, that took the host
  project page down with it. The badge now shows the same gettext-backed
  `Interaction.type_label/1` the CRM interaction timelines use.
- A company trashed in CRM no longer presents as the project's live client —
  config-based linkage has no FK to cascade, so the card now carries a
  `Trashed` badge rather than silently showing a soft-deleted company.
- The tab is translatable. It set the session locale and then rendered
  hardcoded English, including a hand-rolled plural for the member count;
  every string is now gettext, and the count is a real `ngettext` (Estonian
  and Russian plural rules are not English's).
- The recent-interactions read is capped in the query. It previously read
  every interaction of every member contact, with `:contact` and `:parties`
  preloaded, and discarded all but the newest five in memory.

### Changed

- The extension's `company_uuid` config field is a `:select` over
  `company_options/0` instead of a free-text "Company UUID" — linking a client
  is picking a name, not pasting a uuid copied off the company page.
- `ProjectClientLive` uses `use PhoenixKitWeb, :live_view` like every other
  LiveView in this module (AGENTS.md names the convention explicitly), and
  defers its CRM reads to the connected mount, painting a skeleton on the
  disconnected pass. The hub renders a landing extension tab in the project
  page's dead render too, so the reads previously ran twice per load.
- Dropped eight unused entries from `mix.lock` (igniter and its tree), left
  behind by a dependency upgrade — `mix precommit` fails on them via
  `deps.unlock --check-unused`.

## [0.4.1] - 2026-07-31

### Fixed

- The Comparison route was declared twice — once by its `admin_tabs/0` entry
  (which core turns into a route) and once explicitly in
  `PhoenixKitCRM.Routes` — so every host router compiled with two
  "this clause cannot match because a previous clause matches the same
  pattern" warnings, which fails a host running
  `mix compile --warnings-as-errors`. The explicit declaration is gone.

### Changed

- Following from that fix, the generated path helper for the Comparison page is
  now `:admin_crm_comparison` (was `:crm_comparison` / `:crm_comparison_locale`).
  Routing itself is unchanged — same path, LiveView, action, pipeline and
  `live_session`, in both the root and the `/:locale` scope — and this matches
  how the other list-index tabs (Contacts, Companies, Lists) already resolve.
  A host calling the old helper by name must switch to `:admin_crm_comparison`
  or to `PhoenixKitCRM.Paths.comparison/0`.

### Added

- A regression guard for the above: `PhoenixKitCRM.Routes` is now asserted to
  declare no path that an `admin_tabs/0` / `settings_tabs/0` entry already
  generates a route for, so a re-introduced duplicate fails this module's own
  suite instead of the host's compile.

## [0.4.0] - 2026-07-29

### Upgrade note — run the party-role data migration

The commercial party role `client` is now `customer`. Rows written by 0.2.x /
0.3.x keep `role = "client"` and are invisible to the renamed code: absent
from the Customers filter, absent from the company/contact role checkboxes,
and rendered as a raw grey badge. Rewrite them once per database:

```bash
mix phoenix_kit_crm.rename_client_role           # dry-run: reports the count
mix phoenix_kit_crm.rename_client_role --apply   # rewrite
```

The task is idempotent and a no-op on databases that never granted the role.

### Added

- **`Compare` admin tab** (`/admin/crm/comparison`) — contacts subscribed to
  every one of several selected lists (PR #17).
- **Contact ⇄ login-account linkage** (PR #17): a `CRM contact` column on the
  per-role users table linking to the matching contact, and a real link from a
  contact's Overview to its login account.
- **Orders tab on the contact profile**, populated by the host application's
  optional `Andi.CRMBridge` and hidden entirely when that bridge is absent
  (PR #17).
- **CRM landing page** — company / contact / interaction / list counts, each
  linking to the page that manages it, plus a clearer "Portal access" section
  for the PhoenixKit roles that may open the CRM (PR #17).
- `mix phoenix_kit_crm.rename_client_role` — the `client` → `customer` data
  migration described above.
- `PhoenixKitCRM.Contacts.map_by_user_uuids/1`,
  `PhoenixKitCRM.Lists.count_lists/1`,
  `PhoenixKitCRM.Interactions.count_interactions/0`, and
  `PhoenixKitCRM.PartyRoles.{rename_legacy_client_roles/0,
  count_legacy_client_roles/0}`.

### Changed

- **`client` → `customer`** throughout `PartyRole`, the contacts/companies role
  filters and the role labels/badges (PR #17). See the upgrade note above.
- **UI standardisation** (PR #17): page wrappers no longer clamp to
  `max-w-*`, `phx-click` checkboxes use core's `<.checkbox>`, list-members
  pagination uses `join` styling, and clickable table rows use core's
  `<.row_link>` stretched-link overlay instead of a `phx-click` handler. This
  raises the `phoenix_kit` floor to `>= 1.7.219`, the first release shipping
  `PhoenixKitWeb.Components.Core.RowLink`.
- The `Compare` tab now sorts directly after `Lists` in the sidebar rather than
  after `Organizations`.

### Fixed

- **The `CRM contact` column issued one query per table row, inside `render/1`**
  — so every re-render (opening the column modal, toggling card/table view)
  re-ran the whole set, not just the initial load. It is now a single batched
  lookup per page load, skipped entirely when the column isn't selected.
- **A row's stretched link could collapse onto a single cell.** `relative` on
  the `crm_contact` cell made that cell the row-link overlay's positioned
  ancestor whenever the user ordered it first, so the row stopped being
  clickable. The link inside the cell lifts itself above the overlay instead.
- **The host order bridge was queried on every contact-profile tab switch**,
  not just the Orders tab, and was not rescued — an exception in host code took
  down the whole profile rather than one tab.
- **The Overview "Lists" count included archived lists** while the Lists page it
  links to opens on Active, so the card disagreed with the page one click later.
- The CRM landing page no longer prints a specific host application's backfill
  mix task, which does not exist in any other consumer of this package.

## [0.3.3] - 2026-07-20

### Fixed

- **Test suite** — `contact_delete_counters_test.exs` ran a real
  `ALTER TABLE ... DROP CONSTRAINT` inside a sandboxed transaction while
  marked `async: true`, holding a table-level `ACCESS EXCLUSIVE` lock on
  `phoenix_kit_crm_list_members` against other async files reading/writing
  that same table concurrently — the rare "1 failure in 8 full-suite runs"
  deadlock flake (`40P01 deadlock_detected`). The file is now `async: false`
  (PR #16). Test-only change; no published package content is affected.

## [0.3.2] - 2026-07-20

### Fixed

- **`Lists.recount_list/1`** raised if the list row it was recounting was
  deleted concurrently between the caller loading it and the recount's own
  `UPDATE` — a narrower race left open by 0.3.1's fix. It now returns
  `:missing` instead of raising, and `Contacts.delete_contact/1`'s recount
  step tolerates it: a moot counter on an already-deleted list no longer
  rolls back the whole contact deletion (PR #15).

## [0.3.1] - 2026-07-19

### Fixed

- **`Contacts.delete_contact/1`** permanently overcounted a list's
  `subscriber_count` — the FK cascade on `phoenix_kit_crm_list_members`
  removes membership rows at the DB level when a contact is hard-deleted,
  bypassing `Lists.remove_from_list/2`'s atomic counter decrement (that
  path only fires on a live status flip). Deleting a contact still
  `"subscribed"` on a list left the count permanently stuck one too high.
  `delete_contact/1` now snapshots the contact's subscribed lists and
  recounts each one (`Lists.recount_list/1`) in the same transaction as
  the delete (PR #14).

## [0.3.0] - 2026-07-19

Stage 3 of the restructuring plan (PR #13): CRM contact lists, a CSV/text
account importer, per-list locale with bulk-apply, contact opt-out/consent,
and a duplicate-email/list-overlap comparison screen. Requires
`phoenix_kit >= 1.7.203` (the core migration shipping
`phoenix_kit_crm_lists`/`phoenix_kit_crm_list_members` and the CRM broadcast
source columns on newsletters).

### Added

- **`PhoenixKitCRM.Lists`** — named, sluggable contact lists
  (`active`/`archived`), soft-deleted memberships (`subscribed` / `pending` /
  `removed`, never hard-deleted), a maintained `subscriber_count` cache, and
  contact-level opt-out/consent (`opted_out_at` + an append-only `consent`
  log) that applies across every list a contact belongs to. Every
  list/membership mutation broadcasts over `crm:lists` for live subscriber
  counters and admin-UI refresh.
- **`PhoenixKitCRM.Lists.Import`** — CSV (header row, `email`/`name`/
  `company`/`locale` columns) and plaintext (one email per line) import,
  with a no-write dry-run preview and a chunked real run (200 rows/message)
  so a large file doesn't block the LiveView process. Classifies every row
  (`imported` / `already_in_list` / `unsubscribed` / `duplicate_in_file` /
  `no_email` / `invalid_email`); idempotent re-import creates zero duplicate
  contacts.
- **Per-list locale + bulk-apply**: a list can carry a content-language tag,
  bulk-applied to its subscribed members' contacts in `:missing_only`
  (default) or `:all` (overwrite) mode, with a preview of how many contacts
  each mode would touch before confirming.
- **Comparison screen** (`/admin/crm/comparison`): directory-wide duplicate
  emails (expandable to the actual contacts) and cross-list overlap (2+
  lists → contacts subscribed to all of them). Read-only — no merge/remove
  actions.
- Search + pagination on the existing Contacts, Companies, and
  `PartyRoles.list_{companies,contacts}_with_role` listings (previously
  unpaginated, full-table).
- `nimble_csv` dependency for CSV parsing (pure Elixir, already resolved
  transitively via `phoenix_kit`).

### Fixed

- `ComparisonLive`, `ListMembersLive`, and `ListImportLive` queried the
  database directly in `mount/3`, which Phoenix invokes twice per page visit
  (disconnected HTTP render + connected LiveSocket mount) — doubling a
  full-table duplicate-email aggregate scan on every comparison-page visit
  and doubling a primary-key list lookup on the two per-list pages. Moved
  into `handle_params/3`, matching the pattern this PR's own `ListFormLive`/
  `ListsLive` (and the pre-existing `ContactShowLive`) already used
  correctly.
- `phoenix_kit` dependency floor was `>= 1.7.197`, below **1.7.203** — the
  version that actually first shipped core migration V152
  (`phoenix_kit_crm_lists`/`phoenix_kit_crm_list_members`). Installing this
  package at its own previously-stated floor would compile and boot, then
  crash the first time any Lists/Comparison page loaded
  (`relation "phoenix_kit_crm_lists" does not exist`). Floor corrected to
  `>= 1.7.203`.

### Notes

- Postgres was not available in this release's build environment;
  `:integration` (DB/LiveView) tests auto-excluded per this repo's
  documented stance — only unit tests ran (90 passed, 0 failures). The full
  `ComparisonLiveTest`/`ListMembersLiveTest`/`ListImportLiveTest` suites
  (which exercise the `mount/3` → `handle_params/3` fix above end-to-end)
  are expected to run against a real core checkout before this reaches
  production installs.
- See `dev_docs/pull_requests/2026/13-crm-contact-lists/CLAUDE_REVIEW.md`
  for the full post-merge review.

## [0.2.5] - 2026-07-17

First release of the CRM v2 party-roles work (PRs #9-#12): companies and
contacts can now hold commercial `supplier`/`client`/`partner` roles, schemas
carry `PhoenixKit.SchemaPrefix` for named-schema (`--prefix`) installs, and a
one-time backfill task migrates catalogue suppliers into CRM. Requires
`phoenix_kit >= 1.7.197` (the core migration shipping
`phoenix_kit_crm_party_roles` and `phoenix_kit_cat_suppliers.crm_company_uuid`).

### Added

- **`PhoenixKitCRM.PartyRoles`** — grant/revoke `supplier`, `client`, `partner`
  roles on a company or contact (soft-ref polymorphic rows, idempotent grant,
  revoke keeps history instead of deleting). Roles checkboxes on both
  company/contact forms; role badges + filter tabs on both list pages.
  Mutations log `crm.party_role_granted` / `crm.party_role_revoked` with the
  acting user's `actor_uuid`.
- **`mix phoenix_kit_crm.import_suppliers_from_catalogue`** — one-time,
  dry-run-by-default backfill: matches each `phoenix_kit_cat_suppliers` row to
  an existing CRM company by email then normalized website, creates a company
  otherwise, grants the `supplier` role, and stamps `crm_company_uuid` back
  onto the catalogue row. Idempotent; guarded against a missing catalogue
  table or an out-of-date core (`crm_company_uuid` column absent).
- `use PhoenixKit.SchemaPrefix` on every table-backed schema (`RoleSetting`,
  `Company`, `CompanyMembership`, `Contact`, `Interaction`, `InteractionParty`,
  `UserRoleViewConfig`, `PartyRole`) — a no-op unless the host app configures
  `:phoenix_kit, :prefix`. A conformance test enforces it repo-wide.
- `dev_docs/design/crm_v2_parties_suppliers_clients.md` — the design spec this
  release implements Phases 1 and 3 of (Phase 2's catalogue-side resolver and
  Phase 4's client/warehouse seam are future work).

### Changed

- Involved-parties search (`interactions_component.ex`) switched from a
  hand-rolled `PartyPicker` JS hook to core's `<.search_picker>` component;
  the old hook's static asset was deleted.
- `phoenix_kit` dependency floor raised `~> 1.7 and >= 1.7.189` →
  `>= 1.7.197`.

### Fixed

- Party-role grant/revoke activity log entries now record the acting user's
  `actor_uuid` instead of always logging `nil`.
- `ContactFormLive`'s partial-role-failure path re-reads persisted role state
  from the DB before re-rendering (was showing stale checkbox state;
  `CompanyFormLive` already did this correctly).
- Supplier-import email matching lowercases both sides of the comparison (works
  whether the core migration has promoted the column to `citext` or not),
  excludes trashed companies, and resolves duplicate emails to the oldest
  match instead of raising; website matching lowercases before stripping the
  scheme/`www.` prefix so uppercase stored URLs normalize the same as the
  Elixir-side helper.
- Supplier-import per-row processing: a grant/stamp/match failure on one row
  records an `:error` row and the run continues instead of aborting — the
  report always prints. The report's `errors:` total previously only counted
  failed company-creation (`:error_creating`), silently dropping these
  rescued-exception rows from the summary; it now counts both.
- `mix dialyzer` — added `:mix` to `plt_add_apps` (`mix.exs`). The supplier
  backfill task is this repo's first file under `lib/mix/tasks/`, and without
  `:mix` in the PLT, dialyzer couldn't resolve `Mix.Task`'s callbacks or
  `Mix.shell/0`/`Mix.Task.run/1`, failing the release gate.
- `mix credo --strict` — a test call site spelled out the task's fully
  qualified module name instead of using the alias already in scope,
  tripping Credo's nested-module-aliasing check and (like the dialyzer issue
  above) failing the release gate.

### Notes

- Integration tests (the CRM DB round-trips, including all of
  `party_roles_test.exs` and the supplier-import task's DB-backed cases)
  could not run in this release's build environment (no Postgres available);
  per this repo's documented stance they auto-exclude and only the pure-logic
  unit tests ran. They're expected to run in CI / against a real core
  checkout before this reaches production installs.
- Review docs: `dev_docs/pull_requests/2026/{10-crm-party-roles,
  11-schema-prefix,12-import-suppliers-backfill}/CLAUDE_REVIEW.md`.

## [0.2.4] - 2026-06-28

Post-merge review fixes for the interaction-tracker buildout (PR #8) —
correctness, authorization, and performance hardening. No changes to the stable
public surface (`RoleSettings`, `UserRoleView`, `ColumnConfig`).

### Fixed

- `version/0` now reports the package version (it was stale at `0.1.0`); a test
  keeps it in sync with `mix.exs`.
- Company rosters and the company interactions rollup no longer include
  soft-deleted contacts — `Companies.list_memberships/1` excludes trashed members.
- Avatar selection is authorization-scoped: `Attachments.set_avatar/3` only
  accepts an image that belongs to the record's own `Images` folder, so a forged
  event can't point a record's avatar at an arbitrary file.
- Contact/company search escapes the `% _ \` LIKE metacharacters and strips null
  bytes — a literal `%` no longer matches everything, and a null byte can't crash
  Postgres.
- `Contacts.get_by_user_uuid/1` and both `list_by_uuids/1` tolerate malformed
  UUIDs (return `nil`/`[]`) instead of raising an `Ecto.Query.CastError`.
- `Interactions.update_interaction/4` no longer wipes the involved parties when
  none are passed (the default is now "keep"), and preserves each party's frozen
  profile snapshot across an edit instead of re-deriving it from current data.

### Changed

- Composer file uploads are restricted to a curated type allowlist (no inline
  `html`/`svg`/`xml`) with an explicit 25 MiB per-file cap, instead of
  `accept: :any` with the 8 MB default.
- Removed duplicate/needless queries: the contact-form company list and the
  role-view column metadata no longer load in `mount/3` (which runs twice); the
  column modal only queries when open; and the media + company-interactions
  components guard their `update/2` reloads (the contact interactions feed still
  live-refreshes via PubSub).
- The PartyPicker JS hook clears its staging fallback timer on `destroyed()`.

### Internal

- Dialyzer is clean again: fixed two warnings in the PR #8 code and added a
  scoped `.dialyzer_ignore.exs` for the Gettext/Expo opaque-type false positive
  in the generated Gettext backend.

## [0.2.3] - 2026-05-25

Incremental i18n coverage plus a dependency refresh. No API changes; the
only user-visible behaviour change is the CRM settings tab sort position.

### Added

- Localized the remaining CRM admin page bodies onto the package-owned
  `PhoenixKitCRM.Gettext` backend — `CRMLive` (`CRM`, `Enabled`, `Disabled`),
  `SettingsLive` (page title, headings, helper text, flash messages), and the
  `ColumnManagement` macro flash messages (`Columns updated`,
  `Failed to save columns`). All `Gettext.gettext(PhoenixKitWeb.Gettext, …)`
  long-form calls converted to the short `gettext()` macro. After this release
  there are no references to the host app's `PhoenixKitWeb.Gettext` backend
  left in `lib/`. Full `en`/`ru`/`et` coverage for the new msgids.
- Completed the Estonian catalogue — the 16 previously empty column-customization
  msgids (`Apply`, `Cancel`, `Customize columns`, `Drag to reorder`, `Selected`,
  `Available`, …) are now translated; `et/default.po` is 28/28.

### Changed

- CRM admin sidebar tab `priority` `650 → 924`, repositioning the entry within
  the admin settings group.
- Dependencies refreshed — `phoenix_kit` `1.7.106 → 1.7.120`, `ecto`/`ecto_sql`
  `3.13 → 3.14`, plus patch/minor bumps across `bandit`, `finch`, `plug`,
  `postgrex`, `req`, `swoosh`, `tesla`, `igniter`, and others.
- Tightened the `precommit` alias to `compile --force --warnings-as-errors`,
  `deps.unlock --check-unused`, and `quality.ci`.

### Documentation

- `PhoenixKitCRM.Web.ColumnManagement` moduledoc now lists the host requirement
  to `use Gettext, backend: PhoenixKitCRM.Gettext` (the injected flash messages
  call the bare `gettext/1` macro, kept as a macro so `mix gettext.extract`
  sees the strings).

## [0.2.2] - 2026-05-09

### Added

- Per-module Gettext backend (`PhoenixKitCRM.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels (`CRM`, `Overview`, `Organizations`) and UI strings in `ColumnModal` and `CellFormat`. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).
- All `use Gettext, backend: PhoenixKitWeb.Gettext` references in `PhoenixKitCRM` replaced with the module-owned `PhoenixKitCRM.Gettext` backend — the package no longer depends on the host app's Gettext module.
- Column header translations for the role and Organizations table views — `Email`, `Username`, `Full Name`, `Status`, `Registered`, `Last Confirmed`, `Location`, `Organization`, `Contact`. These labels live in `ColumnConfig` module attributes and are translated at runtime via `Gettext.gettext/2`; msgids are maintained manually in `priv/gettext/default.pot` (alongside the Tab labels) since `mix gettext.extract` only sees `gettext()` macro call sites. Full `en`/`ru`/`et` coverage.

## [0.2.1] - 2026-05-05

Bug fixes and performance hardening from the PR #4 retrospective review:
LiveView lifecycle correctness on the CRM landing page, an N+1 query
collapse, and a per-cell render hot-path optimization. No breaking
changes — patch release.

### Fixed

- **CRMLive lifecycle.** Role-stat loading moved out of `mount/3`
  (which fires twice per connect — HTTP + WebSocket) into
  `handle_params/3` gated on `connected?/1`. Eliminates duplicate
  queries on every CRM landing-page render.
- **N+1 across enabled roles.** New
  `PhoenixKitCRM.RoleSettings.list_enabled_with_user_counts/0` issues
  a single GROUP BY with a left join over `RoleAssignment`, replacing
  one `Roles.count_users_with_role/1` round-trip per role. Roles with
  zero users still surface (count = 0) thanks to the left join.
- **Per-cell `available_columns/1` recomputation.** Custom-cell render
  no longer rebuilds the full `[{id, meta}]` list per cell. Views
  compute `ColumnConfig.column_metadata_map/1` once per render and
  pass the resolved map through `render_cell/3`, `card_field/3`,
  `column_label/2`, and `CellFormat.render_custom_cell/3`.
  `ColumnModal` does the same lookup once at the top of the function
  component.
- **Unguarded `field["key"]` in custom-field columns.** Malformed
  custom field definitions (no `"key"`) no longer crash the page with
  `ArgumentError: argument for <> is not a binary` — they're filtered
  upstream of the `Enum.map`.
- **Gettext call-style consistency in `CRMLive`.** Switched long-form
  `Gettext.gettext/dngettext(PhoenixKitWeb.Gettext, …)` to the short
  `gettext/ngettext` already in scope via
  `use PhoenixKitWeb, :live_view`, matching `RoleView` /
  `OrganizationsView`.

### Added

- `PhoenixKitCRM.ColumnConfig.column_metadata_map/1` — flat
  `%{column_id => meta}` map for callers that need lookup-by-id without
  rebuilding the available-columns list per call.
- `PhoenixKitCRM.RoleSettings.list_enabled_with_user_counts/0` — single
  GROUP BY query for the CRM overview.

### Changed

- `PhoenixKitCRM.Web.CellFormat.render_custom_cell/3` second arg is
  now a `column_meta` map (not a scope). Internal callers within CRM
  are updated; `CellFormat` was introduced in 0.2.0's PR #4 follow-ups
  and has not been released until now, so no upgraders are affected.
- Dependencies refreshed via `mix deps.update --all`: `bandit`, `ecto`,
  `jason`, `leaf`, `phoenix`, `phoenix_kit`, `phoenix_live_view`,
  `postgrex`. Patch / minor only — no constraint changes in `mix.exs`.

## [0.2.0] - 2026-05-04

Companies → Organizations pivot, i18n foundation, LiveView lifecycle
correctness, and a runtime-crash hotfix. The `Companies` placeholder is
replaced with a real `Organizations` subtab that lists users whose
`account_type = "organization"`. All user-facing strings are routed
through `gettext`. Six public-API renames (scope atom, setting key,
module, path, tab id, `Paths` helper) make this a breaking release.

### Breaking

- **Scope rename** — `:companies` → `:organizations` everywhere
  (`PhoenixKitCRM.UserRoleView.scope/0`, `ColumnConfig` keys,
  `UserRoleViewConfig` rows). `scope_from_string/1` keeps a fallback
  that decodes the legacy `"companies"` string to `:organizations`
  with a `Logger.warning` so existing DB rows don't crash on read —
  host apps should plan a one-shot data migration to rewrite stored
  scope strings.
- **Setting key rename** — `crm_companies_enabled` →
  `enable_organization_accounts`. The Companies-feature toggle on the
  CRM settings page is removed; visibility of the Organizations
  subtab is gated on the PhoenixKit-wide
  `enable_organization_accounts` setting instead.
- **Module rename** — `PhoenixKitCRM.Web.CompaniesView` →
  `PhoenixKitCRM.Web.OrganizationsView`. Host apps with custom
  `live_view:` overrides need to update.
- **Route rename** — `/admin/crm/companies` →
  `/admin/crm/organizations`. Bookmarks and external links break.
- **Tab id rename** — `:admin_crm_companies` →
  `:admin_crm_organizations` in `PhoenixKitCRM.admin_tabs/0`.
- **Path helper rename** — `PhoenixKitCRM.Paths.companies/0` →
  `PhoenixKitCRM.Paths.organizations/0`.

### Added

- **`Organizations` subtab** — real LiveView (replaces the legal-entity
  placeholder) listing users typed as organizations via
  `PhoenixKit.Users.Auth.list_organizations/0`. Per-user column config,
  card/table view toggle, navigation to the PhoenixKit core user view
  on row click.
- **`PhoenixKitCRM.Paths.user_view/1`** — centralized helper for
  navigating to PhoenixKit core's user-view page from CRM tables.
  Empty-string guard raises `ArgumentError`.
- **i18n foundation** — `use Gettext, backend: PhoenixKitWeb.Gettext`
  wired into module-level code. All flashes, page titles, admin tab
  labels, modal UI strings, table headers, empty states, and column
  labels go through `gettext/1`. `ngettext` for the user-count plural.
  Russian column labels in the legacy Companies schema converted to
  English msgids; `ColumnConfig.translate_labels/1` applies `gettext`
  once at the access point so all consumers see translated labels. No
  `priv/gettext/` shipped — translations remain the host app's
  responsibility (matches sibling-module convention).
- **Whole-row click navigation** — table rows in `RoleView` and
  `OrganizationsView` are clickable and navigate to the user-view page
  via `phx-click="navigate_to_user"`.
- **Integration tests (+25)** — `role_settings_integration_test.exs`
  and `user_role_view_integration_test.exs` exercise real DB
  round-trips for upsert, scope isolation, and cross-scope rejection.
  Tagged `:integration` for opt-in.
- **GitHub Actions CI workflow** — first CI workflow in the
  `phoenix_kit_*` family. Caches `deps/`, `_build/`, `priv/plts/` on
  `mix.lock`. Runs `compile --warnings-as-errors`, `quality.ci`
  (format check + credo --strict + dialyzer), and `mix test`.

### Changed

- **LiveView lifecycle (`mount/3` + `handle_params/3` split)** —
  `RoleView` and `OrganizationsView` keep gates in `mount/3` and move
  data loading into `handle_params/3` under `if connected?(socket)`.
  At most one DB query per connected mount (eliminates the duplicate
  query from the static-render pass).
- **`RoleSettings.list_eligible_roles/0`** — filter switched from
  fragile name-match (`role.name in ["Owner", "Admin"]`) to the
  boolean `role.is_system_role`.
- **`ColumnConfig.available_columns/1`** — labels are now translated
  via `gettext` at the access point, so modal/header/card consumers
  all see the translated string.
- **Admin tab paths standardized to absolute form** — every CRM
  module tab path is now absolute (`/admin/crm/...`). Hotfixes a
  runtime crash where `Tab` registrations via
  `Registry.register/2` (used for role subtabs) bypassed
  `Tab.resolve_path/2` and surfaced `RuntimeError: Url path must
  start with "/"` from `Routes.path/2`.
- **HEEx `:if` migration** — `<%= if %>` blocks in `ColumnModal`
  replaced with `:if={...}` attributes (better diffing, statically
  analyzable).
- **Status badges** — raw HTML `<span class="badge ...">` replaced
  with the `PhoenixKitWeb.Components.Core.StatusBadge` component
  (consistent styling, theme-aware).
- **`Paths.role/1`** — empty-string input now raises
  `ArgumentError` instead of producing a malformed URL.

### Fixed

- `mount/3` no longer issues database queries (was called twice per
  initial load: HTTP + WebSocket).
- Sidebar render no longer crashes when role subtabs are registered
  via `Registry.register/2` with relative paths.
- `Paths.user_view/1` line wrapped to satisfy
  `mix format --check-formatted` (post-merge cleanup).

### Notes

- The CHANGELOG 0.1.0 entry forecast that *"the Companies legal-entity
  schema lands in 0.2.x."* The actual 0.2.0 release pivots away from
  legal-entity modeling and toward listing already-typed organization
  user accounts. The legal-entity schema remains future work,
  un-scheduled.
- Per-role uuid-aware columns are still scaffolded (the
  `available_columns/1` clause pattern-matches the role uuid away);
  picking up uuid-keyed customization is out of scope here.
- Five non-blocking review observations are recorded in
  `dev_docs/pull_requests/2026/2-cleanup-i18n-hotfix/POST_MERGE_FEEDBACK.md`
  for follow-up PRs.

## [0.1.0] - 2026-04-30

First public release of the CRM module for PhoenixKit. Implements the
`PhoenixKit.Module` behaviour for auto-discovery; ships an admin
sidebar tab with Overview, optional Companies subtab, per-role user
listings, and a settings page. Most of the moving pieces are
backbone — the Companies legal-entity schema is a deliberate
placeholder, ready to land in 0.2.x.

### Added

- **Module behaviour & auto-discovery** — `PhoenixKitCRM` implements
  `PhoenixKit.Module`: `module_key/0`, `module_name/0`, `enabled?/0`,
  `enable_system/0`, `disable_system/0`, `version/0`,
  `permission_metadata/0`, `admin_tabs/0`, `settings_tabs/0`,
  `route_module/0`, `css_sources/0`, `children/0`. Discovered at
  startup via the `@phoenix_kit_module` beam attribute — the host app
  needs no router edits.
- **Admin pages** — Overview LiveView at `/admin/crm`, Companies
  subtab at `/admin/crm/companies` (gated by `crm_companies_enabled`),
  per-role user listings at `/admin/crm/role/:role_uuid`, and the
  settings page at `/admin/settings/crm`. All use
  `use PhoenixKitWeb, :live_view` so they render inside the admin
  layout with the standard core components (`<.icon>`, `<.button>`,
  `TableDefault`, …).
- **Role opt-in flow** — `PhoenixKitCRM.RoleSettings` context
  (`list_enabled/0`, `list_eligible_roles/0`, `set_enabled/2`,
  `enabled?/1`) backed by `phoenix_kit_crm_role_settings`
  (`role_uuid` PK, FK to `phoenix_kit_user_roles`). System roles
  (Owner, Admin) are excluded from the eligible set; the rest can be
  toggled per role from the CRM settings page.
- **Per-user, per-scope view configuration** —
  `PhoenixKitCRM.UserRoleView` context backed by
  `phoenix_kit_crm_user_role_view` (`(user_uuid, scope)` unique;
  JSONB `view_config`; UUIDv7 PK). Scope is
  `:companies | {:role, role_uuid}`. `PhoenixKitCRM.ColumnConfig`
  declares available + default columns per scope and validates input.
- **Column-management mixin** —
  `use PhoenixKitCRM.Web.ColumnManagement` injects the seven event
  handlers (`show_column_modal`, `hide_column_modal`, `add_column`,
  `remove_column`, `reorder_selected_columns`,
  `update_table_columns`, `reset_to_defaults`) shared between
  `RoleView` and `CompaniesView`. The reusable
  `PhoenixKitCRM.Web.ColumnModal` function component drives drag-to-
  reorder selected columns + click-to-add available columns; UX
  matches the `PhoenixKit.Users` table column picker.
- **Companies subtab placeholder** — `CompaniesView` renders the
  table/card view with column picker and a "schema in development"
  banner. The legal-entity schema lands in a future release.
- **Runtime sidebar bootstrap** —
  `PhoenixKitCRM.SidebarBootstrap` (one-shot `Task` via
  `children/0`, `restart: :temporary`) registers per-role tabs into
  `PhoenixKit.Dashboard.Registry` under the `:phoenix_kit_crm_roles`
  namespace. Re-run from `PhoenixKitCRM.refresh_sidebar/0` after each
  `RoleSettings.set_enabled/2` call. No watcher GenServer.
- **Route module** — `PhoenixKitCRM.Routes` declares the
  parameterized `live "/admin/crm/role/:role_uuid"` route that
  resolves the runtime-registered role tabs. Defines
  `admin_routes/0` and `admin_locale_routes/0` with unique `:as`
  aliases; spliced into `phoenix_kit`'s `live_session
  :phoenix_kit_admin`.
- **`PhoenixKitCRM.Paths`** — centralized URL helpers (`index/0`,
  `companies/0`, `role/1`, `settings/0`) routed through
  `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
- **Settings keys** — `crm_enabled` (module on/off, also reflected
  on the admin Modules page), `crm_companies_enabled` (Companies
  subtab visibility).
- **Test infrastructure** — `PhoenixKitCRM.Test.Repo`,
  `PhoenixKitCRM.DataCase` (auto-tags `:integration`, sandbox
  setup), `test_helper.exs` (db-availability check via `psql -lqt`,
  `uuid_generate_v7()` SQL function setup, ExUnit start). Integration
  tests are auto-excluded when the test DB is absent.
- **Tests** — 33 in total: behaviour and tab-shape tests
  (`phoenix_kit_crm_test.exs`), pure-function tests for
  `ColumnConfig` (`available_columns`, `default_columns`,
  `validate_columns`, `get_column_metadata`, cross-scope rejection)
  and `UserRoleView` (`scope_to_string`, `scope_from_string`
  including the malformed-input fallback path, the round-trip
  property, `default_config`).
- **`mix test.setup` / `mix test.reset`** aliases and `cli/0`
  `preferred_envs` so the alias auto-runs in `:test`. `:lazy_html`
  test-only dep for `Phoenix.LiveViewTest`.
- **Documentation** — `README.md` covers features, install, routes,
  database, settings keys, and dev workflow. `AGENTS.md` is the
  AI-agents guide modeled on `phoenix_kit_hello_world` and
  `phoenix_kit_staff` — covers the actual scaffold, runtime sidebar
  bootstrap pattern + known limitation, per-user column config,
  conventions, route-module + tab hybrid, test infrastructure, and
  versioning. PR review template + first review at
  `dev_docs/pull_requests/2026/1-add-crm-module/`.

### Notes

- Migrations for `phoenix_kit_crm_role_settings` and
  `phoenix_kit_crm_user_role_view` live in `phoenix_kit` core (V105),
  not in this repo. The parent app applies them via
  `mix phoenix_kit.install` / `mix phoenix_kit.update`.
- `enabled?/0` rescues errors and returns `false` so the module
  degrades gracefully when the DB isn't available (boot race,
  migration in progress).
- `refresh_sidebar/0` logs `Logger.warning` on Registry errors instead
  of silently rescuing — Registry API drift surfaces in logs rather
  than leaving stale role tabs.
- `UserRoleView.scope_from_string/1` falls back to `:companies` and
  logs a warning on malformed input — defends against data corruption
  causing render-time crashes.
