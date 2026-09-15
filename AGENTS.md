# AGENTS.md

Guidance for AI agents working on `phoenix_kit_crm`.

## Overview

An interaction-tracking CRM built on two primary entities — **contacts**
(people) and **companies** (legal entities) — with the **interactions** logged
between them. Around those sit party roles (supplier / customer / manufacturer
/ partner), mailing lists with CSV import, a duplicate/overlap comparison
report, an optional CRM↔user mirror, and per-user column configuration. Each
contact and company carries media (Files/Images, when core Storage is on),
comments (when `phoenix_kit_comments` is enabled), and an Events activity feed.
It implements the `PhoenixKit.Module` behaviour, so a host application
discovers it by adding the package to `deps` — no other config.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex), `phoenix_kit_comments` `~> 0.3`
  (hard — the contact and company profiles `use PhoenixKitComments.Embed` at
  compile time, so the dep cannot be optional; the Comments *tab* is still
  runtime-gated on `PhoenixKitComments.enabled?/0`). Also `phoenix_live_view`
  `~> 1.1`, `ecto_sql` `~> 3.13`, `gettext` `~> 1.0`, `nimble_csv` `~> 1.2`
  (list import), `rustler` (optional, mirroring core's own declaration for
  `mdex_native`), `lazy_html` (test only, for `Phoenix.LiveViewTest`).
  `phoenix_kit_staff` is deliberately **not** a dep: `PhoenixKitCRM.StaffLink`
  reaches it through `Code.ensure_loaded?/1` + `function_exported?/3` and
  degrades to empty results when it is absent or disabled.
- **Consumed by:** `phoenix_kit_projects` (its extension registry discovers
  `phoenix_kit_project_extensions/0` by name — duck-typed, one-way, no
  dependency in either direction) and `phoenix_kit_comments` (calls
  `resolve_comment_resources/1`, wired through the host's
  `:comment_resource_handlers` config). Keep those two callbacks and the
  `RoleSettings` / `UserRoleView` / `ColumnConfig` surface stable; siblings may
  start consuming them.
