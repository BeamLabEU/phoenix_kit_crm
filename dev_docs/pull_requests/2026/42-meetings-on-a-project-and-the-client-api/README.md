Meetings and calls logged on a project, and the client's records on the projects API. Built on dev.greenoak.ee alongside the projects branch (BeamLabEU/phoenix_kit_projects, the API PR) for the boss's client project: "we have a client and we would like to track what we're doing for the client, how much time we're putting in". 21 commits.

## What a reader needs to know

**Interactions on a project** (chain V8: `project_uuid`, `duration_minutes`). The project's Client tab lists the company's interactions and logs new ones in a drawer: type (a "message" type added), subject, body, when and zone, duration, the parties (contacts, staff people, or free text — the viewer offered as a "me" row), with each attendee's minutes going to the project's ledger as billable time; editing an interaction can add or change parties and amend or remove the attendees' logged time (through the projects module's `Ledger`, softly — nothing here depends on it). A meeting can be planned from the Client tab as a project event and the record logged from the plan ("Log what happened"), linked both ways. Interactions are mentionable (`#` records) and link back to the tasks made from a meeting.

**On the projects API** (`PhoenixKitProjects.Extensions.ApiProvider`, adopted by name — the projects module is not a dependency): `/ext/interactions` list (`since`, `limit`), get, create, update, each answering the `tasks` that came out of it (the projects module's link table when it is there, else the mention backlinks), and `tasks: [uuid]` on create/update to link them; `/ext/companies` — the project's client with the people at it, so a party's contact uuid has a name. Both on the `interactions:read` / `interactions:write` scopes. The CRM extension declares `api: [ProjectApi, CompanyApi]` (a list; the projects side accepts one).

**`#` inside a project**: the interaction handler for the typeahead narrows to the project's subtree when core sends the field's context.

Smaller: the row actions in core's three-dot menu, Edit in place, the billable switch on the duration's centre, the row menu's Delete translated, the when-field warning humanised.

## Verification

`mix precommit` clean (compile --warnings-as-errors, deps.unlock --check-unused, hex.audit, credo --strict, dialyzer); 831 tests, 0 failures (`PGUSER=maxdon`). Reviews and the sweep's follow-up under `dev_docs/pull_requests/2026/<this PR>/`.

No version bump, no CHANGELOG entry.
