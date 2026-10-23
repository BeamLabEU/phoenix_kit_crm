# Claude review — PR #30 "Clone scratch DB via pg_dump|psql instead of CREATE DATABASE TEMPLATE" (2026-10-23)

Merged as `b66c42c` (author timujinne). Read: `SchemaOwnerGuardWiringTest`
`clone_from_template!/3`, the new `LiveDatabaseGuard` (+ unit and wiring tests),
and the `test_helper.exs` call. Test-only change. (The #43 review listed this
as "nothing to review"; this is the actual read.)

## Findings

- **NITPICK: the live-database guard hard-codes one contributor's container.** `LiveDatabaseGuard` names `decor_3d_print_dev` and `phoenixkit_hello_world_dev` and cites `/root/bin/pk-test`, an external script that does not exist for anyone else. The guard itself is harmless (an exact-name refusal) and the moduledoc explains why it exists, but those names and the path are one machine's identifiers in a public repo — the kind of thing #35 scrubbed from the docs. A shorter list (`phoenix_kit_dev`) read from config, or a generic `*_dev` suffix rule, would carry the same protection without it. Left: it changes what the maintainers' own environment is protected from.
- **NITPICK: the wiring test boots a nested `mix test` against the shared test database** while the parent suite is running on it. It has not been seen to break the suite, but is the one test in the repo whose pass/fail depends on a second BEAM touching the same DB; if it ever flakes, look there first.
- **NITPICK: `{"PGPASSWORD", admin_opts[:password]}` passes `nil` when no password is configured**, which `System.cmd/3` interprets as *unset the variable*. That is the right outcome here (and correct for trust auth), just not obvious.

## Checked, clean

- **The pipeline-exit-status trap is handled.** `pg_dump` and `psql` are two `System.cmd/3` calls, each matched on `{_, 0}`, with `ON_ERROR_STOP=1` on the restore — a dump that dies mid-stream fails the test instead of yielding a green run on an incomplete clone. The dump file is removed in `on_exit`.
- **Why not `TEMPLATE`:** the running suite's own pool holds sessions on the template database, so `CREATE DATABASE … TEMPLATE` refuses; stopping the repo broke concurrent async modules. The dump route needs no exclusivity. Correct diagnosis.
- **`LiveDatabaseGuard.check!/1` matches on the exact name** (the "merely contains" test pins this), and runs before any connection attempt.