- **Admin surface:** one `CRM` tab at `/admin/crm` with subtabs Overview
  (`/admin/crm`), Contacts (`/admin/crm/contacts`), Companies
  (`/admin/crm/companies`), Lists (`/admin/crm/lists`), Compare
  (`/admin/crm/comparison`) and Organizations (`/admin/crm/organizations`,
  visible only while core's `enable_organization_accounts` setting is on), plus
  one runtime-registered subtab per opted-in role
  (`/admin/crm/role/:role_uuid`). Settings tab at `/admin/settings/crm`.
- **Module key** `"crm"`; settings prefix `crm_`.

## What this module does NOT do

- **No endpoint and no router.** This is a library; the host app provides both,
  and core injects the LiveViews into its own `live_session`.
- **The Overview subtab is not a dashboard.** It is a directory-led front door
  (Companies/Contacts hero cards, a by-role band whose counts deep-link the
  pre-filtered index, a conditional needs-attention row, the newest
  interactions, a Lists row). Dashboards belong to `phoenix_kit_dashboards`.
- **No `Errors` dispatcher.** Context functions return changesets or simple
  `{:error, atom}` shapes handled at the call site; there is no
  atom-to-gettext error module and none is needed yet.
- **No module-owned media table.** Attachments are folder-scoped core
  `PhoenixKit.Modules.Storage` resources (`PhoenixKitCRM.Attachments`), the
  same convention `phoenix_kit_staff` and `phoenix_kit_catalogue` use.
- **No tenant partitioning on PubSub topics.** Topics are global; the
  per-contact and per-company topics are keyed by uuid, so a subscriber must
  already know the record, which bounds fan-out. This is a framework-wide gap,
  not a CRM one.
- **No XLSX list import.** `xlsxir` was evaluated and rejected (unmaintained);
  import is CSV/plaintext only.
- **No destructive migrations.** `down/1` unstamps the version marker and
  drops nothing — pinned by a test that asserts no emitted statement matches
  `DROP` or `TRUNCATE`.

## Commands

```bash
mix deps.get
createdb phoenix_kit_crm_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_KIT_COMMENTS_PATH=../phoenix_kit_comments mix test
```

Repo-specific aliases: `mix test.setup` (`ecto.create` + `ecto.migrate` on
`PhoenixKitCRM.Test.Repo`), `mix test.reset` (drop, then `test.setup`),
`mix quality` / `mix quality.ci`. `mix precommit` here also runs
`deps.unlock --check-unused` and `mix hex.audit`.

## Conventions

- **Module key** is lowercase with underscores (`"crm"`) and is used for every
  permission lookup. **Tab ids** are prefixed `:admin_` (`:admin_crm`,
  `:admin_crm_companies`, `:admin_settings_crm`). **URL segments use hyphens,
  never underscores** — the behaviour test enforces it.
- **Never hardcode `/admin/crm/...`.** Navigation goes through
  `PhoenixKitCRM.Paths`, which is itself built on
  `PhoenixKit.Utils.Routes.path/1` for prefix and locale handling. The
  `*_raw/1` helpers return prefix-less paths and exist only for consumers that
  apply their own prefix (the comments back-link resolver).
- **Routing — two patterns coexist, never on the same path.** Tabs carrying
  `live_view:` generate their own routes (the list/index pages and settings);
  `PhoenixKitCRM.Routes` hand-declares only *parameterized and detail* routes
  (`/role/:role_uuid`, `new`, `:uuid`, `:uuid/edit`, list members/import),
  because dynamic tabs registered into the Dashboard Registry at runtime do not
  trigger router compilation. Declaring one path in both places compiles the
  host router with "this clause cannot match…", which breaks any host running
  `--warnings-as-errors`; a test pins the disjointness. `admin_routes/0` and
  `admin_locale_routes/0` must both exist, cover the same paths, and use unique
  `:as` aliases (`crm_role_view` / `crm_role_view_locale`); their quoted blocks
  are spliced inside `live_session :phoenix_kit_admin`, so they may contain
  `live` declarations and nothing else. Never hand-register CRM routes in a
  host router — routes outside that live_session lose the admin layout and
  crash on cross-page navigation.
- **LiveViews use `use PhoenixKitWeb, :live_view`** (all 16 of them). That
  imports core's components (`<.icon>`, `<.button>`, `<.input>`,
  `TableDefault`, …), gettext and the admin layout. Do not switch to
  `use Phoenix.LiveView`, and do not wrap templates in `LayoutWrapper` — admin
  LiveViews never do. Assigns available in admin pages:
  `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`, `@current_locale`,
  `@url_path`.
- **Gettext:** own backend `PhoenixKitCRM.Gettext` over `priv/gettext`
  (en, et, ru). Modules add `use Gettext, backend: PhoenixKitCRM.Gettext`
  *after* the LiveView macro. Every tab carries
  `gettext_backend: PhoenixKitCRM.Gettext` (a test asserts it). Refresh with
  `mix gettext.extract` then `mix gettext.merge priv/gettext`. Two groups of
  msgids in `priv/gettext/default.pot` are **hand-maintained** because the
  extractor cannot see them: tab labels (plain strings in `Tab.new!(label:)`)
  and column labels (module-attribute literals in `column_config.ex` resolved
  at runtime via `Gettext.gettext(backend, label)`). The `elixir-autogen` flag
  is stripped from the `"CRM"` and `"Organizations"` anchors so they survive
  the removal of their macro call sites — a re-run of `mix gettext.extract`
  re-adds the flag and line refs, so strip them again.
- **JS hooks ship as a prebuilt bundle**, `priv/static/assets/phoenix_kit_crm.js`,
  declared by `js_sources/0` under the namespaced global `PhoenixKitCRMHooks`;
  core's `:phoenix_kit_js_sources` compiler folds it into the host's module
  bundle. Never register a hook from an inline `<script>` — morphdom does not
  execute inserted script tags, so the hook vanishes on LiveView navigation.
  `js_sources/0` deliberately carries **no `@impl`**: older core releases do not
  declare the callback and annotating it warns, which fails
  `--warnings-as-errors`.
- **`css_sources/0` returns `[:phoenix_kit_crm]`.** Tailwind source discovery is
  automatic — core's `:phoenix_kit_css_sources` compiler scans this module's
  templates and writes the host's `assets/css/_phoenix_kit_sources.css`.
- **`enabled?/0` rescues and returns `false`** so the module degrades gracefully
  when the DB is not reachable (during boot, for instance).
