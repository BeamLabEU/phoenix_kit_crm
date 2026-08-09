# PR #17 review — Make the CRM usable: link contacts to accounts, rename the colliding role, and bring the UI up to standard

**Author:** timujinne
**Branch:** `feature/crm-linkage-and-ui`
**Merge commit:** `a09dae9` (files: 28, +1135/−673)

## Summary

Four largely independent changes landed together:

1. **`client` → `customer`** across `PartyRole`'s `@roles`, the contacts and
   companies role filters, `PartyRoleHelpers`' label/badge clauses, and the
   whole `party_roles_test.exs` suite.
2. **Contact ⇄ login-account linkage**: a `crm_contact` column on the per-role
   users table (`RoleView`), a real link to the login account on the contact
   profile's Overview, and an **Orders** tab fed by the host application's
   optional `Andi.CRMBridge`.
3. **A real CRM landing page** (`CRMLive`) — four count cards, an empty-state
   card, a re-labelled "Portal access" roles section — plus a `Compare` tab
   registration.
4. **UI standardisation**: `mx-auto max-w-*` dropped from the page wrappers,
   `phx-click` checkboxes converted to core's `<.checkbox>`, `join`-styled
   pagination, and `phx-click="navigate_to_user"` rows replaced with core's
   `<.row_link>` stretched-link overlay (which is what raised the
   `phoenix_kit` floor to `>= 1.7.219`).

The linkage work and the UI sweep are sound, and most of the individual
mechanics check out (the `<.checkbox>` component does declare `attr :rest,
:global`, so the `phx-click` / `phx-value-uuid` forwarding the conversions rely
on genuinely works; the `Andi.CRMBridge` guard is the same shape as
`StaffLink`'s and core's own guard on this module; `handle_params/3` is used
for every DB read, not `mount/3`). The findings below are what the diff got
wrong.

## Verification performed

- Unpacked the `<.checkbox>` and `<.row_link>` components from the resolved
  `phoenix_kit` 1.7.220 to confirm the attrs the new call sites pass actually
  exist (`wrapper_class`, `:description` slot, `:global` rest, `navigate` +
  `label`), and to confirm `row_link/1`'s documented "the row must be the
  positioned ancestor" contract — which finding 3 violates.
- Traced `PartyRole.roles/0` through `PartyRoleHelpers.sync_roles/3` and
  `selected_roles/1` to establish exactly what happens to a pre-rename
  `"client"` row (finding 1): it is *not* silently revoked, but it is
  unreachable from every UI path.
- Cross-checked `CHANGELOG.md` to confirm `supplier`/`client`/`partner` shipped
  in a published `0.2.x` release, so stranded rows are a real upgrade scenario
  rather than a hypothetical.
- Checked each count in `load_counts/0` against the default scope of the page
  its card links to (finding 5).
- Ran the repo gate (`mix quality.ci`) on the merged tree.

## Findings

### 1. BUG - HIGH — the `client` → `customer` rename strands data already in production databases

`lib/phoenix_kit_crm/schemas/party_role.ex:32`

`@roles` went from `~w(supplier client partner)` to `~w(supplier customer
partner)` with no data migration, no changelog note, and no version bump.
`supplier`/`client`/`partner` shipped in a published `0.2.x` release
(`CHANGELOG.md:116`), so any host that granted a `client` role before this PR
now has rows the new code cannot see or manage:

- `list_companies_with_role("customer")` / `list_contacts_with_role("customer")`
  never match them, so they vanish from the Customers tab that replaced Clients.
- `PartyRoleHelpers.sync_roles/3` iterates `PartyRole.roles/0`, which no longer
  contains `"client"` — so the row is never revoked (no silent data loss) but
  also never has a checkbox on the company/contact form. It is unremovable
  through the UI.
- `role_label("client")` falls through to the raw-value clause and
  `role_badge_class/1` to `badge-ghost`: the party renders a grey `client`
  badge that no filter, form or query acknowledges.

**Fixed** by adding the missing data migration:
`PartyRoles.rename_legacy_client_roles/0` (+ `count_legacy_client_roles/0`) and
a `mix phoenix_kit_crm.rename_client_role` task wrapping it, dry-run by
default, following the existing
`phoenix_kit_crm.import_suppliers_from_catalogue` task's conventions. Rows for
a party that *already* holds `customer` are deleted rather than renamed — the
`(roleable_type, roleable_uuid, role)` unique index forbids the duplicate and
the newer row is authoritative. Both steps run in one transaction and the whole
thing is idempotent.

