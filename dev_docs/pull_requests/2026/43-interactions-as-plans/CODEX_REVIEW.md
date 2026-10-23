# Codex review — PR #43 (2026-10-23)

PR: [Interactions as plans](https://github.com/BeamLabEU/phoenix_kit_crm/pull/43),
merged as `bba32bd`. Reviewed the current implementation, including the
post-merge ledger guard, against the interaction context, schema, composer,
drawer, project API, calendar providers, notifier, project columns, and tests.

## Findings fixed

1. **BUG - HIGH: API filtering and plan ordering happened after the 200-row
   database limit.** Enough future plans hid the project's completed history;
   asking for the next plan selected from the furthest 200 starts. An older
   interaction edited recently could also disappear from `updated_since`.
   Status, start and update filters now run in SQL, followed by the requested
   order and limit. A UUID tiebreak makes capped results deterministic.
   Regression coverage inserts 205 additional plans and checks the completed
   record, earliest plan, and update-filtered result.

2. **BUG - HIGH: the polling cursor was captured after the read.** A write
   committed after the SELECT but before the response's `now` could be absent
   from both that response and the next inclusive `updated_since` poll.
   `now` is captured before querying. A telemetry-backed slow-read test
   confirms the cursor does not advance beyond the read.

3. **BUG - MEDIUM: calendar capping preceded the exact overlap check.**
   201 interactions ending before the requested window could consume the
   entire SQL result and hide real calendar entries, while reporting
   `truncated: false`. Exact overlap now runs in SQL before the cap; the
   existing one-day index bound and overlap boundary semantics are preserved.
   A regression test uses 201 irrelevant rows and 201 overlapping rows and
   checks the first 200 items plus `truncated: true`.

4. **BUG - MEDIUM: explicit null status raised a database exception.**
   Inclusion validation skipped nil, so the NOT NULL constraint raised
   instead of returning a changeset. Empty strings could also be cast back
   to the schema's `happened` default, silently changing a plan's outcome.
   Status is cast separately with no empty-value substitution and is
   required. Tests cover nil, empty and whitespace values on create/update,
   preservation of the saved plan, and the existing omitted-status default.

5. **BUG - MEDIUM: reinstating a plan did not tell its existing attendees.**
   `cancelled -> planned` and `happened -> planned` were ordinary updates;
   recipient differences were empty when the parties stayed the same.
   Entering planned status now creates one `crm.interaction_planned` activity
   with `status_from` and fans it out to all current party accounts.
   Reinstatement coverage checks the new planning activity. Existing tests
   retain the distinct behavior for adding someone to an unchanged plan.

6. **BUG - MEDIUM: contact notification lookup ignored the CRM schema prefix.**
   The owned contacts table was queried as a raw string. It now uses the
   `Contact` schema through the same UUID/user query, honoring its compiled
   prefix. Existing linked-contact recipient tests exercise the query in the
   default schema; a separate host build with a custom prefix was not run.

## Additional verification

The API's previous guard against re-planning a row with ledger entries now
has tests using the existing synchronous projects-ledger collaborator. Both
existing time and a failed ledger read return 422 without changing status.
The suite also covers project write gates, read-only client spillover,
anchor trash/restore, attendee retry behavior, and calendar visibility.

Known boundaries remain: a new API plan without a start defaults to now;
task serialization still calls the optional projects bridge per task; the
CRM suite does not boot a complete host with the actual projects package.

Validation and review scope: [pre-live report](../../../reports/2026-10-23-prelive-review.md).
