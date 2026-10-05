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