- **Activity logging:** mutations log `"crm.<verb>"` actions through
  `PhoenixKitCRM.Activity`, a `Code.ensure_loaded?`-guarded, never-raising
  wrapper over `PhoenixKit.Activity`; the Events-tab labels live in
  `PhoenixKitCRM.ActivityLabels`. Never put PII (email, phone, free-text body)
  in activity metadata, and never set `target_uuid` to a non-user — it drives
  core notifications.
- **Soft delete** is a `status` string column with the sentinel `"trashed"` and
  the prior status stashed in `metadata`; the changeset logic is shared through
  `PhoenixKitCRM.SoftDelete`. Every listing query filters it.
- **Interaction anchor:** every interaction anchors to exactly one record,
  `contact_uuid` XOR `company_uuid` (both hard FKs, DB CHECK
  `num_nonnulls(...) = 1`). "Anchor" is the deliberate word — `subject` is the
  title. The anchor is IMMUTABLE after create (`update_changeset/2` never casts
  it) and composers stamp it server-side.
- **PubSub:** the module's own topics live on core's internal manager
  (`PhoenixKitCRM.PubSub.subscribe/1`, messages `{:crm, event, payload}`).
  Broadcasts are best-effort, rescued, and sent **after** the DB commit — a
  saved record must never be reported as failed because a broadcast hiccuped.
- **Schemas:** UUIDv7 primary keys, and every table-backed schema must
  `use PhoenixKit.SchemaPrefix` so its queries target the schema core's
  migrations installed into (a conformance test scans `lib/**/*.ex` for it).
  Free-text search terms go through `PhoenixKitCRM.Search` for LIKE/ILIKE
  escaping.
- **Index filter strips** (Contacts and Companies share the rules): the default
  tab is **All** (everything not trashed); the Active/Inactive pair appears only
  once inactive records exist; role and status tabs render only when they have
  results or are the active tab; every label carries a search-independent count;
  a tab click resets search.

### Landmines

- **Cross-module PubSub server mismatch.** Sibling modules broadcast on the
  HOST app's PubSub via `PhoenixKit.PubSubHelper`; `PubSub.subscribe/1`
  subscribes on core's *internal* manager and hears none of it. Use
  `PubSub.subscribe_host/1` (and `unsubscribe_host/1`) for any cross-module
  topic, such as the catalogue's.
- **Inner-joining `contact` on interactions silently drops company-anchored
  rows.** The feeds LEFT JOIN both anchors with a per-anchor trashed guard;
  any new interaction query must do the same.
- **`phoenix_kit_crm_role_settings` has no `id`/`uuid` column** — its primary
  key is `role_uuid` (`@primary_key {:role_uuid, :binary_id, autogenerate:
  false}`). Queries that assume the usual key shape fail at runtime.
- **Runtime role subtabs can vanish.** They live in the runtime-only
  `:phoenix_kit_crm_roles` namespace, which
  `PhoenixKit.Dashboard.Registry.load_admin_defaults/0` wipes if it is called
  at runtime. They reappear on the next `RoleSettings.set_enabled/2` or an
  application restart — an accepted trade-off for not running a persistent
  watcher GenServer.

## Architecture

