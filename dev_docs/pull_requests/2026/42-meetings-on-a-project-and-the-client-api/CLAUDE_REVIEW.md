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
