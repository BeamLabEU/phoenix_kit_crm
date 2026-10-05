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

# Post-merge pass (2026-10-05)

How each finding in the second section of `CLAUDE_REVIEW.md` and in
`CODEX_REVIEW.md` was resolved. Codex could not run a shell in this
container (its sandbox needs user namespaces the kernel denies), so it
reviewed the PR's `lib/` + `test/` diff piped to it, with `AGENTS.md`; every
claim of its below was checked against the code here before being acted on.

## Fixed

- ~~BUG - HIGH: `can_write` enforced only by the template~~ (Codex #1 too) — `InteractionsComponent.handle_event/3` refuses `save_interaction`, `delete_interaction`, `edit_interaction`, `log_planned`, `start_planning` and `save_plan` when `can_write` is `false` (only an explicit `false`: the CRM's own pages never set it); `ProjectClientLive` refuses `open_composer` and `{:crm_client, :compose, _}` without `can_write: true`. Test: `project_client_write_gate_test.exs` — a forged delete and save leave the row alone (verified failing with the guard stashed), and the same delete with `can_write` goes through.
- ~~BUG - HIGH: staff attendee's time logged again on every edit~~ (Codex #2, found independently) — one `actor_key/2` builds the key for the chips and for the ledger entries. Test: the edit drawer's minutes box for a staff party is `attendee_minutes[staff_person:<uuid>]`.
- ~~BUG - MEDIUM: edit skipped the ownership gate~~ (Codex #4) — `editable?/2` on the event, and `load_for_edit/2` for the drawer's `open_editing_uuid`. Test: a contact-anchored project row does not open for edit on the company's tab.
- ~~BUG - MEDIUM: ledger failure hidden by the closing drawer~~ (Codex #6) — `done/1` does not close while `save_error` is set; the feed refreshes off the save's broadcast either way. Not covered by a test: the ledger (the projects module) is not loaded in this suite.
- ~~BUG - MEDIUM: non-string party names / non-uuid references → 500 / bad changeset~~ (Codex #3) — typed checks before `to_string`, `uuid_or_nil?/1` on both references. Test rows added to the `update` validation table.
- ~~BUG - MEDIUM: `event_uuid` unchecked~~ — must be a uuid or null (422 otherwise). Test rows added. Existence on the project is not checked (see Skipped).

## Skipped (with rationale)

- **Billable alone on an edit changes nothing** (Codex #7) — a fix has to know the checkbox's value when the drawer opened: `c_billable` is "any entry billable", so re-applying it on every save would flip the non-billable entries of a mixed set that someone edited in the projects UI. Needs an `edit_billable` assign and the ledger's `update_time/3` semantics (not loaded here to test). Open.
- **`list_for_project/2` shows rows of a trashed anchor** (Codex #5) — `list_for_company/2`, the pre-PR sibling, does the same, so this is a product question rather than a slip: should a project's history vanish from its Client tab when its client company is trashed? Left for a decision.
- **Task linking after the interaction write** (Codex #8) — the pre-write `check_tasks/2` (above, `d370885`) closes the reachable cases; what is left is a task deleted between the check and the link.
- **Planned-events cache** (Codex #9) and **topic coverage** (Codex #10) — a stale "Planned" time until the tab is reopened, and no live refresh for a contact-anchored or former-client row. Both cosmetic; the API and the composer write only company-anchored rows.
- **`since`/`time_zone`/cross-project `event_uuid`, ledger entries after a delete** — on record in `CLAUDE_REVIEW.md`, no behaviour change.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_crm/web/interactions_component.ex` | write-event guard; `editable?/2`, ownership in `load_for_edit/2`; `actor_key/2`; `done/1` |
| `lib/phoenix_kit_crm/web/project_client_live.ex` | `open_composer` / `:compose` need `can_write` |
| `lib/phoenix_kit_crm/project_api.ex` | party and `event_uuid` type checks |
| `test/phoenix_kit_crm/web/project_client_write_gate_test.exs` | new — forged events, edit ownership |
| `test/phoenix_kit_crm/web/project_client_edit_test.exs` | staff attendee key |
| `test/phoenix_kit_crm/project_api_test.exs` | the new validation rows (uuids in the "at most one" row) |

## Verification

`mix precommit` 0 (compile --warnings-as-errors, deps.unlock --check-unused, hex.audit, credo --strict, dialyzer). `mix test`: 836 tests; the failures are environmental and identical on the untouched tree — `InteractionAttachmentsTest` (8; the shared test DB holds a leftover "Default" storage bucket that is in use) and `SchemaOwnerGuardWiringTest` (2) — the four new tests pass.

## Open

~~The three Skipped items that are decisions: billable on edit, trashed anchors on the project feed, the planned-events refresh.~~ All three were taken in `ee71f0b` (next section): billable edits, the trashed-anchor guard on the project feed (`visible_anchors/1`, also on the API's fetch), and the calendar/project-feed refresh. Still open after it: the task link after the interaction commits, `event_uuid` project membership, and concurrent first-time ledger writes.

# Workspace follow-up to commit `854ae92` (2026-10-05)

Codex ran the code and extended the previous static review in
`CODEX_REVIEW.md`. Claude's authorization, actor-key and UUID/type fixes are
retained. This pass additionally fixes partial-ledger retries, failed ledger
reads, billable-only edits and mixed billable flags, project visibility and
notifications, calendar cache refresh, and NUL/blank API input validation.
The previously reported suite failures are repaired through sandboxed fixture
setup, scratch-clone portability and parent/component synchronization; no
ownership-guard assertion or test was removed.

The new drawer tests exercise a successful staff edit, billable-only changes,
mixed ledger flags, partial failures and retry, ledger read failures, and
calendar refreshes. Running them with Claude's original component produced
six tests and five failures; restoring the reviewed component makes all pass.
The runtime test collaborators are limited to a synchronous module and are
unloaded afterward; no projects dependency or production test switch was added.

API task linking after commit remains open, including failures after the
prevalidation succeeds. Project membership of `event_uuid` and concurrent
first-time ledger writes also remain limitations. See the review for the
transaction/broadcast reason an outer transaction alone is insufficient.

## Workspace validation

- `mix test --seed 42`: **846 tests, 0 failures**.
- `mix test --seed 999`: **846 tests, 0 failures**.
- `mix precommit`: **exit 0** (compile with warnings as errors, unused-lock
  check, Hex audit, formatting, strict Credo and Dialyzer).
- `git diff --check`: clean.

Version remains `0.15.1`; no release entry, push, publish or tag was made.
