# PR #15 review — Tolerate a concurrently-deleted list during delete_contact's recount

**Author:** timujinne
**Branch:** fix/contact-delete-counters-hardening
**Files:** `lib/phoenix_kit_crm/contacts.ex`, `lib/phoenix_kit_crm/lists.ex`, `test/phoenix_kit_crm/contact_delete_counters_test.exs`

## Summary

Follow-up to PR #14. That review flagged an accepted, narrower residual
race: even with the snapshot moved inside the transaction, a list could
still vanish between `recount_by_uuid/1`'s `repo().get/2` and
`Lists.recount_list/1`'s own `UPDATE` — a genuine intra-transaction TOCTOU
that would previously raise (`{1, _} = repo().update_all(...)` pattern-match
failure) and roll back the entire contact deletion over a moot counter on
an already-gone list.

This PR closes that gap:

- `Lists.recount_list/1` now returns `ContactList.t() | :missing` instead
  of unconditionally `ContactList.t()`. The `:missing` case skips the
  `:list_recounted` PubSub broadcast (nothing to broadcast about).
- `defp set_counter/2` branches explicitly on the `update_all` matched-row
  count (`{1, _}` vs `{0, _}`) instead of asserting `{1, _} = ...`.
- `Contacts.recount_by_uuid/1` (private) treats both `:missing` and a
  successful recount as `:ok` — either way there's nothing further to do
  for that list.

Verified the change is contained: `Lists.recount_list/1` has exactly one
other caller in the whole codebase (`Contacts.recount_by_uuid/1` — grepped
`lib/` and `test/`), so widening its return type doesn't leave any other
call site pattern-matching on a bare `%ContactList{}` and now crashing on
`:missing`. The pre-existing test (`lists_test.exs:495`, "recount_list/1
repairs a drifted counter") still binds the result and reads
`.subscriber_count` directly, which only matches the non-`:missing`
struct branch, so it's unaffected.

Three new tests:

1. `Repo.delete!(contact)` directly (bypassing `delete_contact/1`) to make
   the subsequent `repo().delete(contact)` inside `delete_contact/1` hit a
   stale struct and raise `Ecto.StaleEntryError` deterministically —
   confirms the transaction still rolls back cleanly (counter unchanged)
   on any failure, not just the new code path.
2. `recount_list/1` on a list whose row was deleted out from under the
   struct returns `:missing` rather than raising.
3. A `list_members` FK-drop-then-restore trick (rolled back with the rest
   of the sandboxed transaction, never touching the real schema) to let a
   `ListMember` row outlive the `ContactList` it references, reproducing
   the `nil ->` branch in `recount_by_uuid/1` deterministically — confirms
   `delete_contact/1` still succeeds when a subscribed list is gone by the
   time the snapshot is recounted.

Checked the raw SQL in test 3 against the actual migration
(`phoenix_kit/lib/phoenix_kit/migrations/postgres/v152.ex:261`): the FK is
declared inline (`REFERENCES ... ON DELETE CASCADE`, no explicit
`CONSTRAINT` name), so Postgres's auto-generated name is
`phoenix_kit_crm_list_members_list_uuid_fkey` — matches what the test
drops. Also confirmed `Repo` is in scope via `PhoenixKitCRM.DataCase`'s
`using` block (aliased there, not redundantly re-aliased in the test
file).

## Findings

None. Read `contacts.ex`/`lists.ex` in full against the PR #14 review's
open item, cross-checked the sole other call site of `recount_list/1`,
and traced each new test's setup against the actual FK/cascade shape in
the core migration — all consistent, no gaps.

## Not changed

- `recount_list/1`'s return type widening (`ContactList.t()` →
  `ContactList.t() | :missing`) is a public-API breaking change in
  principle, but the module is pre-1.0 (`0.3.1`) and the new variant is
  documented in the `@doc`/`@spec`, so no deprecation shim was warranted.

## Gate

`mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix credo --strict`, and `mix dialyzer` all pass clean (0 issues,
4 dialyzer errors are pre-existing/skipped as before, `mix dialyzer` exits
0). No local Postgres in this environment (same limitation as the #14
review) — `mix test` ran 94 tests, 0 failures, 324 excluded
(`:integration`-tagged DB tests auto-exclude per the documented
DB-absent behavior). This PR's new tests were read line-by-line against
the real `Lists`/`Contacts`/migration behavior instead of executed; rerun
with `PHOENIX_KIT_PATH=../phoenix_kit mix test` against a real Postgres
before relying on this alone.
