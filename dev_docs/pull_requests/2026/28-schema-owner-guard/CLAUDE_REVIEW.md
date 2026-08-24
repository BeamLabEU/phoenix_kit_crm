# PR #28: I067 — SchemaOwnerGuard — refuse a PGDATABASE-override collision instead of silently colliding

**Author**: @timujinne
**Reviewer**: Claude, single pass — full diff read line-by-line, plus real execution of the project's gate (`mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`) and `mix test` against a local `phoenix_kit` core checkout and a live Postgres instance
**Date**: 2026-08-24
**URL**: https://github.com/BeamLabEU/phoenix_kit_crm/pull/28

## Context

Test-only infrastructure (`test/support/schema_owner_guard.ex`, wired into `test/test_helper.exs`): when `PGDATABASE` is pointed at a shared Postgres database (e.g. a workspace-wide `migration_test_db`), `Ecto.Migrator`'s `schema_migrations` bookkeeping table is keyed only by version number with no package namespace, so another package's already-applied migration version can silently mask this package's migration of the same number. `SchemaOwnerGuard` stamps a `COMMENT ON TABLE schema_migrations` marker naming the owning package after a successful boot, and refuses (`OwnerMismatch`) if a future boot finds a marker naming someone else. Only engages when `PGDATABASE` is explicitly set — the default, isolated per-repo test DB is unaffected.

The PR's own commit history (7 commits) and in-code comments show it already went through several rounds of adversarial review (referenced as "Kimi" and "Pi" in comments) before merge, closing gaps like: unit tests calling `check!`/`stamp!` directly instead of through the real `test_helper.exs` boot path, an enumerative field-list snapshot replaced with a full `pg_dump --schema-only` diff, and fixture blind spots where a templated scratch DB already carried the marker/extension/function/migrator-row being tested.

## Findings

1. **IMPROVEMENT — MEDIUM (fixed).** `test/schema_owner_guard_wiring_test.exs:217` called `PhoenixKitCRM.Test.SchemaMigration.migrator_version()` as a fully-qualified nested reference instead of aliasing the module. `mix credo --strict` — part of this repo's documented `mix precommit`/`mix quality` gate (AGENTS.md) — flags this as a Software Design suggestion and exits non-zero on it, so the gate was red as merged. Fixed by adding `alias PhoenixKitCRM.Test.SchemaMigration` and using the short name at the call site; `mix credo --strict` now exits 0 with "found no issues".

2. **Verified — no logic defects found in `SchemaOwnerGuard` itself.** `check!/1` is a true no-op unless `PGDATABASE` is set; treats "table absent" and "table present but unmarked" both as `:ok` (documented, intentional — an isolated/fresh DB is never refused); raises `OwnerMismatch` only when a marker naming a *different* package is found; the message names the actual foreign owner. `stamp!/1` only writes when `PGDATABASE` is set. The `test_helper.exs` wiring calls `check!/1` before any DDL/migration runs and `stamp!/1` only after migrations succeed, then explicitly reraises `OwnerMismatch` (rather than swallowing it into the generic "could not connect" path) so a real boot crashes loudly and visibly.

3. **Minor/theoretical — not fixed (over-engineering for this use case).** `owner/1`'s existence check (`SELECT EXISTS (... information_schema.tables WHERE table_name = 'schema_migrations')`) is not schema-qualified, while the immediately following `'schema_migrations'::regclass` lookup resolves through `search_path`. In a hypothetical multi-schema database where `schema_migrations` exists only in a schema outside the default search path, the `EXISTS` check would report `true` but the `::regclass` cast would then raise `undefined table` instead of being treated as "no table". This guard is test-only tooling for a single-schema test database (the CRM's own migration chain always runs `prefix: "public"`), so this doesn't reflect a real usage path today — noting it for the record rather than changing it.

4. **Execution/verification limits of this review.** The two new test files (`schema_owner_guard_test.exs`, `schema_owner_guard_wiring_test.exs`) create/drop scratch databases via an admin connection to the `postgres` maintenance database, which requires `CREATEDB`/superuser-equivalent Postgres privileges. This sandbox's Postgres role (`beamlab_test`) has neither `CREATEDB` nor `CONNECT` on the `postgres` database, so those 7 tests fail here with `insufficient_privilege` / connection-pool-timeout errors — an environment limitation, not a defect in the PR. Every other test in the suite (663/670) passes against a real, local `phoenix_kit` core checkout and a live Postgres instance. `mix compile --warnings-as-errors`, `mix format --check-formatted`, and `mix dialyzer` are all clean.

## Not defects (considered and ruled out)

- **First-run race / bootstrapping gap**: the very first boot against a fresh, unmarked DB always passes `check!` (marker absent), even if that DB secretly belongs to another package that never stamps its own marker. This is an inherent, acknowledged limitation of a "mark on success" scheme (matches the `phoenix_kit_document_creator` precedent this PR follows), not a bug — the guard protects against a *previously-owned-and-marked* DB being repurposed, not an unmarked collision on the very first run.
- **SQL construction in `stamp!/1`** (`"COMMENT ON TABLE schema_migrations IS '#{@package}'"`) interpolates `@package`, a fixed module attribute (`"phoenix_kit_crm"`), never user input — no injection risk.

## Gate status after fix

```
mix compile --warnings-as-errors   clean
mix format --check-formatted       clean
mix credo --strict                 clean (0 issues, was 1 before fix)
mix dialyzer                       clean (passed successfully)
mix test (local core, live PG)     663 passed, 7 failed — all 7 are the new
                                    scratch-DB tests, blocked by this sandbox's
                                    lack of Postgres CREATEDB privilege
```