```
lib/phoenix_kit_crm.ex                       # PhoenixKit.Module behaviour: tabs, route/migration
                                             # modules, css/js sources, project extension,
                                             # comment-resource resolver, refresh_sidebar/0
lib/phoenix_kit_crm/
├── paths.ex / routes.ex                     # URL helpers; parameterized admin routes
├── contacts.ex / companies.ex               # Contexts: CRUD, soft-delete, search, mirror writes
├── interactions.ex                          # Context: interactions + involved parties
├── party_roles.ex                           # supplier/customer/manufacturer/partner on a party
├── lists.ex + lists/{import,import_report}.ex  # Contact lists, CSV/plaintext import engine
├── schemas/                                 # Contact, Company, CompanyMembership, Interaction,
│                                            # InteractionParty, PartyRole, ContactList, ListMember
├── role_setting.ex / role_settings.ex       # Which roles have CRM access
├── user_role_view_config.ex / user_role_view.ex / column_config.ex   # Per-user column config
├── migrations.ex                            # Module-owned versioned chain
├── soft_delete.ex / search.ex / pub_sub.ex  # Shared helpers
├── activity.ex / activity_labels.ex         # Activity wrapper + Events-tab labels
├── mirror.ex                                # Pure diff/resolve engine for the CRM↔user mirror
├── attachments.ex                           # Core Storage folders for a contact/company
├── staff_link.ex                            # Guarded, optional phoenix_kit_staff integration
├── catalogue_import.ex                      # Engine behind the catalogue→CRM backfill tasks
├── gettext.ex / sidebar_bootstrap.ex
└── web/
    ├── crm_live.ex                          # Overview (directory front door)
    ├── contacts_live.ex / contact_form_live.ex / contact_show_live.ex
    ├── companies_live.ex / company_form_live.ex / company_show_live.ex
    ├── lists_live.ex / list_form_live.ex / list_members_live.ex / list_import_live.ex
    ├── comparison_live.ex                   # Duplicate-email + list-overlap report
    ├── organizations_view.ex / role_view.ex / settings_live.ex
    ├── project_client_live.ex               # The Client tab contributed to phoenix_kit_projects
    ├── interactions_component.ex            # Dual-anchor composer + feed (contact AND company)
    ├── events_component.ex / media_component.ex
    ├── components/{mirror_panel,mirror_conflict_modal,tab_intro}.ex
    ├── column_management.ex / column_modal.ex
    └── cell_format.ex / interaction_helpers.ex / party_role_helpers.ex
lib/mix/tasks/                               # One-time backfills: import suppliers / manufacturers
                                             # from the catalogue; rename the legacy client role
```

**Profiles.** `ContactShowLive` opens a contact with Interactions / Files /
Images / Comments / Events tabs. `CompanyShowLive` adds a Members roster and an
Interactions tab that both logs company-anchored interactions and merges its
members' own behind an All | Company | People filter; Edit rides the layout's
`page_action` chip, and the identity block (logo, status, role badges) opens the
Overview tab.

**Mirror.** A `Company` mirrors an `account_type: "organization"` user and a
`Contact` an `account_type: "person"` user. `PhoenixKitCRM.Mirror` is pure —
field maps, a per-field divergence diff, and a resolver; it never touches the
DB, and the `Companies` / `Contacts` contexts own every write. Its rules:
master is the side the form you are on transfers *from*; two non-blank,
genuinely different values are a **conflict** the caller must surface (the
conflict modal), never silently overwrite, while one blank side is just a fill;
values compare trimmed. `diff/2` and `resolve/4` key on the **CRM-side symbolic
atom** (`:name`, `:email`) for both kinds, never a raw `User` column — a
contact's `name` splits across `first_name`/`last_name`, so a diff entry must
never be fed straight into `put_change/3`.

**Tab registration.** Static tabs come from `admin_tabs/0` and
`settings_tabs/0`. Per-role tabs are registered at runtime by
`PhoenixKitCRM.SidebarBootstrap` into `PhoenixKit.Dashboard.Registry` under
`:phoenix_kit_crm_roles`, in two places: at boot via `children/0` as a one-shot
`Task` (`restart: :temporary`), and after every `RoleSettings.set_enabled/2`
via `PhoenixKitCRM.refresh_sidebar/0` (which unregisters, then re-bootstraps).

**Per-user column configuration.** `PhoenixKitCRM.ColumnConfig` defines
available columns and defaults per scope: `:organizations`, and
`{:role, role_uuid}` (mirroring the standard PhoenixKit user fields — email,
username, full_name, status, registered, last_confirmed, location). Selections
persist through `PhoenixKitCRM.UserRoleView`, keyed by
`(user_uuid, scope_string)`. The picker UI is `Web.ColumnModal`, wired into
LiveViews with `use PhoenixKitCRM.Web.ColumnManagement`.

**PubSub topics** (all via `PhoenixKitCRM.PubSub`):

| Topic | Carries |
|---|---|
| `crm:contact:<uuid>:interactions` | One contact's feed — as interaction subject or resolved party |
| `crm:company:<uuid>:interactions` | One company's feed — company-**anchored** interactions only |
| `crm:company:<uuid>` | One company's page: member roster joins/leaves/renames |
| `crm:lists` | Contact-list membership changes and counters |

Interaction messages are `{:crm, event, %{interaction_uuid: uuid}}` with `event`
one of `:interaction_created | :interaction_updated | :interaction_deleted`;
roster messages are `{:crm, event, %{contact_uuid: uuid}}` with `:member_joined
| :member_left | :member_changed`. A company's soft-delete flip sends
`{:crm, :company_visibility_changed, %{company_uuid: uuid}}` to each affected
party contact's feed.

