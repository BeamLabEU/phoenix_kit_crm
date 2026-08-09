# PR #19 — Add the Client project extension for the projects hub

**Author:** Max Don (`mdon/main`)
**Merge commit:** `63c7ac5` (PR commit `7a524d3`)
**Reviewer:** Claude (Opus 5)
**Date:** 2026-08-09

## Scope

Contributes CRM's first `phoenix_kit_project_extensions/0` descriptor — the
projects hub's duck-typed, one-way provider contract — plus the contributed
tab LiveView `PhoenixKitCRM.Web.ProjectClientLive`. A project links one CRM
company through per-instance CONFIG (`company_uuid`, no FK); the tab renders
the company card, its member-contact count and the aggregated recent
interactions, read-only, with link-outs into the CRM admin.

Reviewed against the real consumer — `PhoenixKitProjects.Extensions.Extension`
(the normalizer), `.Registry` (discovery + the permission gate),
`.ConfigOptions` (config field rendering) and `ProjectShowLive`'s
`live_render` call site (the embed-session contract) — not against the PR
description.

**What the PR gets right,** and which the fixes below preserve: the one-way
contract (no dependency on `phoenix_kit_projects`), `module_key: "crm"` so
the hub's `visible_for_scope?/2` requires the CRM permission for a tab
re-exporting CRM data, `permission_actions: [:view]` so the hub resolves
`can_write: false`, no `handle_params/3` so the tab stays off-router
mountable, and `default_enabled: false`.

---

## BUG - CRITICAL — `interaction.kind` is not a field; the tab crashes on any interaction

`project_client_live.ex` rendered each row as `{interaction.kind}`.
`PhoenixKitCRM.Schemas.Interaction` has no `:kind` — the field is
`:interaction_type` (`schemas/interaction.ex`; `@types ~w(call email meeting
note other)`). Struct dot-access on a missing key raises `KeyError` at render
time.

Failure path: a project with a linked company whose member contacts have **at
least one** logged interaction. `@recent != []`, the `:for` runs, `KeyError`.
An empty CRM is fine — which is exactly why this survived a smoke test.

The blast radius is the thing the PR set out to prevent. Its `safe/1` wrapper
guards only the three mount reads; `render/1` is outside it, and the hub
renders this LV as a nested `live_render` on the project page, so the child's
crash takes the host page down with it. The commit message's "every CRM read
degrades to the empty state so a contributed tab can never crash the host
project page" held for reads and not for the render that consumes them.

**Fixed:** render `Interaction.type_label(interaction.interaction_type)` — the
same gettext-backed label `InteractionsComponent` and
`CompanyInteractionsComponent` already use, so the badge reads "Call", not
`call`. Locked by `test/phoenix_kit_crm/web/project_client_live_test.exs`,
which renders the template against in-memory structs (no DB) precisely because
the crash lives in `render/1`, where `safe/1` cannot reach.

## BUG - MEDIUM — a trashed company still presents as the live client

Linkage is config-based with no FK, so trashing a company in CRM cannot
unlink it here — and `Companies.get_company/1` returns rows of any status.
The tab kept rendering a soft-deleted company as the project's current client,
while `Companies.list_memberships/1` (deliberately) filtered its trashed
contacts out of the roster underneath it: two halves of the same card
disagreeing about what "deleted" means.

**Fixed:** the card carries a `Trashed` badge when `Company.trashed?/1`.
Chosen over blanking to the empty state, which would have claimed no client
was ever linked and hidden the stale config the admin needs to fix.

## BUG - MEDIUM — the locale is set but nothing is translatable

`maybe_put_locale/1` set the CRM Gettext locale from the session, then every
string in the template was a hardcoded English literal — including a
hand-rolled `ngettext_members/1` plural. In a module that ships `en`/`et`/`ru`
catalogs, the tab would have been the one CRM surface that ignores the host's
language.

