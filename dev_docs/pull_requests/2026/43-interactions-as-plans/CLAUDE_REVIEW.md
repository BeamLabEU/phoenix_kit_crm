# Claude review — PR #43 "Interactions as plans (planned, happened, cancelled), on the calendars, and shared across a client's projects" (2026-10-14)

Merged as `bba32bd` (`greenoak-interactions`, author mdon). Read: the whole
`lib/` diff — V9 migration, `Interaction` status/`planned_at`/`location`,
`Interactions` (status-aware readers, `log_change`, `project_condition`),
`InteractionNotifier`, `CalendarItems`, `ProjectColumns`, `ProjectApi`,
`InteractionsDrawer`, `InteractionsComponent`, the three host LiveViews.
Not re-read line by line: the gettext catalogues, `mix.lock`, the JS bundle.

Not reviewed because there is nothing to review: #30 (test-only guard
wiring), #34 (AGENTS.md skeleton), #35 (test_helper preflight + doc
scrubbing).

## Findings

- **BUG - MEDIUM: the API could turn a logged row back into a plan while the project's ledger still held time against it.** The composer refuses this (`status_error/2`: "Time is already logged on this…"), and AGENTS.md states it as a rule ("one with ledger entries cannot be made a plan again"), but `ProjectApi.update/3` only ran `check_time/2`. `PATCH {"status": "planned"}` on a happened row with attendee minutes left a plan carrying ledger entries — a state the UI cannot produce and `log_attendee_time/2` never reconciles. **Fixed:** `check_replan/3` asks `ProjectsLink.fetch_time/2` (the variant that keeps read failures) and answers 422 when entries exist, or when the ledger cannot be read. Without the projects module there is no ledger and the change passes (covered by a test; the refusal itself needs the projects module and is not reachable from this repo's suite).
- **IMPROVEMENT - MEDIUM: AGENTS.md still said the chain was at V08** and the module-owned-tables list did not mention `status` / `planned_at` / `location` / `idx_crm_interactions_planned`. **Fixed.**
- **IMPROVEMENT - MEDIUM: `POST /ext/interactions` accepts `status: "planned"` without `occurred_at`.** The schema then stamps "now" as the planned start, so the plan is `overdue` on its first read. Not changed: it is a contract choice for the author (require a start for a plan, or document the default).
- **IMPROVEMENT - MEDIUM: `ProjectApi.linked_tasks/2` with `reach` calls `ProjectsLink.task_project/1` once per task per row** (a list is up to 200 rows). The unreachable-`reach` filter is right and needed; the cost is the same N+1 the earlier triage flagged for `tasks_for_interaction/1`. Left — wants a batched `task_projects/1` on the projects side.
- **NITPICK: `CalendarItems.in_window/3` applies `limit(@cap + 1)` in SQL before the exact overlap filter.** More than 200 rows that start in the one-day slack before the window and do not reach it can push real in-window items past the limit, and `truncated` is computed after the filter. Needs >200 interactions in a single day; left.
- **NITPICK: a `happened → cancelled` edit notifies the parties** ("A meeting you are in was cancelled"), as does any `from != "cancelled"` transition. Reasonable, but the convention text only talks about plans. A `cancelled → planned` re-instatement notifies nobody new (`notify_added/3` diffs parties, not the status). Left.
- **NITPICK: `InteractionNotifier.linked_users/2` reads `phoenix_kit_crm_contacts` schemaless**, which ignores a non-default schema prefix (the staff table is another module's, so schemaless is right there). The `Contact` schema would honour `SchemaPrefix`. Failure mode is a silent `[]` (no notification), not a crash. Left.
- **Design note (not a defect):** with `of=client` / `:client`, a key or a user with access to project A reads the full body of project B's interactions with the same client company. It is documented, writes stay on the owning project (`fetch/2` answers 403 `other_project`), and `to_json/2` drops tasks outside the caller's reach. It does mean the Client extension on a project is the only gate for the client's whole history.

## Checked, clean

- **Transitions and notifications:** `change_kind/2` ordering (logged → cancelled → moved → updated) is exhaustive; `update_interaction/4` force-preloads `parties` before and after, so `party_user_uuids/1` never sees `NotLoaded`; `fan_out/2` takes the `{:ok, entry}` straight from `Activity.log`, so a log that did not write notifies nobody; no PII in the new metadata (`notification_text` is a type word).
- **Every reader says what it means by an interaction:** `list_recent/1` and `count_interactions/0` leave plans out, `list_planned/1` is the plan, the feeds return everything and `planned_rows/1` / `feed_rows/1` split it; `ProjectClientLive` drops planned rows from its "recent" strip; anchors are LEFT JOINed with the trashed guard in `CalendarItems` too.
- **Write gates:** the `@write_events` list lost `save_plan` (event removed) and gained `cancel_planned` / `set_status`; `open_composer` has its own `can_write: false` clause; `InteractionsDrawer.handle_info/3` drops `:compose` for a read-only host; `owns_row?/2` now also requires `row.project_uuid == project_uuid` in project mode, so a client row logged on another project is read-only there.
- **LiveView lifecycle:** no queries in `mount/3` (the drawer's `init/2` only assigns); the feed refresh rides a fresh token; `ProjectClientLive` collapses the two PubSub deliveries of one write (project + client-company topic) into one reload.
- **Migration V9:** every statement idempotent (`ADD COLUMN IF NOT EXISTS`, guarded constraint, `CREATE INDEX IF NOT EXISTS`); `down/1` still drops nothing; existing rows default to `happened`.
- **Time rules agree:** the composer's 300 s "still to come" threshold equals the API's `@future_tolerance_seconds`; `ended_at` ↔ `duration_minutes` conversion rejects an end not after the start in both.
- **Schemaless reads of other modules' tables** (`phoenix_kit_staff_people`, `phoenix_kit_project_modules`) are rescued, and the staff table is created by core's migrations (V135), so `CalendarItems.for_user/3` does not collapse to empty on installs without the staff module.
