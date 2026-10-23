# CRM pre-live review — 2026-10-23

Reviewed current main starting at `4f1db32`, after a successful fast-forward
check against origin. Scope: merged PRs #43–45 and their follow-ups, plus
the party-role vocabulary/forms added between #44 and #45. Prior review
documents informed the pass; their clean conclusions were rechecked against
the implementation and new failure cases.

## Results

Seven confirmed defects fixed:

| Severity | Behavior corrected | Review |
| --- | --- | --- |
| HIGH | API filters and plan ordering now precede the result limit | [#43](../pull_requests/2026/43-interactions-as-plans/CODEX_REVIEW.md) |
| HIGH | Polling cursor precedes the read, retaining racing updates | [#43](../pull_requests/2026/43-interactions-as-plans/CODEX_REVIEW.md) |
| MEDIUM | Calendar overlap is checked before capping results | [#43](../pull_requests/2026/43-interactions-as-plans/CODEX_REVIEW.md) |
| MEDIUM | Explicit blank/null status returns validation errors | [#43](../pull_requests/2026/43-interactions-as-plans/CODEX_REVIEW.md) |
| MEDIUM | Reinstated plans record planning and notify existing parties | [#43](../pull_requests/2026/43-interactions-as-plans/CODEX_REVIEW.md) |
| MEDIUM | Contact recipient lookup honors its schema prefix | [#43](../pull_requests/2026/43-interactions-as-plans/CODEX_REVIEW.md) |
| MEDIUM | Orders bridge exits no longer crash the contact profile | [#45](../pull_requests/2026/45-orders-bridge-config/CODEX_REVIEW.md) |

No additional confirmed defect in [#44 and the subsequent party-role changes](../pull_requests/2026/44-gettext-split-backend/CODEX_REVIEW.md).
Added seven regression tests, including coverage of the existing API ledger
guard with logged time and with an unreadable ledger.

## Validation

- Baseline: `mix test` — 979 tests, zero failures.
- Before fixes: four new calendar/status/reinstatement/API tests failed;
  the separate Orders timeout test also failed by terminating the LiveView.
- After the first interaction fixes: 32 focused interaction/calendar/API
  tests passed.
- Final: `mix test --seed 42` — 986 tests, zero failures.
- Final: `mix test --seed 0` — 986 tests, zero failures.
- Final: `mix precommit` — passed: warnings-as-errors compilation, unused
  dependency check, Hex advisory audit, formatting, strict Credo, and Dialyzer
  (four existing ignored warnings, no unnecessary ignores).
- `git diff --check` — passed.

## Limits

Validation uses the repository's real PostgreSQL test database and LiveView
test endpoint. The optional projects package is represented by the existing
in-memory ledger collaborator for integration failure cases. A full consumer
application and a separate build with a custom database prefix were not run.
This pass changes no migration, release version, or changelog.

The `pr-review` workflow's referenced `elixir:*` thinking skills were absent
from this environment. Review proceeded directly against source, producing
callers, dependency code, prior findings, and executable regression tests.