**Fixed:** `use Gettext, backend: PhoenixKitCRM.Gettext` and every string
wrapped; the member count is now a real `ngettext/3` (Estonian and Russian
plural rules are not English's, which is what the hand-rolled clause assumed).
New strings extracted into the catalogs.

## IMPROVEMENT - HIGH — the recent-interactions read was unbounded

`Interactions.list_for_contacts/1` has no limit: it reads **every** interaction
logged on **every** member contact, preloading `:contact` and `:parties` on all
of them, and the tab then threw all but five away with `Enum.take/2`. On a
long-standing client that is the company's entire history, with two preload
round-trips, to paint five lines on a page CRM doesn't even own.

**Fixed:** `list_for_contacts/2` takes a `:limit` option (arity-1 behaviour
unchanged for `CompanyInteractionsComponent`, which legitimately shows the full
rollup) and the tab passes `limit: @recent_limit`. `Enum.take/2` is gone —
the cap is in the query.

## IMPROVEMENT - HIGH — `use Phoenix.LiveView` against the documented convention

This was the only LiveView in the repo not using `use PhoenixKitWeb,
:live_view`, which AGENTS.md names explicitly ("Do **not** switch to `use
Phoenix.LiveView` directly"). It is not cosmetic: it is why the module had no
Gettext backend, no `<.icon>`, and reached for a raw field where the rest of
the codebase reaches for a helper. Off-router mounting is not the reason —
the hub's own contributed tab (`PhoenixKitProjects.Web.ProjectWhiteboardsLive`)
uses `use PhoenixKitWeb, :live_view` in exactly this nesting position, and
core's `:layout` is a documented passthrough.

**Fixed:** switched.

## IMPROVEMENT - MEDIUM — the config field asked the admin to paste a UUID

`config_schema` declared `%{key: "company_uuid", type: :string, label:
"Company UUID"}`, and the tab's own empty state then had to explain where to
go copy a UUID from. The hub already supports better: `ConfigOptions.resolve/2`
renders `:select` fields from a literal option list **or** a lazy `{module,
fun}` source (the dashboards picker pattern), and always re-adds the stored
value even when the provider stops offering it, so a stale link stays visible
instead of silently blanking.

**Fixed:** the field is now `type: :select` with `options:
{PhoenixKitCRM.Companies, :company_options}`, and `Companies.company_options/0`
returns untrashed companies as `%{value:, label:}` — capped at 500 (the hub
re-adds the stored value regardless) and degrading to `[]` if CRM's storage is
down, so the panel renders either way. The empty-state copy now says "pick",
not "paste".

## IMPROVEMENT - MEDIUM — the Iron Law: every CRM read ran twice

`mount/3` queried unconditionally. The hub lazy-mounts extension tabs, but
`ext_initial_mounted/1` includes the **landing** tab, so opening a project
directly on its Client tab renders this LV in the parent's dead render and
again on connect — company, memberships and interactions, twice. With no
`handle_params/3` allowed, the connected-mount guard is the available fix.

**Fixed:** reads moved behind `connected?(socket)`, with a `loading` assign
so the disconnected pass paints a skeleton. Worth noting the alternative
considered and rejected: leaving the dead render to fall through to the
"No client linked to this project yet" branch would have flashed a false
statement about the project's configuration on every load.

## NITPICK — blank-name initial

`String.first(@company.name || "?")` returns `nil` for `""` or `"  "`,
rendering an empty avatar. Now trimmed, upcased, and defaulted to `?`.

---

## Tests added

No tests shipped with the PR. Added:

- `test/phoenix_kit_crm_test.exs` — `describe
  "phoenix_kit_project_extensions/0"`: three tests mirroring the hub's
  normalizer without depending on the projects package. This matters because
  the hub is defensive by design — `Extension.from_map/2` **drops** an invalid
  tab or config field with only a `Logger.warning` and registers the extension
  anyway. A typo costs the Client tab, or its company picker, silently, in the
  host app, at runtime. The tests assert the descriptor identity + permission
  wiring, that every tab passes the tab normalizer (loadable `lv`, and no
  `handle_params/3` export, which would block `live_render`), and that config
  fields use supported types with a resolvable 0-arity option source.
- `test/phoenix_kit_crm/web/project_client_live_test.exs` — six DB-free render
  tests: the interaction type label + subject (the CRITICAL regression), the
  plural member count, the trashed badge, the blank-name initial, the empty
  state, and the loading skeleton.

Both files run without a database, deliberately: the bugs they lock are in
`render/1`, which the mount's `safe/1` wrapper does not cover.

## Validation

`mix precommit` (`compile --force --warnings-as-errors` +
`deps.unlock --check-unused` + `hex.audit` + `quality.ci`) clean.
`mix test` green — integration tests auto-excluded, no Postgres in this
environment; the new tests are unit tests and did run.

Not from this PR, but blocking the gate on `main`: `deps.unlock
--check-unused` failed on eight stale `mix.lock` entries (igniter and its
tree) left by the `lib upgrades` commit. Cleared with `mix deps.unlock
--unused`; no dependency resolution changed.

## Known limitation left in place

The tab still reads CRM data on the strength of the hub's gate rather than
re-checking a scope of its own — the documented extension-tab trust model
(`ProjectShowLive` filters tabs through `ExtRegistry.visible_for_scope?/2`,
which resolves `module_key: "crm"` to the CRM permission, and the session
carries no scope for the tab to re-check). That is the contract every
contributed tab in the ecosystem follows; diverging here would be
inconsistent, not safer.