Deliberately **not** done: a permanent read-side shim treating `"client"` as an
alias of `"customer"` in the query/label paths. That would make the two spellings
co-exist forever and quietly accumulate more of them; a one-time task that the
CHANGELOG's upgrade note points at ends the ambiguity instead.

Tests: four cases in `party_roles_test.exs` covering company rows, contact
rows, the unique-index collision path, and idempotency + non-interference with
`supplier`/`partner`.

### 2. BUG - HIGH — the `crm_contact` column issues one query per row, inside `render/1`

`lib/phoenix_kit_crm/web/role_view.ex:193, 218` (pre-fix)

`render_cell(_meta, "crm_contact", u)` called `Contacts.get_by_user_uuid(u.uuid)`
— a database round-trip per table row, evaluated during render. This is worse
than a load-time N+1: `render/1` re-runs on *every* diff, so opening the column
modal, toggling card/table view, or any other unrelated event re-issues the
whole storm. The card view hits it a second time through `card_fields`. A role
with 500 users means 500 queries per interaction.

**Fixed**: `handle_params/3` now builds a `%{user_uuid => contact}` map once via
a new `Contacts.map_by_user_uuids/1` (batched sibling of `get_by_user_uuid/1`,
same malformed-uuid tolerance) and assigns it; `render_cell/4` takes the map and
does a `Map.get`. The load is skipped entirely when the column isn't selected.
Tests added for `map_by_user_uuids/1` in `contacts_test.exs`.

### 3. BUG - MEDIUM — `relative z-10` on the `crm_contact` cell can collapse the row-link overlay onto that one cell

`lib/phoenix_kit_crm/web/role_view.ex:149` (pre-fix)

`<.row_link>` paints an `::after` overlay across its nearest *positioned*
ancestor — which is meant to be the `<tr class="relative transform-gpu">`.
Making a `<td>` `relative` makes that cell the positioned ancestor instead. Cell
order here is user-configurable, so whenever `crm_contact` is the user's first
selected column, the row-link lives inside a `relative` cell and its overlay
shrinks from the whole row to that single cell — the row stops being clickable.

**Fixed** by moving `relative z-10` off the cell and onto the `<.link>` inside
`crm_contact_cell/1`. That still lifts the interactive link above the `z-0`
overlay (the `<tr>` sets `position: relative` without a `z-index`, so it creates
no stacking context and the two z-indices are directly comparable), while no
`<td>` is ever positioned. Comment added at the call site so the constraint
isn't reintroduced.

### 4. BUG - MEDIUM — the host order bridge is queried on every tab switch, unguarded

`lib/phoenix_kit_crm/web/contact_show_live.ex:62` (pre-fix)

`Andi.CRMBridge.orders_for_contact(contact)` ran on every `handle_params/3` —
i.e. on Overview, Files, Images, Comments and Events too, none of which display
orders. And unlike every other soft dependency in this file
(`storage_enabled?/0`, `comments_available?/0`, `StaffLink`), the call was not
rescued. The bridge is the *host's* code, outside this package's tests and
release cycle; an exception in there took down the entire contact profile, not
just the tab that needed it.

**Fixed**: `load_contact_orders/3` fetches only when the active tab is
`"orders"`, and rescues to `[]` with a `Logger.warning` on failure.

### 5. BUG - MEDIUM — the Overview "Lists" count contradicts the page it links to

`lib/phoenix_kit_crm/web/crm_live.ex:53-62` (pre-fix)

`load_counts/0` mixed scopes. Companies and Contacts went through their
contexts and so excluded trashed rows, matching their list pages — but Lists
used a bare `repo.aggregate(ContactList, :count, :uuid)`, counting archived
lists, while the Lists page opens on the Active tab. A card reading "5" landing
on a page showing 3 rows is a bug the user discovers one click later.

**Fixed**: `Lists.count_lists(status: "active")`, plus new
`Lists.count_lists/1` and `Interactions.count_interactions/0` so the LiveView
goes through contexts rather than reaching for `RepoHelper.repo()` and schema
modules directly (which is also what tripped the credo failure in finding 7).
Test added in `lists_test.exs`.

### 6. IMPROVEMENT - HIGH — the landing page hardcodes a host application's mix task

`lib/phoenix_kit_crm/web/crm_live.ex:128` (pre-fix)

