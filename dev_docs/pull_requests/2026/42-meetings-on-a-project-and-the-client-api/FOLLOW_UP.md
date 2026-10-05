# Follow-up — PR #42 (2026-10-05)

How each finding in `CLAUDE_REVIEW.md` was resolved. The panel's design
sweep of the API surface (codex, grok, zai) sits with the projects PR
(`phoenix_kit_projects/dev_docs/pull_requests/2026/48-…/`), where the
findings that touched this repo were taken in the "panel's sweep" commits:
the task ↔ interaction join table replacing the token-only link, and the
interaction lookup from a task in a sub-project.

## Fixed (`d370885`)

- ~~BUG - HIGH: `tasks: [uuid]` linked any task on the site~~ — `ProjectApi.check_tasks/2` runs before any write: every uuid must be a task of the project or of a sub-project under it (`ProjectsLink.task_project/1` against `ProjectsLink.subtree_uuids/1`); one outside the reach — or that the projects module cannot find — is a 404, a non-uuid a 422. Test: a malformed list and an unknown task both answer before the row changes.
- ~~BUG - MEDIUM: `tasks: [123]` → 500~~ — the 422 above, before `link_task/3`'s guard is reached.
- ~~BUG - MEDIUM: the interaction committed before the tasks were checked~~ — checked first; a bad list writes nothing.
- ~~IMPROVEMENT - HIGH: `tasks_for_interaction/1` per row~~ — kept per row (see Skipped) but the join table makes it one indexed read per row rather than a backlink scan.
- ~~Stale comments in `project_api.ex` and `projects_link.ex` (the token-only link)~~ — corrected.
- ~~Missing `@spec` on the new public functions~~ — `task_project/1` and `subtree_uuids/1` carry one; the `ApiProvider` callbacks and `client_company_uuid/1` stay `@doc false` without, as `ProjectApi`'s existing callbacks are.

## Skipped (with rationale)

- **The CRM-side `tasks:` link writes no activity row** — the projects module's own `POST /tasks/:id/interactions/:uuid` logs; a link made through the CRM's endpoint leaves the join row and the token on the task, which the projects UI shows, but no `projects.task_linked` entry. A small follow-up once the two modules agree on whose activity stream a cross-module link belongs to.
- **`since` filters on `occurred_at` while `now` is server time** — documented on the endpoint: a backdated interaction logged after a poll is found through the list without `since`. Filtering on `updated_at` instead would change what `since` means for a poller that reads it as "happened after".
- **`tasks_for_interaction` per interaction row** — the list is capped at 200 and the projects briefing trims it to five; a batch is easy later. Left so this PR's diff stays about what it does.
- **Broad rescues on the soft cross-app calls in `ProjectsLink`** — deliberate: the projects module may be absent or older; each carries a comment.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_crm/project_api.ex` | `check_tasks/2` before any write; 422/404; stale comments |
| `lib/phoenix_kit_crm/projects_link.ex` | `task_project/1`, `subtree_uuids/1`; link through `link_interaction/4` |
| `test/phoenix_kit_crm/company_api_test.exs` | tasks checked before writing: a malformed list, an unknown task |

## Verification

`mix precommit` 0 (format, compile --warnings-as-errors, deps.unlock --check-unused, hex.audit, credo --strict, dialyzer); `mix test` 832 tests, 0 failures. Fit-tables grep clean (no new columns in this PR).

## Open

None.
