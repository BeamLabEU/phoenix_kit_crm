# Codex review — PR #42 (2026-10-05)

Reviewer: codex (`codex exec`, read-only sandbox). It could not run commands in this container, so it saw only the PR's `lib/` + `test/` diff and `AGENTS.md`, piped in. Output below is verbatim; its claims are triaged in `FOLLOW_UP.md` (the "Post-merge pass" section).

Static review of the supplied diff only; no commands or tests run.

1. **BUG - HIGH — `web/interactions_component.ex`, `handle_event("save_plan", …)`**

   The template hides planning behind `@can_write`, but `start_planning`, `plan_change`, and `save_plan` never enforce it. `save_plan` directly calls `ProjectsLink.create_event/3`.

   **Failure scenario:** A viewer with `can_write: false` sends those events to the mounted feed component and creates a project event despite having no write permission. Any independent authorization inside the unseen projects context cannot be verified here.

2. **BUG - HIGH — `web/interactions_component.ex`, `assign_logged_time/2`, `attendees/1`**

   Existing staff ledger entries are indexed as `"staff_person:<uuid>"`, using `actor_kind`. Staged staff attendees use `"staff:<uuid>"`. Consequently, edits never match staff attendees to their existing entries.

   **Failure scenario:** Save a 120-minute meeting with a staff attendee, then edit and save it without changing anything. That attendee appears unlogged and receives another 120-minute ledger entry. Repeated edits keep duplicating time.

3. **BUG - MEDIUM — `project_api.ex`, `party/2`**

   `to_string(p["name"] || "")` runs before validating the name’s type. JSON objects do not implement `String.Chars`; some arrays also raise during conversion. The provider has no rescue or validation clause for this.

   **Failure scenario:** PATCH an existing interaction with `{"parties":[{"name":{}}]}`. The callback raises `Protocol.UndefinedError` instead of returning 422. Whether the HTTP layer converts that into a different response depends on the unseen dispatcher.

4. **BUG - MEDIUM — `web/interactions_component.ex`, `load_for_edit/2`, `update_interaction/2`**

   The template restricts Edit to `owns_row?(assigns, i)`, but the new edit loader and update function accept any interaction in the loaded feed. Neither checks ownership.

   **Failure scenario:** A company’s People feed contains a member’s contact-anchored interaction. Sending `edit_interaction` with that UUID loads it, and saving changes updates it despite the page’s explicit read-only treatment of spillover rows.

5. **BUG - MEDIUM — `interactions.ex`, `list_for_project/2`**

   This listing omits both anchor joins and their `"trashed"` guards. Preloading contacts and companies afterward does not filter results.

   **Failure scenario:** Trash a company or contact that anchors a project interaction. The interaction remains visible through the project Client tab and API, including its body and parties, although the conventions require listing queries to exclude trashed anchors.

6. **BUG - MEDIUM — `web/interactions_component.ex`, `log_attendee_time/2`, `done/1`; `web/project_client_live.ex`, `handle_info/2`**

   Ledger failures set `save_error`, but the save path still calls `done/1`. In drawer mode, that sends `:saved`, and the parent immediately removes the composer. The error is rendered only inside that composer.

   **Failure scenario:** The meeting saves successfully but the ledger rejects an attendee’s time. The drawer closes without showing the failure, leaving the user unaware that time was not recorded.

7. **BUG - MEDIUM — `web/interactions_component.ex`, `amendment/2`, `log_attendee_time/2`**

   Existing entries are updated only when their minutes change. Changing the Billable checkbox alone produces `:keep`, so `ProjectsLink.update_time/3` is never called.

   **Failure scenario:** Edit a meeting with an existing nonbillable 60-minute entry, check Billable, and save with the same minutes. The interaction saves, but the ledger entry remains nonbillable.

8. **BUG - MEDIUM — `project_api.ex`, `answer/4`, `link_tasks/3`**

   Task linking happens after the interaction write succeeds. A linking failure returns an error without any rollback shown; earlier task links can also have succeeded.

   **Failure scenario:** A task passes `check_tasks/2` but is deleted before linking. POST returns 404 after creating the interaction. Retrying can create another interaction. This persistence outcome would depend on whether the unseen dispatcher wraps the entire callback in a transaction and explicitly rolls it back.

9. **BUG - MEDIUM — `web/interactions_component.ex`, `assign_planned_events/1`, `planned_label/2`**

   Planned events are loaded with `assign_new`, so refreshing interactions never refreshes an existing event cache. `planned_label/2` prefers that cached event over fetching its current value.

   **Failure scenario:** Move a meeting in the project Calendar while the Client tab remains mounted. Even after an interaction broadcast refreshes the feed, the tab continues showing the old planned time. Newly created plans also remain absent until a fresh component mounts.

10. **BUG - MEDIUM — `web/project_client_live.ex`, `subscribe/1`**

    The feed lists interactions by project, including contact-anchored rows—as the added tests explicitly demonstrate—but subscribes only to the configured company’s interaction topic.

    **Failure scenario:** Another session updates a contact-anchored interaction belonging to this project. Its notification goes to the contact topic under the documented PubSub contract, so the project feed does not refresh. The same mismatch occurs for rows anchored to a former client company after the project’s client changes.

## Workspace verification of Claude's post-merge fixes — 2026-10-05

