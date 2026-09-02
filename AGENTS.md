# AGENTS.md

Guidance for AI agents working on the `phoenix_kit_crm` plugin module.

## Project overview

PhoenixKit CRM module — an interaction-tracking CRM. Implements the
`PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

Two primary entities: **contacts** (people) and **companies** (legal entities),
with the **interactions** logged between them. Each contact/company carries media
(Files/Images, when core Storage is on), comments (when `phoenix_kit_comments` is
installed), and an Events activity feed. The role opt-in flow and per-user view
configuration round it out.

Registers one admin tab (`CRM`) with subtabs:

- **Overview** (`/admin/crm`) — a directory-led front door: Companies/Contacts
  hero cards, a By-role band (each count deep-links the pre-filtered index),
  a conditional needs-attention row (companies without live contacts → the
  index's `?filter=no-contacts`), the newest interactions, and a Lists row.
  Deliberately an overview, NOT a dashboard (the dashboards module owns those).
- **Contacts** (`/admin/crm/contacts`) — the people list; each opens a profile
  (`ContactShowLive`) with Interactions / Files / Images / Comments / Events tabs
- **Companies** (`/admin/crm/companies`) — legal entities; each opens
  `CompanyShowLive` with a Members roster and an Interactions tab that both
  logs company-anchored interactions and merges the members' own behind an
  All | Company | People filter. Edit rides the layout's `page_action` chip;
  the identity block (logo/status/role badges) opens the Overview tab.
- **Lists** (`/admin/crm/lists`) — mailing lists (members, import, opt-out)
- **Compare** (`/admin/crm/comparison`) — duplicate-email + list-overlap report
- **Organizations** (`/admin/crm/organizations`) — organizations view
- **Role subtabs** (`/admin/crm/role/:role_uuid`) — one per opted-in role,
  registered at runtime into `PhoenixKit.Dashboard.Registry`

Both index pages share the same filter-strip rules: the default tab is **All**
(everything not trashed), the Active/Inactive pair appears only once inactive
records exist, role/status tabs render only with results (or while active),
every label carries a search-independent count, and a tab click resets search.

Plus a settings tab at `/admin/settings/crm`.

## Architecture notes

- **Schemas + contexts** under `lib/phoenix_kit_crm/` — the `Contacts`,
  `Companies`, and `Interactions` contexts over `Schemas.{Contact, Company,
  CompanyMembership, Interaction, InteractionParty}`. Soft-delete is a `status`
  string column (`"trashed"`) with the prior status stashed in `metadata`; the
  changeset logic is shared via `PhoenixKitCRM.SoftDelete`.
- **Interaction ANCHOR (V05)** — every interaction anchors to exactly one
  record: `contact_uuid` XOR `company_uuid` (both hard FKs, DB CHECK
  `num_nonnulls(...) = 1`). "Anchor" is the deliberate word — the `subject`
  column is the title. The anchor is IMMUTABLE after create
  (`Interaction.update_changeset/2` never casts it); composers stamp it
  server-side. Any query inner-joining `contact` silently drops company rows —
  the feeds LEFT JOIN both anchors with per-anchor trashed guards.
- **Activity logging** — mutations log `"crm.<verb>"` actions through
  `PhoenixKitCRM.Activity` (a `Code.ensure_loaded?`-guarded wrapper over
  `PhoenixKit.Activity`); the Events-tab labels live in
  `PhoenixKitCRM.ActivityLabels`. Never put PII (email / phone / free-text body)
  in activity metadata, and don't set `target_uuid` to a non-user (it drives core
  notifications).
- **Migrations** — the module owns its own versioned chain
  (`PhoenixKitCRM.Migrations`, currently V05) via
  `PhoenixKit.Module.migration_module/0`; V01 adopts the tables core
  historically created — see "Database" below.
- **No `Errors` dispatcher** — context functions return changesets or simple
  `{:error, atom}` shapes handled at the call site; there is no atom-to-gettext
  error module (none is needed yet).

## Common commands

```bash
mix deps.get                # Install dependencies
mix compile                 # Compile

mix test                    # Unit tests (excludes :integration when DB is absent)
mix test test/phoenix_kit_crm_test.exs  # Behaviour tests only

mix format                  # Format (uses Phoenix LiveView import rules)
mix credo --strict          # Lint
mix dialyzer                # Static type checking
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer

