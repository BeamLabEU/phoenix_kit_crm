# PR #41: Describe the CRM comparison screen in English

**Author**: @timujinne (merge `d031242`, 2 commits)
**Reviewer**: Claude, single pass. Read the diff, the full `ComparisonLive` moduledoc, and scanned `lib/`, `test/`, `mix.exs` and `README.md` for leftover Cyrillic. Ran `mix precommit` and `mix test` against a live Postgres.
**Date**: 2026-09-28
**URL**: https://github.com/BeamLabEU/phoenix_kit_crm/pull/41

## Context

One line in `lib/phoenix_kit_crm/web/comparison_live.ex`: the moduledoc's
Cyrillic gloss ("сличение") is removed. Round 1 then dropped the
"(reconciliation)" English stand-in too, because the screen reconciles nothing:
it is two read-only reports, and the rest of the moduledoc and the page
subtitle ("Read-only reports — nothing here changes any data.") already say so.

What checks out:

- No Cyrillic remains in `lib/`. What is left in `test/` is `ru` translation
  data (`i18n_test.exs`, the empty-state tests), which is correct and must stay.
- Documentation only: no code, gettext msgid or behaviour changes.

## Findings

### NITPICK — commit message of `d93afa1` describes more than the diff

The message says the commit renames Cyrillic spec labels and makes Russian
catalogue import/export labels English. Its diff is the single moduledoc line
above. The text looks carried over from the same sweep in a sibling repo. It is
harmless, but `git log` on this repo claims changes it does not contain.
Not rewritten: the history is merged and pushed.

## Unrelated to the PR

`test/schema_owner_guard_wiring_test.exs` (2 tests) fails in this environment.
Its setup clones the template DB via `pg_dump` | `psql`. The restore stops on
`COMMENT ON EXTENSION citext` ("must be owner of extension citext") because the
shared test DB's extensions are owned by `postgres` and the test role is not a
superuser. The other 813 tests pass. Not changed here: it is a test-harness
issue, not something this PR touched.

## Verdict

Merge is fine. No code fixes needed.