**Settings.** `crm_enabled` (module on/off, via `enable_system/0` /
`disable_system/0`) is the only key this module owns. It reads core's
`enable_organization_accounts` to decide whether the Organizations subtab is
visible, and core's `time_zone` for interaction timestamps.

**Permission.** One key, `"crm"` (label "CRM", icon `hero-users`), carried by
every tab; no sub-permissions. The contributed projects extension declares
`module_key: "crm"` and `permission_actions: [:view]` so a tab re-exporting CRM
data requires the CRM permission, not the viewer's projects permission — and so
the hub derives no write surface from it.

**Cross-module surface.** CRM consumes `PhoenixKit.Users.Roles` (eligible-role
listing excludes the system Owner and Admin roles) and
`PhoenixKit.Users.Auth.User` (referenced by UUID from
`phoenix_kit_crm_user_role_view` and from `companies.user_uuid`).

## Database & migrations

Owns a versioned chain: `PhoenixKitCRM.Migrations` via `migration_module/0`,
marker `crm_schema:<N>` as a `COMMENT ON TABLE phoenix_kit_crm_contacts`,
currently **V06**. `mix phoenix_kit.update` applies it in hosts; the test suite
applies it through `PhoenixKitCRM.Test.SchemaMigration` (see Testing).
A marker-less table reads as version 0 — the core-baseline shape from before
the chain existed.

Adoption rules:

- **V01 is adoptive and must never be edited.** It `CREATE TABLE IF NOT EXISTS`
  nine tables core historically created, shape-identical to core's DDL
  (constraint and index names included), and adds the one genuinely new object:
  `phoenix_kit_crm_companies.user_uuid` (nullable FK → `phoenix_kit_users`,
  `ON DELETE SET NULL`) plus its partial unique index. Because V01 changes no
  adopted shape, core's `ExpectedSchema` manifest stays accurate and no core
  release is needed for it.
- **A shape change is V2+ and needs core's ExpectedSchema exclusion first.**
  Core's chain always runs ahead of this one, so adoption's presence-only check
  is safe: by the time V01 runs, every adopted table is already at core's
  current shape.
- **Every statement is idempotent** (`IF NOT EXISTS`, guarded `DO $$ …
  pg_constraint … $$`, `COMMENT`), so the chain replays safely.
  `up_statements/1` returns the SQL as data — the testable single source.
- **`down/1` drops nothing.** It only unstamps or re-stamps the marker.

Module-owned tables:

- `phoenix_kit_crm_contacts` — people (the primary entity); soft-delete via `status`
- `phoenix_kit_crm_companies` — legal entities; soft-delete via `status`; `user_uuid` is the mirror link
- `phoenix_kit_crm_company_memberships` — contact↔company associations (role / department)
- `phoenix_kit_crm_interactions` — logged interactions, anchored to a contact XOR a company
- `phoenix_kit_crm_interaction_parties` — an interaction's involved parties and their frozen snapshots
- `phoenix_kit_crm_party_roles` — supplier/customer/manufacturer/partner on companies and contacts (polymorphic soft ref); a CHECK pins the vocabulary and a partial unique index on `(roleable_uuid, role) WHERE is_active` makes a duplicate active role impossible
- `phoenix_kit_crm_lists` / `phoenix_kit_crm_list_members` — mailing lists and members
- `phoenix_kit_crm_role_settings` — primary key `role_uuid` (FK → `phoenix_kit_user_roles`); columns `enabled`, `inserted_at`, `updated_at`
- `phoenix_kit_crm_user_role_view` — UUIDv7 PK; `(user_uuid, scope)` unique; `view_config` is a JSON map

All schemas use UUIDv7 primary keys and `use PhoenixKit.SchemaPrefix`.

## Testing

Test DB `phoenix_kit_crm_test` against `PhoenixKitCRM.Test.Repo`; create it once
with `createdb phoenix_kit_crm_test` (or `mix test.setup`). Without a reachable
DB, `:integration`-tagged tests auto-exclude and the unit tests still run — the
behaviour, migration-SQL, mirror, search, path, activity-label and conformance
tests are all DB-free.