mix test.setup              # createdb + migrate the test repo
mix test.reset              # drop + recreate + migrate the test repo
```

## Dependencies

This is a **library** (no endpoint, no router). Direct deps:

- `phoenix_kit` (`~> 2.0`, via the `pk_dep/3` local-path helper) — Module behaviour, Settings, RepoHelper, Dashboard tabs, admin layout, `Users.Roles`
- `phoenix_live_view` (`~> 1.1`) — admin LiveViews
- `ecto_sql` (`~> 3.13`) — schemas and changesets (`RoleSetting`, `UserRoleViewConfig`)
- `lazy_html` (test only) — required by `Phoenix.LiveViewTest`

## Architecture

### File layout

```
lib/phoenix_kit_crm.ex                                # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_crm/
├── paths.ex                                          # Centralized URL helpers (always go through Routes.path/1)
├── routes.ex                                         # Parameterized admin routes (per-role view)
├── role_setting.ex                                   # Schema: phoenix_kit_crm_role_settings
├── role_settings.ex                                  # Context: list_enabled, list_eligible_roles, set_enabled
├── user_role_view_config.ex                          # Schema: phoenix_kit_crm_user_role_view
├── user_role_view.ex                                 # Context: get/put view config keyed by (user_uuid, scope)
├── column_config.ex                                  # Available columns + defaults per scope
├── sidebar_bootstrap.ex                              # Registers per-role tabs into Dashboard.Registry
└── web/
    ├── crm_live.ex                                   # CRM landing LiveView (Overview)
    ├── contacts_live.ex                              # Contacts list
    ├── contact_form_live.ex                          # Contact new/edit form
    ├── contact_show_live.ex                          # Contact profile (Interactions/Files/Images/Comments/Events)
    ├── companies_live.ex                             # Companies list
    ├── company_form_live.ex                          # Company new/edit form
    ├── company_show_live.ex                          # Company profile (Members + tabs)
    ├── organizations_view.ex                         # Organizations LiveView
    ├── role_view.ex                                  # Per-role users LiveView
    ├── settings_live.ex                              # Settings LiveView (module toggle, role opt-in + portal links)
    ├── interactions_component.ex                     # Dual-anchor composer + feed (contact page AND company page)
    ├── events_component.ex                           # Events (activity) feed tab
    ├── media_component.ex                            # Files/Images tab (core Storage)
    ├── column_management.ex / column_modal.ex        # Per-user column picker
    └── cell_format.ex / interaction_helpers.ex       # Render helpers
```

### Settings keys

- `crm_enabled` — module on/off (set via `enable_system/0` / `disable_system/0`)

### Tab registration

- Static tabs (Overview, Contacts, Companies, Organizations, settings) come from `admin_tabs/0` and `settings_tabs/0`.
- **Per-role tabs are runtime-registered** by `PhoenixKitCRM.SidebarBootstrap` into `PhoenixKit.Dashboard.Registry` under `:phoenix_kit_crm_roles`. Bootstrap runs:
  1. At boot, via `children/0` as a one-shot `Task` (`restart: :temporary`).
  2. After every `RoleSettings.set_enabled/2`, via `PhoenixKitCRM.refresh_sidebar/0` (which unregisters then re-bootstraps).
- The matching parameterized route `/admin/crm/role/:role_uuid` is declared in `PhoenixKitCRM.Routes` because dynamic tabs registered into the Dashboard Registry at runtime do not trigger router compilation.

> **Known limitation:** if `PhoenixKit.Dashboard.Registry.load_admin_defaults/0` is invoked at runtime, the `:phoenix_kit_crm_roles` namespace is wiped. Role tabs reappear on the next `set_enabled/2` call or on application restart. This is an accepted trade-off for not running a persistent watcher GenServer.

### Per-user column configuration

`PhoenixKitCRM.ColumnConfig` defines available columns + defaults per scope. Scopes:

- `:organizations` — columns for the organizations view
- `{:role, role_uuid}` — mirrors standard PhoenixKit user fields (email, username, full_name, status, registered, last_confirmed, location)

Selections are persisted via `PhoenixKitCRM.UserRoleView` (keyed by `(user_uuid, scope_string)`). The column-modal UI lives in `PhoenixKitCRM.Web.ColumnModal` and is wired into LiveViews through `use PhoenixKitCRM.Web.ColumnManagement`.

### Critical conventions (inherited from the template)

- **Module key**: lowercase with underscores (`"crm"`); used everywhere for permission lookups and `module_key()` references.
- **Tab IDs**: prefixed with `:admin_` (`:admin_crm`, `:admin_crm_companies`, `:admin_settings_crm`).
- **URL paths in tabs**: hyphens, not underscores. The behaviour test at `test/phoenix_kit_crm_test.exs` enforces this.
- **Navigation**: always use `PhoenixKitCRM.Paths` (or `PhoenixKit.Utils.Routes.path/1` directly). Never hardcode `/admin/crm/...` in templates.
- **`enabled?/0`**: rescues errors and returns `false` so the module degrades gracefully when the DB isn't available (e.g. during boot).
- **LiveViews** use `use PhoenixKitWeb, :live_view` — this imports PhoenixKit core components (`<.icon>`, `<.button>`, `<.input>`, `TableDefault`, etc.), Gettext, and the admin layout. Do **not** switch to `use Phoenix.LiveView` directly.
- **JavaScript hooks**: must be inline `<script>` tags; register on `window.PhoenixKitHooks`.
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`, `@current_locale`, `@url_path`.

