# PhoenixKitCRM

CRM module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) — implements the `PhoenixKit.Module` behaviour for auto-discovery by a parent Phoenix application.

An interaction-tracking CRM: **contacts** (people) and **companies** (legal entities), the interactions logged between them, each with its own media, comments, and activity feed. Roles opt in to CRM access, and every admin gets per-user column configuration.

## Features

- **Contacts** — people with profile fields, an optional linked login account, a circular avatar, and soft-delete (trash/restore). Each contact has **Interactions**, **Files**, **Images**, **Comments**, and **Events** (activity) tabs.
- **Companies** — legal entities with a **Members** roster (contacts + their role/department), an **Interactions** rollup across those members, a logo, soft-delete, and the same Files/Images/Comments/Events tabs.
- **Interactions** — logged interactions (call/email/meeting/note/other) anchored to a contact, with resolvable involved parties (CRM contacts or staff people) and a profile snapshot frozen at save time.
- **Role opt-in** — choose which non-system roles can access CRM; enabled roles get their own subtab under `/admin/crm/role/:role_uuid`.
- **Per-user column config** — each admin picks which columns to show; the layout is persisted in `phoenix_kit_crm_user_role_view`.
- **Activity logging** — create/update/trash/delete across contacts, companies, and interactions is recorded and surfaced on each record's Events tab.
- **Auto-discovery** — no parent-app router edits; PhoenixKit picks the module up via the `@phoenix_kit_module` beam attribute.

Files/Images tabs require core **Storage** to be enabled; the **Comments** tab requires the `phoenix_kit_comments` module.

## Installation

Add to the parent PhoenixKit app's `mix.exs`:

```elixir
# Local development
{:phoenix_kit_crm, path: "../phoenix_kit_crm"}

# or, once published / pinned to a tag
{:phoenix_kit_crm, "~> 0.6"}
```

Then `mix deps.get`. The module appears in **Admin > Modules** and the
sidebar automatically; toggle it on to expose `/admin/crm`.

## Routes

| Path                                         | LiveView                          |
|----------------------------------------------|-----------------------------------|
| `/admin/crm`                                 | `PhoenixKitCRM.Web.CRMLive`       |
| `/admin/crm/contacts`                        | `PhoenixKitCRM.Web.ContactsLive`  |
| `/admin/crm/contacts/new` · `/:uuid/edit`    | `PhoenixKitCRM.Web.ContactFormLive` |
| `/admin/crm/contacts/:uuid`                  | `PhoenixKitCRM.Web.ContactShowLive` |
| `/admin/crm/companies`                       | `PhoenixKitCRM.Web.CompaniesLive` |
| `/admin/crm/companies/new` · `/:uuid/edit`   | `PhoenixKitCRM.Web.CompanyFormLive` |
| `/admin/crm/companies/:uuid`                 | `PhoenixKitCRM.Web.CompanyShowLive` |
| `/admin/crm/organizations`                   | `PhoenixKitCRM.Web.OrganizationsView` |
| `/admin/crm/role/:role_uuid`                 | `PhoenixKitCRM.Web.RoleView`      |
| `/admin/settings/crm`                        | `PhoenixKitCRM.Web.SettingsLive`  |

The CRM section appears only after the module is toggled on under **Admin > Settings > CRM**; per-role subtabs appear for each opted-in role.

## Database

The module's tables live in `phoenix_kit` **core** (the CRM tables migration), per the PhoenixKit convention — not in this repo:

- `phoenix_kit_crm_contacts`, `phoenix_kit_crm_companies`, `phoenix_kit_crm_company_memberships` — the people, legal entities, and their associations
- `phoenix_kit_crm_interactions`, `phoenix_kit_crm_interaction_parties` — logged interactions + their involved parties
- `phoenix_kit_crm_role_settings` — which roles have CRM access enabled
- `phoenix_kit_crm_user_role_view` — per-user, per-scope view configuration

The parent app applies them via `mix phoenix_kit.install` / `mix phoenix_kit.update`.

## Settings keys

- `crm_enabled` — module on/off (also reflected on the Modules page)

## Development

```sh
mix deps.get
mix compile
mix test            # unit tests; integration tests excluded if no DB
mix precommit       # compile + format + credo --strict + dialyzer
```

For integration tests, create the test database once:

```sh
createdb phoenix_kit_crm_test
```

The CRM's tables migration ships in `phoenix_kit` core. Until that core release is
published, run the suite against a **local core checkout** so the test DB migrates
to the version that has the CRM tables:

```sh
PHOENIX_KIT_PATH=../phoenix_kit mix test
```

With `PHOENIX_KIT_PATH` unset, the published Hex pin is used (publish/CI-safe).

See [`AGENTS.md`](AGENTS.md) for the development conventions, file layout,
and testing setup.

## License

MIT — see [LICENSE](LICENSE).