The empty-state card printed `mix andi.crm_backfill_clients` to every consumer
of this package. The moduledoc immediately above it argues — correctly — that
CRM must not reach into the host's order tables, and that this is why the
backfill lives in the host. Printing the host's command name is the same
boundary violation wearing a different hat: in any consumer that isn't Andi,
the page names a task that does not exist.

**Fixed**: the card now offers this package's own next steps (a **New contact**
link and an **Import into a list** link). A host that ships an importer is the
right place to document it.

### 7. IMPROVEMENT - HIGH — the merged tree failed the repo's own gate, twice

`mix quality.ci` on `a09dae9` fails credo `--strict`:

```
[R] The alias `` is not alphabetically ordered among its group.
    lib/phoenix_kit_crm/web/crm_live.ex:23
```

`alias PhoenixKit.RepoHelper` was appended after the `PhoenixKitCRM.*` aliases.

That failure **masked a second one**: `quality.ci` is an alias, so a non-zero
credo halts it before dialyzer ever runs. Running dialyzer directly on the
merged tree (verified by stashing this review's changes) gives:

```
lib/phoenix_kit_crm/web/contact_show_live.ex:63:49:unknown_function
Function Andi.CRMBridge.orders_for_contact/1 does not exist.
```

AGENTS.md names `mix precommit` / `mix quality.ci` as the release bar, so both
should have blocked the merge.

**Fixed**: the credo issue is gone as a side effect of finding 5's move to
context functions. The dialyzer warning is correct-but-intended — Andi depends
on CRM, never the reverse, so the module genuinely is not in this package's
PLT — and is now silenced by a scoped `.dialyzer_ignore.exs` entry documented
alongside the two existing ones, the Dialyzer counterpart to the
`@compile {:no_warn_undefined, Andi.CRMBridge}` the PR already added for the
compiler. The gate is green on the current tree.

### 8. NITPICK — `Compare` renders after `Organizations` despite being declared before it

`lib/phoenix_kit_crm.ex:132`

The new tab was inserted directly after Lists in source (where it belongs —
Compare operates on contact lists) but given `priority: 656` against
Organizations' `655`, so the sidebar sorts it last. **Fixed** by swapping the
two priorities, with a comment noting that priority, not source order, is what
the sidebar sorts on.

### 9. NITPICK — the `max-w` sweep missed the settings page

`lib/phoenix_kit_crm/web/settings_live.ex:62`

Every other page wrapper lost `mx-auto max-w-*`; `SettingsLive` kept
`mx-auto max-w-3xl` and was the only remaining occurrence in `lib/`. **Fixed**
for consistency with the rest of the sweep.

### 10. NITPICK — `crm_contact` had no test tying it to `RoleView`'s render clauses

`ColumnConfig`'s `@role_standard` and `RoleView`'s `render_cell/4` clauses are
two lists that must stay in sync, and `render_cell`'s catch-all renders `"—"`,
so a column added on one side and forgotten on the other fails silently rather
than loudly. **Fixed** by asserting `"crm_contact" in ids` in
`column_config_test.exs`, with a comment naming the coupling.

## Not changed (on record)

- **`priv/gettext` is 305/378 untranslated in all three locales.** That is the
  pre-existing state of the catalogues, not something this PR introduced; the
  two strings this review adds are extracted and merged but left untranslated
  like the rest.
- **The `Andi.CRMBridge` order struct contract is unvalidated.** The Orders tab
  reads `order.path`, `order.number` and `order.inserted_at` off whatever the
  bridge returns, and `function_exported?/3` only checks the arity. Normalising
  each row defensively would add a schema this package would then have to keep
  in step with the host's — the rescue added in finding 4 already contains the
  blast radius to the tab, which is the proportionate guard.
- **No LiveView test covers the Orders tab's "available" branch.** `Andi` is
  not (and must not become) a dependency of this package, so the suite can only
  exercise the unavailable branch — which the PR's own two new tests do. This
  limitation is inherited, not introduced.

## Test status

The repo gate (`mix format --check-formatted`, `mix credo --strict`,
`mix dialyzer`) passes. `mix test` runs the unit suite green, but **no
PostgreSQL is available in this environment**, so the 128 `:integration`-tagged
tests — including the nine cases added by this review — auto-excluded and have
not been executed. They need a run against a real database
(`PHOENIX_KIT_PATH=../phoenix_kit mix test`) before this is considered
verified.