### Routing

> **Never hand-register CRM LiveView routes in the parent app's `router.ex`.** PhoenixKit injects them into its own `live_session :phoenix_kit_admin` automatically. Routes outside that session lose the admin layout and crash on cross-page navigation.

Two patterns coexist in this module:

1. **`live_view:` on tabs** (Overview, Companies, settings) — auto-generated routes from `admin_tabs/0` / `settings_tabs/0`.
2. **Route module** (`PhoenixKitCRM.Routes`) — hand-written `live` declarations for parameterized routes. Both `admin_routes/0` and `admin_locale_routes/0` must be defined and use unique `:as` aliases (e.g. `crm_role_view` and `crm_role_view_locale`).

`admin_routes/0` and `admin_locale_routes/0` quoted blocks are spliced inside `live_session :phoenix_kit_admin do … end` — they may only contain `live` declarations.

### Tailwind CSS scanning

`css_sources/0` returns `[:phoenix_kit_crm]`. CSS source discovery is automatic at compile time — the `:phoenix_kit_css_sources` compiler scans this module's templates and writes into `assets/css/_phoenix_kit_sources.css` in the parent app.

## Database

**The module owns its schema through its own versioned chain** —
`PhoenixKitCRM.Migrations` (currently **V05**), reached via the
`PhoenixKit.Module.migration_module/0` callback and applied by
`mix phoenix_kit.update`. V01 *adopts* the tables core historically created
(guarded `CREATE TABLE IF NOT EXISTS`); later versions are this repo's to
write — V05 relaxed `interactions.contact_uuid` and added the `company_uuid`
anchor arm. The applied version is a `crm_schema:<N>` comment marker on
`phoenix_kit_crm_contacts`; every statement is idempotent and `down/1` never
drops a table (pinned by tests).

Module-owned tables:

- `phoenix_kit_crm_contacts` — people (the primary entity); soft-delete via a `status` column
- `phoenix_kit_crm_companies` — legal entities; soft-delete via `status`
- `phoenix_kit_crm_company_memberships` — contact↔company associations (role / department)
- `phoenix_kit_crm_interactions` — logged interactions, anchored to a contact XOR a company (V05)
- `phoenix_kit_crm_interaction_parties` — an interaction's involved parties + their frozen snapshots
- `phoenix_kit_crm_party_roles` — supplier/customer/manufacturer/partner roles on companies and contacts (polymorphic soft ref)
- `phoenix_kit_crm_lists` / `phoenix_kit_crm_list_members` — mailing lists + members
- `phoenix_kit_crm_role_settings` — primary key is `role_uuid` (FK to `phoenix_kit_user_roles`); columns `enabled`, `inserted_at`, `updated_at`.
- `phoenix_kit_crm_user_role_view` — `(user_uuid, scope)` is unique; `view_config` is a JSON map; UUIDv7 primary key.

The role-settings schema uses `@primary_key {:role_uuid, :binary_id, autogenerate: false}` — there's no separate `id` / `uuid` column. Be careful when writing new queries.

## Testing

### Setup

This module owns its own test database (`phoenix_kit_crm_test`) and a test repo (`PhoenixKitCRM.Test.Repo`). Create the DB once:

```bash
createdb phoenix_kit_crm_test
mix test.setup     # ecto.create + ecto.migrate
```

If the DB is absent, integration tests auto-exclude via the `:integration` tag (see `test/test_helper.exs`) — unit tests still run.

The critical config wiring is in `config/test.exs`:

```elixir
config :phoenix_kit, repo: PhoenixKitCRM.Test.Repo
```

Without this, all DB calls through `PhoenixKit.RepoHelper` crash with "No repository configured".

### Test infrastructure

