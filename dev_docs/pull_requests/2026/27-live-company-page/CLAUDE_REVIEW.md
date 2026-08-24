# PR #27: Make the company page live and say on every tab what it shows

**Author**: @mdon
**Reviewers**: four Claude triage passes (security + error handling + async UX; translations + activity + tests; PubSub + cleanliness + API; host-integration boundaries), each read-only over `upstream/main..main` with every claim re-read in the current code
**Date**: 2026-08-24
**URL**: https://github.com/BeamLabEU/phoenix_kit_crm/pull/27

## Findings (verified unless marked)

1. **BUG — the catalogue topic was subscribed on the wrong PubSub server.** `company_show_live.ex` called `CRMPubSub.subscribe(@catalogue_topic)` → `PhoenixKit.PubSub.Manager` (`:phoenix_kit_internal_pubsub`), while the catalogue broadcasts through `PhoenixKit.PubSubHelper` on the host app's server. The Catalogue tab's live refresh was dead in production; the only test `send`-ed the tuple to the pid and could not see it. (All three code-lens passes found this independently.)
2. **BUG — subscriptions established after the initial reads** (`handle_params`: company → catalogue → memberships → subscribe). A write committed in that window was lost until the next event.
3. **IMPROVEMENT — Catalogue tab ignored `:supplier` / `:manufacturer` / `:links`**, the party rows and CRM-company links that decide which items count as supplied by the company.
4. **NITPICK — `settings_live.ex` used a literal `Routes.path("/admin/settings/crm")`** while `Paths.settings/0` exists.
5. **NITPICK — `Paths.contact_tab/2` had no caller** (the per-member links were dropped in `ae9dc1e`) and interpolated `tab` unencoded.
6. **TEST GAP — no test pinned the company-topic announcements for restore / delete / clear-primary**, nor the unsubscribe-on-company-switch, nor the catalogue-enabled refresh branch.
7. **Boundary trace (intact)**: `TabIntro` attrs/slots at all 12 call sites; `send_update` ids match rendered component ids; `party_items_table` contract unchanged.

## Not defects on verification (Gemini's four CRM findings)

- `Enum.find_value(companies, &(&1.uuid == uuid and uuid))` — `true and x` returns `x` in Elixir; only the left operand must be boolean. No crash.
- `socket.assigns.catalogue_enabled` "missing" — assigned in `handle_params` (`company_show_live.ex:78`).
- Interactions / Files components "stale after a tab switch" — both render inside `:if={@tab == …}`, so a tab switch mounts a fresh component that re-queries.
