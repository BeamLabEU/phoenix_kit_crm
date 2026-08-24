# Follow-up Items for PR #27

Triaged 2026-08-24 against `main` (`a471c99`). Reviewers: Codex (`CODEX_REVIEW.md`), Gemini (`GEMINI_REVIEW.md`), four Claude triage passes (`CLAUDE_REVIEW.md`). Every finding was re-verified in the code before being acted on; the ones that did not hold are listed under "Not defects on verification".

## Fixed (Batch 1 — 2026-08-24, commit a471c99)

- ~~Catalogue topic subscribed on core's internal PubSub while the catalogue broadcasts on the host server~~ — `PubSub.subscribe_host/1` / `unsubscribe_host/1` (`lib/phoenix_kit_crm/pub_sub.ex`) go through `PhoenixKit.PubSubHelper`; `company_show_live.ex` uses them. Test: "the catalogue topic is followed on the HOST PubSub" subscribes the same way and broadcasts through `PubSubHelper` (`config/test.exs` sets `:phoenix_kit, :pubsub` to the test server).
- ~~Subscribe after the initial reads~~ — `subscribe_live/3` now runs before `assign_catalogue` / `list_memberships`; `sync_member_subscriptions/1` runs once the roster is assigned (`company_show_live.ex` `handle_params`).
- ~~Catalogue subscription reconciled only when the company changes~~ (Codex) — `sync_catalogue_subscription/2` runs on every request: subscribes when the module became available, unsubscribes when it went away.
- ~~Catalogue tab ignores `:supplier` / `:manufacturer` / `:links`~~ — added to the `handle_info` guard.
- ~~`delete_contact/1` and `set_primary_company/4` snapshot the companies to notify before their transactions~~ (Codex) — `locked_company_uuids_for/1` reads them inside the transaction under `FOR UPDATE` on the contact (an FK insert of a membership waits on it); both return the companies from the transaction for the post-commit broadcast.
- ~~Literal settings path~~ — `Paths.settings/0` in `settings_live.ex`.
- ~~Unused, unencoded `Paths.contact_tab/2`~~ — removed.
- ~~No tests for restore / delete / clear-primary announcements~~ — `contacts_mirror_test.exs` "company pages hear every roster change" (3 tests).

## Not defects on verification

- Gemini #1 (`and` with a binary right operand): `true and x` returns `x`; no `ArgumentError`.
- Gemini #2 (`assigns.catalogue_enabled` missing): assigned at `company_show_live.ex:78`.
- Gemini #3 / #4 (Interactions / Files stale after a tab switch): the components render inside `:if={@tab == …}` and mount fresh on each switch.

## Open — for Max to decide

- **Codex: `comparison_live.ex` reopen refreshes the rows but not `duplicate_groups`** (count badge and group list age). A first attempt — re-query the groups in the expand branch — made the existing reopen test fail (the reopened group's rows disappeared), so it was reverted rather than guessed at. Fix now (needs a look at how the group key and the expanded key relate), or leave?
- **Codex: `contacts_mirror_test.exs` post-commit assertion is in the same process** — an in-transaction broadcast would still pass. A real check needs a separate subscriber that reads the committed row on receipt, which the shared sandbox connection makes awkward. Worth the harness work?
- **Codex: `settings_live_test.exs` asserts only the redirect string**; the destination is not mounted by the test router. Mount the production-shaped settings route in the test router?
- **Test gaps still open**: unsubscribe-on-company-switch (no observable difference through PubSub in one process) and the catalogue-enabled refresh branch (the catalogue module is absent in this repo's test env — `:requires_catalogue`). The host-server subscription itself is pinned.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_crm/pub_sub.ex` | `subscribe_host/1`, `unsubscribe_host/1` |
| `lib/phoenix_kit_crm/web/company_show_live.ex` | subscribe first; `subscribe_company/2`, `sync_catalogue_subscription/2`; extra kinds |
| `lib/phoenix_kit_crm/contacts.ex` | `locked_company_uuids_for/1`; companies read inside the delete / set-primary transactions |
| `lib/phoenix_kit_crm/web/settings_live.ex` | `Paths.settings/0` |
| `lib/phoenix_kit_crm/paths.ex` | `contact_tab/2` removed |
| `config/test.exs` | `:phoenix_kit, :pubsub` → test server |
| `test/phoenix_kit_crm/web/company_show_live_test.exs` | host-server subscription test |
| `test/phoenix_kit_crm/contacts_mirror_test.exs` | roster announcement tests |

## Verification

`mix precommit` green (compile with warnings-as-errors, format, credo --strict, dialyzer); `mix test`: 662 tests, 0 failures. `mix deps.get` must run before the suite in this repo (the committed lock is older than the resolved swoosh); `mix.lock` is restored before committing.

## Open

See "Open — for Max to decide" above.