- `test/support/test_repo.ex` — `PhoenixKitCRM.Test.Repo`
- `test/support/data_case.ex` — auto-tags `:integration`, sets up the SQL sandbox
- `test/support/live_case.ex` — LiveView case: wires `Test.Endpoint` + the SQL
  sandbox, provides `fake_scope/1` + `put_test_scope/2`, and imports
  `ActivityLogAssertions`
- `test/support/{test_endpoint,test_router,test_layouts,test_hooks}.ex` — a
  `server: false` endpoint + router mounting the CRM LiveViews under
  `/en/admin/crm`, minimal layouts, and an `on_mount` hook that fakes
  scope/current_user from the test session
- `test/support/activity_log_assertions.ex` — `assert_activity_logged/2` +
  `refute_activity_logged/2` (match action + actor / resource / metadata subset)
- `test/test_helper.exs` — checks DB availability, creates `uuid_generate_v7()`,
  migrates the test DB to the current core version (`ensure_current`), starts the
  PubSub manager / module registry / test endpoint, forces the URL prefix to `/`,
  and filters the expected OwnershipError settings-query log noise

Run the integration + LiveView tests against a **local core checkout** — the CRM
tables migration ships in core and is unreleased:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

### Current coverage

- **Module behaviour** (`phoenix_kit_crm_test.exs`) — callbacks, permission
  metadata, `admin_tabs/0`, `settings_tabs/0`, `Paths`
- **Contexts** — `Contacts` / `Companies` / `Interactions`: create+update
  validation, get (incl. malformed uuid), soft-delete guards, listing + count,
  search, `list_by_uuids`, interaction parties + frozen snapshots, and the
  involving / for-contacts queries
- **Helpers** — `SoftDelete`, `ActivityLabels`, `PubSub.involved_contact_uuids`,
  `Paths`, and the `resolve_comment_resources/1` comment back-link resolver
- **LiveViews** (`test/phoenix_kit_crm/web/`) — contacts/companies index render,
  contact/company show + redirect-on-unknown, new/edit forms (create logs
  `crm.<entity>_created`, blank-name validation, edit updates), and the list
  trash action (logs `crm.contact_trashed`) — activity verified via
  `ActivityLogAssertions`

### Stability check

The suite touches the SQL sandbox + spawned settings queries, so vary the seed:

```bash
for s in 0 1 2 3 17 42 99 999; do PHOENIX_KIT_PATH=../phoenix_kit mix test --seed $s; done
```

## Versioning & releases

This project follows [Semantic Versioning](https://semver.org/). The version must be updated in **two** places when bumping:

1. `mix.exs` — `@version` module attribute
2. `lib/phoenix_kit_crm.ex` — `def version, do: "x.y.z"`

(There is no version compliance test today; add one when the test surface grows.)

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
gh release create 0.1.0 --title "0.1.0 - YYYY-MM-DD" --notes "..."
```

### Full release checklist

1. Update version in `mix.exs` and `lib/phoenix_kit_crm.ex`.
2. Add a `CHANGELOG.md` entry.
3. Run `mix precommit` — ensure zero warnings/errors.
4. Commit: `"Bump version to x.y.z"`.
5. Push to `main` and **verify the push succeeded** before tagging.
6. `git tag x.y.z && git push origin x.y.z`.
7. `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`.

**Never tag before all changes are committed and pushed.** Tags are immutable pointers.

## Pull requests

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/`. Use `{AGENT}_REVIEW.md` (e.g. `CLAUDE_REVIEW.md`).

Severity levels:

- `BUG - CRITICAL` — crashes, data loss, security issues
- `BUG - HIGH` — incorrect behavior that affects users
- `BUG - MEDIUM` — edge cases, minor incorrect behavior
- `IMPROVEMENT - HIGH` — significant code-quality or performance issue
- `IMPROVEMENT - MEDIUM` — better patterns or maintainability
- `NITPICK` — style, naming, minor suggestions

### Commit message rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`. **Do not include AI attribution or `Co-Authored-By` footers** unless the user asks for it.

## Cross-module integration

CRM consumes `PhoenixKit.Users.Roles` (eligible-role listing excludes the system Owner and Admin roles) and `PhoenixKit.Users.Auth.User` (referenced by UUID in `phoenix_kit_crm_user_role_view`). Keep the public surface (`PhoenixKitCRM.RoleSettings`, `PhoenixKitCRM.UserRoleView`, `PhoenixKitCRM.ColumnConfig`) stable — sibling modules may start consuming it.
