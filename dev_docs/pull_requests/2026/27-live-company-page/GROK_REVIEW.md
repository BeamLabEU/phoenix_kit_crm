# Review: Make the company page live and say on every tab what it shows

**PR:** [#27](https://github.com/BeamLabEU/phoenix_kit_crm/pull/27) (merged `38aed12`)
**Author:** mdon
**Branch:** `main`

## Summary

The company page now follows its data: a per-company topic for roster changes (`announce_to_companies/3` after commit), per-member interaction feeds kept in step with the roster, and the catalogue topic on the **host** PubSub (`PubSub.subscribe_host/1`) so the Catalogue tab actually hears the catalogue module. Tab switches drop the previous company's subscriptions. Every contact/company tab that is fed from elsewhere opens with a line saying what it lists and how something gets into it.

Same sweep: contact Files roll-up refreshes on interaction broadcasts; the role view's CRM-contact map reloads from `columns_saved/1`; settings remounts after a role toggle so the sidebar re-reads the registry; the list-members locale preview and comparison duplicate-group **rows** stay current; mirror-resolution results are written into the form instead of being reverted on Save.

Prior panel (`CLAUDE_REVIEW.md`, `CODEX_REVIEW.md`, `GEMINI_REVIEW.md`, `FOLLOW_UP.md`) already closed the production-dead catalogue subscription, subscribe-after-read, extra catalogue kinds (`:supplier` / `:manufacturer` / `:links`), and the delete / set-primary snapshot-outside-transaction races.

## Findings

### BUG - MEDIUM — comparison page refreshed rows on reopen but not the group list or count

**Where:** `lib/phoenix_kit_crm/web/comparison_live.ex` `toggle_duplicate`; `lib/phoenix_kit_crm/contacts.ex` `list_duplicate_email_groups/0`

Collapsing a duplicate group dropped its cached contacts so a re-expand re-queried the rows (the PR's claim). `duplicate_groups` — the email list and the "N contacts" badge — was still the `handle_params` snapshot. After another session changed an email, re-expanding showed fewer (or different) people under a badge that still said 2, and a pair that was no longer duplicated stayed on the page.

A first attempt in the original follow-up re-queried groups only on expand and broke the existing reopen test (rows vanished). The cause is citext: `GROUP BY email` merges `alice@x` and `ALICE@X`, but the representative string Postgres returns is whichever row it picks. Elixir `==` on that string is case-sensitive, so a re-query could flip the group key, miss `Enum.any?(groups, &(&1.email == email))`, and refuse to expand. That is why the reopen test — which creates the second contact with `String.upcase(email)` — lost its rows. Left open for Max in `FOLLOW_UP.md`.

**Fix applied:** `list_duplicate_email_groups/0` lowercases the representative email so the UI key is stable; `toggle_duplicate` re-queries groups on every toggle and lowercases the param; a group that is no longer duplicated collapses rather than showing a one-row drill-down; each collapse has `id={"crm-dup-#{group.email}"}`. Tests: existing reopen (rename) still shows the new name; a new test changes one address and asserts the group and "2 contacts" badge leave the page.

### BUG - MEDIUM — Catalogue tab ignored `:category`

**Where:** `lib/phoenix_kit_crm/web/company_show_live.ex` `handle_info/2` (`:catalogue_data_changed`)

The follow-up widened the kind whitelist to `:supplier` / `:manufacturer` / `:links` (what decides which items count as supplied by this company). It still dropped `:category`. The catalogue's own `party_items_table/1` defaults include a category column, and `items_supplied_by/1` preloads `:category` — renaming a category left the company Catalogue tab showing the old name until some other kind fired.

Verified against `PhoenixKitCatalogue.Catalogue.PubSub`'s `kind` type and `party_items_default_columns/0`. Folders / PDFs / attribute sets still ignored: they are not columns of that table.

**Fix applied:** `:category` added to the guard.

### IMPROVEMENT - MEDIUM — member interaction feeds subscribed after the other page reads

**Where:** `lib/phoenix_kit_crm/web/company_show_live.ex` `handle_params/3`

The follow-up moved `subscribe_live/3` (company topic + catalogue) before the initial reads. `sync_member_subscriptions/1` still ran last, after catalogue items, avatar, timezone, and the mirror user. A member's interaction committed in that window was lost until the next event — the same class of gap, on the feeds the Interactions rollup actually listens to.

`sync_member_subscriptions/1` also ran on the disconnected HTTP mount (the company/catalogue subscribe is `connected?/1`-guarded). Harmless (that process dies) but inconsistent.

**Fix applied:** roster is the first read after subscribe; member feeds are synced immediately; `sync_member_subscriptions/1` is a no-op until connected.

### NITPICK — two new tab-intro strings left `fuzzy` in et/ru

Gettext's compiler still ships fuzzy msgstrs, so et/ru operators already saw the translated lines. The flag is leftover from `msgmerge` matching similar older strings. Cleared; the translations themselves were already correct.

## Not defects (re-verified)

- Gemini #1 (`true and uuid`): `and` requires a boolean **left** operand; `Enum.find_value(..., &(&1.uuid == uuid and uuid))` returns the uuid or nil. No crash.
- Gemini #2 (`assigns.catalogue_enabled` missing): assigned in `handle_params` before any catalogue `handle_info`.
- Gemini #3 / #4 (Interactions / Files stale after a tab switch): both LiveComponents render inside `:if={@tab == …}` and are destroyed when the tab is left; switching back mounts a fresh component that re-queries. `loaded_token == nil` only applies while the component stays in the tree.
- Codex: post-commit assertion in the same process — true, an in-transaction broadcast would still pass this test. A separate subscriber that reads the committed row needs sandbox sharing the test did not have. Left as a test-quality gap; the production path broadcasts after `repo().transaction` returns.
- Codex: settings test asserts only the redirect string — the test router mounts settings at `/en/admin/crm/settings` while `Paths.settings/0` is `/admin/settings/crm`, so LiveViewTest cannot follow the remount without a production-shaped layout. The handler does `push_navigate(to: Paths.settings())`; the sidebar is core's layout, not this package's test layout. Not fixable here without standing up the dashboard.
- Company Events tab `send_update` on a member's interaction is a wasted query (`resource_type` is `crm_company`, interaction activity is `crm_contact`). Harmless.

## Files touched (this review)

| File | Change |
|------|--------|
| `lib/phoenix_kit_crm/web/comparison_live.ex` | Re-query groups on toggle; stable collapse id |
| `lib/phoenix_kit_crm/web/company_show_live.ex` | `:category` kind; roster+member feeds before other reads; connected? on member subs |
| `test/phoenix_kit_crm/web/comparison_live_test.exs` | Group disappears when it is no longer a duplicate |
| `priv/gettext/{et,ru}/LC_MESSAGES/default.po` | Drop stale `fuzzy` on two reviewed strings |