Reviewed the merged PR and commit `854ae92` against their callers, the local
projects implementation, and the running CRM suite. Claude's write gate,
anchor ownership check, staff actor-key fix, and typed API validation are
sound. The earlier static review did not exercise ledger writes; the new
synchronous drawer tests supply temporary in-memory projects collaborators
and exercise the real LiveView and `ProjectsLink` calls. They unload those
collaborators afterward, retaining the package's no-projects dependency and
its absent-module tests.

### Findings fixed in this pass

1. **BUG - HIGH: the partial-ledger-error fix cleared the saved meeting's
   identity and fields.** Keeping the drawer open made the warning visible,
   but `reset_composer` had already erased `editing_uuid`, parties, minutes,
   and the meeting fields. Save now keeps the committed row as an edit and
   reloads successful ledger entries. A retry writes missing time without
   creating another meeting or duplicating successful entries. The regression
   test covers one successful attendee and one rejected attendee followed by
   a successful retry.

2. **BUG - HIGH: a failed ledger read looked like an empty ledger.** The
   rescue in `list_time/2` returned `[]`; editing then treated all staff as
   unlogged. Added `fetch_time/2`, preserving read errors while retaining the
   existing `list_time/2` contract. The composer refuses an edit save after a
   read error and tells the viewer to reopen the meeting. A regression test
   proves that neither the interaction nor existing time changes.

3. **BUG - MEDIUM: billable-only edits did nothing, and minutes edits could
   overwrite a mixed set's billable flags.** The latter is the other half of
   the skipped finding: the old update passed the aggregate checkbox to a
   changed attendee even when that checkbox was untouched. Save now compares
   the checkbox with its initial aggregate value and preserves each entry's
   flag unless the viewer changes it. Tests cover billable-only updates and
   changing the nonbillable attendee's minutes in a mixed set. The unchanged
   staff-entry test also verifies Claude's actor-key fix through actual calls.

4. **BUG - MEDIUM: project lists included interactions with trashed anchors.**
   This is resolved by the documented visibility rule, rather than requiring
   another product decision. The project query LEFT JOINs both anchors and
   filters before applying its limit. API get/update use the same visibility
   predicate. Data remains stored. Trash, restore and cascade delete notify
   project feeds; tests cover both anchor kinds.

5. **BUG - MEDIUM: the project feed and planned-event cache stayed stale.**
   The Client tab subscribed only to its current company, missing contact and
   former-client rows. Added a CRM project interaction topic, covering create,
   update, delete, anchor visibility, and changes to a row's project. Calendar
   subscriptions use the projects package's own PubSub contract through the
   optional bridge; this checkout's projects package uses core's internal
   manager. Plans reload on feed refresh, including an open drawer, without
   overwriting typed meeting fields. Tests exercise contact/former-client
   mutations via real PubSub and calendar refreshes through the event handler.

6. **BUG - MEDIUM: API strings containing NUL could still reach PostgreSQL
   and raise instead of answering 422.** Subject, body, time zone and party
   names now reject NUL before writing. Party names are trimmed and blank
   names rejected, rather than silently omitted by the context. The validation
   matrix covers these cases alongside Claude's malformed types and UUIDs.

7. **IMPROVEMENT - MEDIUM: the reported test failures were fixable fixture
   and synchronization problems.** Seed 42 on the untouched checkout produced
   836 tests / 11 failures. Core's storage profile rules forbid disabling an
   in-use bucket, including newly created fixture buckets; a leftover Default
   bucket is not the only cause. Tests now detach profile references inside
   the sandbox before disabling. Scratch DB clones omit ownership/ACL restores
   and inherited admin-owned extension comments while preserving table marker
   comments and all guard assertions. Cleanup is registered before restoration
   so a failed restore cannot leak its scratch DB. The intermittent Files-tab
   test and the company-interaction refresh test now wait for the parent to
   queue its component update before asserting the rendered result.

### Remaining limitations

- **BUG - MEDIUM: API task linking is still not atomic with the interaction
  write.** Prevalidation handles bad tasks known before saving, but a later
  linking failure can still return an error after the meeting and earlier links
  have committed. This includes dependency or database failures, not only a
  task being deleted between validation and linking. A correct cross-module
  transaction must also defer both modules' activity and broadcasts until the
  outer commit; simply wrapping today's contexts would violate that contract.
  Left for coordinated CRM/projects work, not classified as fixed.
- `event_uuid` is shape-validated but not checked for membership in the project;
  `since` still means occurrence time, and malformed `since` is ignored. These
  existing API semantics were not changed in this pass.
- Deleting an interaction retains its independent ledger history. Concurrent
  editors can still race when adding the same attendee's first time entry;
  the ledger has no interaction/actor uniqueness guarantee. The sequential
  retry fix does not claim concurrency idempotence.

### Verification

- New ledger/drawer tests against Claude's component from `854ae92`: **6 tests,
  5 failures**, detecting retry state loss, read-error duplication, both
  billable issues and the stale plan cache. The unchanged staff-key test passed.
  Restoring this pass's component makes all six pass.
- Full suite and quality-gate results are recorded in `FOLLOW_UP.md` below.
- Release preparation remains incomplete: `mix.exs` is still `0.15.1` and the
  changelog has no PR #42 entry. This review does not bump, publish, tag or push.
