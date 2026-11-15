# Release 0.20.0 — Follow-up

Triaged 2026-11-15 against `main` (`3c5bdc7`). Reviewer: Grok (`GROK_REVIEW.md`).
Grok fixed every finding in `3c5bdc7`; each fix was re-read in the diff and
verified with `mix precommit` clean and `mix test` on seeds 0, 42 and 999
(1043 tests, 0 failures, 15 excluded — the same excluded count as before the
fixes, so the removed table probe neither enabled nor dropped a test).

## Fixed (commit 3c5bdc7)

- ~~#1 `test_helper.exs` probed for CRM tables after this module's chain had
  created them, and printed a `PHOENIX_KIT_PATH` hint~~ — probe, hint and the
  `crm_tables_present` env key removed (no reference left in `lib/`, `test/` or
  the docs); `:integration` and the test endpoint depend only on the database
  being reachable; the `:requires_catalogue` probe is kept. The stale
  `pk_dep/3` comment and the AGENTS.md TODO went with it.
- ~~#2 README described managed mirrors as optional and nested the section
  under License; AGENTS.md said `phoenix_kit_comments ~> 0.3`~~ — README
  section is its own heading and matches the 3.5.0 floor, install example
  `~> 0.20`; AGENTS.md and the `mix.exs` comment say `~> 0.5`;
  `ManagedMirror`'s moduledoc no longer calls the path optional.
- ~~#3 The session-stack test only asserted the button~~ — it now searches for
  the first manager, submits, and asserts the company is linked.
- ~~#4 Changelog said public pages skip the CRM's JavaScript without naming
  the core~~ — the bullet and the bundle's header comment say it is core 3.6.0
  behaviour and core 3.5 still loads the file publicly.
- ~~#5 `ColumnConfig.load_custom_fields/0` swallowed `UndefinedFunctionError`
  silently~~ — that clause is gone; any failure is logged and still returns `[]`.

## Left as they are (agreed with the review)

- Role subtab labels are primary-language and refresh on `refresh_sidebar/0`
  or restart: `Tab.label` is one string. Asked of core in
  `dev_docs/2026-11-15-brief-core-account-links-in-crm.md`.
- `Code.ensure_loaded?` / `apply/3` around staff, projects, catalogue and
  comments stay: those apps are not dependencies.
- `InteractionNotifier.fan_out/2` keeps its rescue so a notify failure cannot
  fail a save.
