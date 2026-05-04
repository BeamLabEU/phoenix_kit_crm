# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