`config/test.exs` sets `config :phoenix_kit, repo: PhoenixKitCRM.Test.Repo`;
without it every call through `PhoenixKit.RepoHelper` crashes with "No
repository configured". It also sets `config :phoenix_kit, pubsub:
PhoenixKitCRM.Test.PubSub`, the host server `subscribe_host/1` targets.
PG env vars honoured: `PGUSER`, `PGPASSWORD`, `PGHOST`, `PGPORT`, `PGDATABASE`,
`MIX_TEST_PARTITION`.

`test/test_helper.exs`, in order: refuses to run against a known live database
by name (`LiveDatabaseGuard`); probes for the test DB and starts the repo;
checks the `schema_migrations` ownership marker when `PGDATABASE` is set
(`SchemaOwnerGuard`, so a shared DB owned by another package cannot have this
package's same-numbered migrations silently skipped); creates the `uuid-ossp`
extension and a `uuid_generate_v7()` function; runs core's chain with
`PhoenixKit.Migration.ensure_current/2`; runs the module's own chain through
`Ecto.Migrator` against `PhoenixKitCRM.Test.SchemaMigration`; stamps ownership;
starts `PhoenixKit.PubSub.Manager`, `PhoenixKit.ModuleRegistry`, the rate-limiter
backend and the test Endpoint; forces the URL prefix to `/` (so admin paths
resolve under `/en/admin/crm`, which the test router mounts); and installs a
logger filter that drops the expected `"Failed to query setting …"` sandbox
noise.

`PhoenixKitCRM.Test.SchemaMigration.migrator_version/0` deliberately offsets the
chain version by a large constant: `schema_migrations` on a shared test DB is
one physical table every sibling module writes into, and a bare `{1, Module}`
entry collides with another package's version 1 and is treated as already
applied.

Support modules:

- `test/support/test_repo.ex` — `PhoenixKitCRM.Test.Repo`
- `test/support/data_case.ex` — auto-tags `:integration`, sets up the SQL sandbox
- `test/support/live_case.ex` — LiveView case: wires `Test.Endpoint` and the
  sandbox, provides `fake_scope/1` and `put_test_scope/2`, imports
  `ActivityLogAssertions`
- `test/support/{test_endpoint,test_router,test_layouts,test_hooks}.ex` — a
  `server: false` endpoint plus a router mounting the CRM LiveViews under
  `/en/admin/crm`, minimal layouts, and an `on_mount` hook faking
  scope/current_user from the test session
- `test/support/activity_log_assertions.ex` — `assert_activity_logged/2` and
  `refute_activity_logged/2` (match action plus an actor / resource / metadata
  subset)
- `test/support/{schema_owner_guard,live_database_guard,schema_migration}.ex`

Conditional exclusions beyond `:integration`:
`:requires_phoenix_kit_i18n_api` (the resolved core must export
`PhoenixKit.Dashboard.Tab.localized_label/1`) and `:requires_catalogue` (the
supplier-import tests need `phoenix_kit_cat_suppliers.crm_company_uuid` in the
test DB).

Conformance tests worth knowing about: `core_pin_conformance_test.exs` fails the
build if the `:phoenix_kit` requirement is re-narrowed to a single core minor
(the `~> 2.0.x` trap, which only breaks consumers) or if a local path override
reaches a commit; `schema_prefix_conformance_test.exs` scans `lib/` for a
table-backed schema missing `use PhoenixKit.SchemaPrefix`.

Known noise: `Phoenix.LiveViewTest` emits `missing_form_id` warnings for forms
rendered without an `id`, and the logger filter above swallows the settings
`OwnershipError` messages background processes produce without a sandbox
connection. Neither is a failure.

The suite touches the SQL sandbox plus spawned settings queries, so vary the
seed when checking stability:

```bash
for s in 0 1 2 3 17 42 99 999; do mix test --seed $s; done
```

## Feature notes

None. Feature behaviour is documented in `@moduledoc`s; the design records
behind the party-role vocabulary, the interaction tracker and the
suppliers/clients model live under `dev_docs/design/` and `dev_docs/research/`.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- **`test_helper.exs` still gates on core shipping the CRM tables.** Its
  `crm_tables_present` probe and the `PHOENIX_KIT_PATH` hint it prints predate
  the module-owned chain, which now creates those tables itself; the branch is
  dead. Remove it the next time that file is touched. The same stale rationale
  sits in the `pk_dep/3` comment in `mix.exs`.
