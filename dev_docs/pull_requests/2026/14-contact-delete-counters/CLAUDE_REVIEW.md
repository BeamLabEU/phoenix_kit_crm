# PR #14 review — Fix delete_contact permanently overcounting list subscriber_count

**Author:** timujinne
**Branch:** fix/contact-delete-counters
**Files:** `lib/phoenix_kit_crm/contacts.ex`, `test/phoenix_kit_crm/contact_delete_counters_test.exs`

## Summary

`Contacts.delete_contact/1` hard-deletes a contact. The FK on
`phoenix_kit_crm_list_members.contact_uuid` is `ON DELETE CASCADE`
(confirmed in `phoenix_kit/lib/phoenix_kit/migrations/postgres/v152.ex:262`),
so deleting a contact silently removes its `ListMember` rows at the DB
level — bypassing `Lists.remove_from_list/2`'s atomic
`subscriber_count` decrement, which only fires on a live status flip.
A contact deleted while still `"subscribed"` on a list left that
list's `subscriber_count` permanently stuck one too high, since
nothing else ever revisits it.

The fix snapshots which lists the contact was `"subscribed"` on,
hard-deletes the contact, then calls `Lists.recount_list/1` (the same
repair function backing the Settings-page "Recount" action) for each
affected list, all inside one transaction. Verified `Lists.recount_list/1`
does a genuine `COUNT` from current DB state rather than a delta, so it's
self-correcting regardless of what the stale count was.

Four new tests cover: single subscribed list, mixed subscribed/removed
lists, multiple subscribed lists, and a no-op soft-delete case
(`trash_contact/1` must not touch counters at all). All read correctly
against the actual `Lists`/`ListMember` behavior — no fabricated
assertions.

## Findings

### IMPROVEMENT - MEDIUM — snapshot query ran outside the transaction

`affected_list_uuids` was queried *before* `repo().transaction/1` was
called. That leaves a window between the snapshot and the delete where a
concurrent `Lists.add_contact_to_list/3` could subscribe the contact to a
new list the snapshot never saw — `bump_counter/2` fires (+1), the
transaction then deletes the contact and cascades that brand-new
membership row away, and nothing ever recounts that list. It's the same
class of permanent drift this PR exists to fix, just reached through a
narrower door (a subscribe landing in the gap between the SELECT and the
transaction's BEGIN, rather than every delete).

**Fix applied:** moved the `affected_list_uuids` query inside
`repo().transaction/1`, immediately before `repo().delete(contact)`,
closing the pre-transaction window. (Note: this narrows rather than
fully eliminates the race — Postgres's default READ COMMITTED isolation
means a concurrent commit landing between the snapshot statement and the
delete statement, both within the transaction, is still theoretically
possible. Given `Lists.recount_list/1` is already the documented,
idempotent repair path for exactly this kind of drift, and the remaining
window is now a single intra-transaction statement gap instead of an
unbounded pre-transaction one, a `SELECT ... FOR UPDATE`/serializable
approach wasn't worth the added complexity here.)

## Not changed

- N+1 shape of `Enum.each(affected_list_uuids, &recount_by_uuid/1)` (one
  `get` + one aggregate query per affected list): contacts belonging to
  many lists at once are the exception, not the norm, for this module —
  not worth batching.
- No `Activity.log` call added to `delete_contact/1` itself — the
  pre-existing behavior (activity logging happens at the LiveView call
  site, `web/contacts_live.ex:91-99`), unchanged by this PR.

## Gate

`mix format`, `mix compile --warnings-as-errors`, `mix credo --strict`,
and `mix dialyzer` all pass. No local Postgres was available in this
review environment, so the DB-backed tests (including this PR's new
`contact_delete_counters_test.exs`, which uses `PhoenixKitCRM.DataCase`
and is `:integration`-tagged) auto-excluded per the documented
DB-absent behavior — `0 tests, 0 failures (5 excluded)` — rather than
actually running. They were read line-by-line against the real
`Lists`/`ListMember` behavior instead (see Summary above) and were not
otherwise modified. Re-run with `PHOENIX_KIT_PATH=../phoenix_kit mix
test` against a real Postgres before merging if that assurance matters
more than the code read.
