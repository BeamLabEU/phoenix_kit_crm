# PR #16 review — Fix rare full-suite deadlock: ALTER TABLE DDL under async: true

**Author:** timujinne
**Branch:** flaky-suite-deadlock-investigation
**Files:** `test/phoenix_kit_crm/contact_delete_counters_test.exs` (test-only, one line + comment)

## Summary

`contact_delete_counters_test.exs`'s "a list gone by the time recount_by_uuid
checks it doesn't crash the delete" test runs a real
`ALTER TABLE ... DROP CONSTRAINT` inside its sandboxed transaction (a
deliberate choice, predating this PR, to reproduce a TOCTOU gap
deterministically instead of chasing a genuine two-connection race). DDL
takes a table-level `ACCESS EXCLUSIVE` lock on `phoenix_kit_crm_list_members`
for the rest of that transaction — i.e. until the sandbox rolls it back at
test end — while three other `async: true` files (`companies_test.exs`,
`lists_test.exs`, `lists/import_test.exs`) read/write that same table
concurrently. If one of those files' connections already held a row lock
from its own insert/update when the DDL's `ACCESS EXCLUSIVE` request queued
behind it, and that connection then needed another lock the DDL transaction
was blocking, Postgres detects the two-process wait cycle and kills one side
with `40P01 deadlock_detected`. The PR's own commit message documents
reproducing this live (`mix test --repeat-until-failure 30`, hit on the
first rep, seed 763135) — the rare "1 failure in 8 full-suite runs" flake.

Fix: mark this one file `async: false`, with a comment explaining why (so it
doesn't read as an accidental omission, and isn't used as precedent for
adding DDL to other async files). A follow-up commit in the same PR
(741252c) corrected a lock-level misstatement in that comment (row lock vs.
`ACCESS SHARE`, which is a table-level mode) — the final wording is accurate.

## Verification

- Confirmed `ExUnit.Runner`'s scheduling (`async_loop/4` in the installed
  Elixir's `ex_unit/lib/ex_unit/runner.ex`): `async: true` modules run
  concurrently first; `async: false` (sync) modules are only pulled from the
  queue and started after *all* async modules have finished, and are then
  run strictly one at a time. So `async: false` here doesn't just reduce the
  odds of the race — it makes the race impossible, since this file's DDL
  transaction can no longer overlap with any other test file's transaction.
- Grepped the three files named in the comment: all three are indeed
  `use PhoenixKitCRM.DataCase, async: true` and reference `ListMember` /
  the list-members table.
- Grepped the whole `test/` tree for other DDL statements
  (`ALTER TABLE`/`CREATE INDEX`/`DROP TABLE`) under `async: true` — none
  found. This is the only file that needed the fix.
- Re-read the DDL test itself: it drops and never restores the FK
  constraint, but the drop happens inside the sandboxed transaction, which
  the sandbox always rolls back at test end — the real schema is untouched
  regardless of `async` value, so the `async: false` switch doesn't change
  that part of the test's safety.
- Checked `test/support/data_case.ex`: `Sandbox.start_owner!(TestRepo,
  shared: not tags[:async])` — `async: false` flips this test to a shared
  sandbox connection, the normal/expected mode for non-async DB tests; no
  interaction with the deadlock fix.

## Findings

None. The diagnosis matches Postgres's documented DDL-lock-queueing
behavior, the claimed concurrent files were verified to actually touch the
contended table, and the fix (verified against ExUnit's actual scheduler)
fully — not just probabilistically — eliminates the overlap that caused it.

## Not changed

- The whole file is now `async: false`, serializing all 6 tests in it even
  though only 1 of the 6 needs the DDL. Splitting the DDL test into its own
  file would let the other 5 stay `async: true`. Left as-is: the suite-wide
  slowdown from one more serial file is negligible, and the PR's comment is
  explicit about keeping this contained to a single file rather than
  establishing a pattern — not worth the extra file for the marginal speed
  gain.

## Gate

`mix precommit` itself failed at the `deps.unlock --check-unused` step
(stale `beamlab_ex_aws_sqs` lock entry from the unrelated `55fc25d lib
upgrades` commit, already on `main` before this review, not touched by
PR #16) — out of scope for this PR, not fixed here. Ran the rest of the
gate directly instead:

- `mix format --check-formatted` — clean
- `mix compile --warnings-as-errors` — clean
- `mix credo --strict` — 0 issues (1159 mods/funs)
- `mix dialyzer` — 4 errors, all pre-existing and skipped via
  `.dialyzer_ignore.exs` (same as prior reviews); exits 0
- `mix test` — 94 tests, 0 failures, 324 excluded. No local Postgres in
  this environment, so the `:integration`-tagged DB tests (including this
  PR's own file) auto-exclude; the fix was verified by reading against
  Postgres's actual DDL-lock semantics and ExUnit's actual scheduler
  source instead of by executing the reproduction. Rerun
  `PHOENIX_KIT_PATH=../phoenix_kit mix test --repeat-until-failure 30`
  against a real Postgres before relying on this alone, per the PR's own
  repro instructions.
