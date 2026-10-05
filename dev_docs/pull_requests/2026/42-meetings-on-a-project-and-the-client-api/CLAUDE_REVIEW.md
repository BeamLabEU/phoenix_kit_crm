# Claude review — quality-sweep triage (2026-10-05)

The projects-and-CRM branches were triaged together by three read-only
agents (the playbook's C12 prompts, verbatim) before the two PRs were
opened; the full three-agent report sits with the projects PR
(`phoenix_kit_projects/dev_docs/pull_requests/2026/48-…/CLAUDE_REVIEW.md`).
What concerned this repo:

- **BUG - HIGH: `tasks: [uuid]` on an interaction linked any task on the site.** `ProjectApi.link_tasks/3` → `ProjectsLink.link_task/3` looked the task up by uuid alone; nothing compared the task's project with `ctx.project` or the key's reach. A key with `interactions:write` on project A could link, and rewrite the description of, a task in project B — and the interaction's `tasks` then showed B's task title.
- **BUG - MEDIUM: `tasks: [123]` hit `link_task/3`'s `is_binary` guard**, which its `rescue` does not catch → a 500.
- **BUG - MEDIUM: the interaction was committed before the tasks were checked**, so an unknown task answered 404 with the row already saved, and a retry duplicated it.
- **BUG - MEDIUM: linking tasks from the CRM side logged nothing.**
- **IMPROVEMENT - HIGH: `to_json/1` ran `tasks_for_interaction/1` per row**, up to 200 on a list.
- **NITPICK:** `since` filters on the user-supplied `occurred_at` while `now` is server time, so a backdated interaction logged after a poll is never returned to a poller using `since=now`. Comments in `project_api.ex` and `projects_link.ex` still described the token-only link.
- Missing `@spec` on `CompanyApi.resource/scopes/action/list/get` and `ProjectApi.client_company_uuid/1` — consistent with `ProjectApi`'s own `@doc false` callbacks.
- Checked, clean: no PubSub in the diff; `CompanyApi.get/2` answers only the project's own client; the `#` context can only narrow a search; `escape_like` on the LIKE input; no log leaks.

# Claude review — post-merge pass (2026-10-05)

A second read of the merged PR (`2dee43d..6a44592`), after the triage above
and its fixes. Findings are in severity order; what was done about each is in
`FOLLOW_UP.md`.

- **BUG - HIGH: `can_write: false` was enforced only by the template.** `InteractionsComponent` and `ProjectClientLive` rendered no write controls for a viewer without the extension's `log_interaction` action, but `save_interaction`, `delete_interaction`, `edit_interaction`, `save_plan`, `start_planning`, `log_planned` and `open_composer` ran for anyone who sent the event. A read-only viewer could delete the client's interactions, log new ones (with attendee time into the project's ledger) and create project events. Reproduced: with the guard stashed, a forged `delete_interaction` removed the row.
- **BUG - HIGH: a staff attendee's logged time never matched on edit.** `assign_logged_time/2` keyed ledger entries `"#{actor_kind}:#{actor_uuid}"` (`staff_person:<uuid>`), the attendee chips keyed a staff person `"staff:<uuid>"`. Only the viewer's `"me"` key lined up (the one case the edit test covers), so every edit saw each staff attendee as new and logged their minutes again.
- **BUG - MEDIUM: `edit_interaction` skipped the ownership gate `delete_interaction` has.** A forged event could open and save a row that only spills into the page's feed (a member's own interaction on the company page).
- **BUG - MEDIUM: a ledger failure was invisible in the drawer.** `log_attendee_time/2` sets `save_error`, then `done/1` closed the drawer — the only place the message renders — so "N time entries could not be written" was never read.
- **BUG - MEDIUM: `parties` entries that are not strings/uuids.** `to_string(p["name"])` raises on a JSON object (a 500 instead of a 422); a number in `contact_uuid` / `staff_person_uuid` reached the changeset.
- **BUG - MEDIUM: `event_uuid` was unchecked on the API.** Any string (5 000 characters of it) was stored on the row's metadata; a number was silently dropped.
- **IMPROVEMENT - MEDIUM: toggling Billable alone on an edit changes nothing.** `amendment/2` compares minutes only, so an existing entry stays as it was.
- **IMPROVEMENT - MEDIUM: `list_for_project/2` joins neither anchor**, so rows whose anchor is trashed still list, unlike the overview's `list_recent/1`. (`list_for_company/2` does the same today; see FOLLOW_UP.)
- **IMPROVEMENT - MEDIUM: the planned-events cache is `assign_new`.** A meeting moved or planned on the hub's Calendar tab does not show on a mounted Client tab until it is remounted.
- **NITPICK: the Client tab subscribes to the client company's topic only**, so a project row anchored to a contact (or to a former client) refreshes nobody.
- **NITPICK: an unparseable `since` is silently ignored** (the full list comes back); `time_zone` is not checked against the IANA names; an `event_uuid` of another project is accepted.
- **NITPICK: deleting a project interaction leaves its ledger entries** (they carry `metadata.interaction_uuid`). Consistent with "the CRM never reads the ledger back"; worth a line in the delete confirmation.
- Checked, clean: `InteractionLinks` search/visibility (`escape_like`, CRM-access gate, a bad project uuid is rescued to `[]`); V8 is idempotent and drops nothing; `check_tasks/2` now runs before any write; no PII in the new activity or log lines.
